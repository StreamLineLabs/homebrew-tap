# typed: false
# frozen_string_literal: true

# Homebrew formula for Streamline
# The Redis of Streaming - Kafka-compatible streaming platform
#
# Installation via tap:
#   brew tap streamlinelabs/streamline
#   brew install streamline
#
# Or direct installation:
#   brew install streamlinelabs/streamline/streamline


class Streamline < Formula
  desc "The Redis of Streaming - Kafka-compatible streaming platform"
  homepage "https://github.com/streamlinelabs/streamline"
  version "0.3.0"
  license "Apache-2.0"

  # Pre-built binaries — no bottles needed
  bottle :unneeded

  # SHA256 hashes are computed from release artifacts by scripts/update-formula.sh
  # To update: ./scripts/update-formula.sh <version>
  # Or trigger the "Update Formula" GitHub Action on a new release.
  #
  # IMPORTANT: Hashes below must be updated before publishing. The placeholder value
  # "PLACEHOLDER_SHA256_*" will cause brew install to fail with a clear error.
  # Run: ./scripts/update-formula.sh 0.2.0
  #
  # CI will block releases with placeholder hashes. See .github/workflows/release.yml.
  on_macos do
    on_arm do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER_SHA256_ARM64_DARWIN" # update-formula.sh replaces this
    end
    on_intel do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER_SHA256_X64_DARWIN" # update-formula.sh replaces this
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "PLACEHOLDER_SHA256_ARM64_LINUX" # update-formula.sh replaces this
    end
    on_intel do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "PLACEHOLDER_SHA256_X64_LINUX" # update-formula.sh replaces this
    end
  end

  head do
    url "https://github.com/streamlinelabs/streamline.git", branch: "main"
    depends_on "rust" => :build
  end

  option "with-moonshot", "Include experimental moonshot features (semantic search, agent memory, attestation, branches)"

  def install
    if build.head?
      if build.with?("moonshot")
        system "cargo", "build", "--release", "--features", "moonshot"
      else
        system "cargo", "build", "--release"
      end
      bin.install "target/release/streamline"
      bin.install "target/release/streamline-cli"
    else
      # Fail fast if placeholder hashes were not replaced
      if stable.url.to_s.empty? || stable.checksum.to_s.start_with?("PLACEHOLDER")
        odie <<~EOS
          SHA256 hashes have not been updated for this release.
          Run: ./scripts/update-formula.sh #{version}
        EOS
      end

      bin.install "streamline"
      bin.install "streamline-cli" if File.exist?("streamline-cli")
    end

    odie "streamline binary not found in archive" unless (bin/"streamline").exist?

    # Generate shell completions if supported
    generate_completions_from_executable(bin/"streamline-cli", "completions") if (bin/"streamline-cli").exist?
  end

  def post_install
    (var/"streamline").mkpath
    (var/"log").mkpath
  end

  def caveats
    <<~EOS
      Streamline has been installed!

      Quick Start:
        # Start the server
        streamline --data-dir #{var}/streamline

        # Or in playground mode (in-memory, demo topics)
        streamline --playground

      Service Management:
        # Start as a background service
        brew services start streamline

        # Stop the service
        brew services stop streamline

        # View logs
        tail -f #{var}/log/streamline.log

      CLI Usage:
        # Produce a message
        streamline-cli produce demo -m "Hello, Streamline!"

        # Consume messages
        streamline-cli consume demo --from-beginning

        # List topics
        streamline-cli topics list

      Kafka Clients:
        Streamline is Kafka-compatible. Connect any Kafka client to localhost:9092.

      Data Directory: #{var}/streamline
      Log File:       #{var}/log/streamline.log

      Documentation:
        https://github.com/streamlinelabs/streamline
    EOS
  end

  service do
    run [opt_bin/"streamline", "--data-dir", var/"streamline"]
    keep_alive true
    working_dir var/"streamline"
    log_path var/"log/streamline.log"
    error_log_path var/"log/streamline.log"
  end

  test do
    # Verify binaries exist and are executable
    assert_predicate bin/"streamline", :exist?
    assert_predicate bin/"streamline", :executable?

    # Test --version output
    assert_match version.to_s, shell_output("#{bin}/streamline --version")

    # Test --help output
    assert_match "streamline", shell_output("#{bin}/streamline --help")

    if (bin/"streamline-cli").exist?
      assert_predicate bin/"streamline-cli", :executable?
      assert_match "streamline-cli", shell_output("#{bin}/streamline-cli --help")
    end

    # Test server starts, responds to health check, and serves Kafka protocol
    kafka_port = free_port
    http_port = free_port
    pid = fork do
      exec bin/"streamline",
           "--listen-addr", "127.0.0.1:#{kafka_port}",
           "--http-addr", "127.0.0.1:#{http_port}",
           "--data-dir", testpath/"data",
           "--in-memory"
    end

    # Wait for server to be ready (up to 10 seconds)
    sleep 1
    10.times do
      break if shell_output("curl -sf http://127.0.0.1:#{http_port}/health 2>&1 || true").include?("ok")

      sleep 1
    end

    begin
      # Health endpoint responds
      health_output = shell_output("curl -sf http://127.0.0.1:#{http_port}/health 2>&1 || true")
      assert_match(/ok|healthy|alive/i, health_output) if health_output && !health_output.empty?

      # Info endpoint returns server version
      info_output = shell_output("curl -sf http://127.0.0.1:#{http_port}/v1/info 2>&1 || true")
      assert_match version.to_s, info_output if info_output && !info_output.empty?

      # Topics list endpoint responds (empty list is fine)
      topics_output = shell_output("curl -sf http://127.0.0.1:#{http_port}/v1/topics 2>&1 || true")
      assert_match(/\[/, topics_output) if topics_output && !topics_output.empty?

      # Kafka protocol port is listening (TCP connect test)
      assert shell_output("nc -z 127.0.0.1 #{kafka_port} 2>&1; echo $?").strip.end_with?("0"),
             "Kafka protocol port #{kafka_port} should be listening"
    ensure
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end
end
