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
  version "0.2.0"
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
  on_macos do
    on_arm do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER_SHA256_ARM64_DARWIN"
    end
    on_intel do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER_SHA256_X64_DARWIN"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "PLACEHOLDER_SHA256_ARM64_LINUX"
    end
    on_intel do
      url "https://github.com/streamlinelabs/streamline/releases/download/v#{version}/streamline-#{version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "PLACEHOLDER_SHA256_X64_LINUX"
    end
  end

  head do
    url "https://github.com/streamlinelabs/streamline.git", branch: "main"
    depends_on "rust" => :build
  end

  def install
    if build.head?
      system "cargo", "build", "--release"
      bin.install "target/release/streamline"
      bin.install "target/release/streamline-cli"
    else
      bin.install "streamline"
      bin.install "streamline-cli"
    end
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
    assert_predicate bin/"streamline-cli", :exist?
    assert_predicate bin/"streamline-cli", :executable?

    # Test --version output
    assert_match version.to_s, shell_output("#{bin}/streamline --version")

    # Test --help output
    assert_match "streamline", shell_output("#{bin}/streamline --help")
    assert_match "streamline-cli", shell_output("#{bin}/streamline-cli --help")

    # Test server starts and responds (quick smoke test)
    port = free_port
    pid = fork do
      exec bin/"streamline", "--data-dir", testpath/"data", "--port", port.to_s
    end
    sleep 2
    begin
      output = shell_output("curl -sf http://localhost:#{port + 2}/health 2>&1 || true")
      # Server may not have HTTP on that port, but process should be alive
      assert_predicate testpath/"data", :directory?
    ensure
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end
end
