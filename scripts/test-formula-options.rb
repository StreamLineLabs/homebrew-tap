#!/usr/bin/env ruby
# frozen_string_literal: true

# test-formula-options.rb — hermetic tests for the formula's public source/HEAD
# build contract: the `with-moonshot` option and the conditional Cargo feature
# arguments it drives.
#
# Usage:
#   ruby scripts/test-formula-options.rb [formula]
#
# Environment:
#   STREAMLINE_FORMULA   formula path (same convention as the shell scripts)
#
# Nothing here touches Homebrew, the network, or the filesystem outside a
# temporary directory. The formula is loaded against a minimal stub of the
# Homebrew DSL and its real `install` method is executed, so the assertions
# describe what `brew install --HEAD [--with-moonshot]` would actually run
# rather than what the source merely looks like. Source-level assertions cover
# the parts that cannot be observed by running `install`: that the option is
# declared exactly once, in a Homebrew-compatible position, and outside the
# generated stable-artifacts region so the updater cannot drop it.

require "fileutils"
require "pathname"
require "tmpdir"

FORMULA_PATH = Pathname.new(
  ARGV[0] || ENV["STREAMLINE_FORMULA"] ||
    File.expand_path("../streamline.rb", __dir__),
).expand_path

FEATURE_FLAG = "--features"
FEATURE_NAME = "moonshot"
OPTION_NAME = "with-moonshot"
BEGIN_MARKER = "# >>> STABLE ARTIFACTS BEGIN"
END_MARKER = "# >>> STABLE ARTIFACTS END"

@failed = false

def pass(message)
  puts "  ✅ #{message}"
end

def fail_test(message)
  warn "  ❌ #{message}"
  @failed = true
end

def check(condition, ok_message, fail_message)
  condition ? pass(ok_message) : fail_test(fail_message)
end

unless FORMULA_PATH.file?
  warn "❌ Formula file '#{FORMULA_PATH}' not found."
  exit 2
end

# ---------------------------------------------------------------------------
# Minimal Homebrew DSL stub.
#
# Only what this formula uses is implemented. Anything the formula calls that
# is not modelled raises NoMethodError, which fails the suite loudly instead of
# silently passing on a formula that Homebrew could not load.
# ---------------------------------------------------------------------------
class StubBuild
  def initialize(head:, requested_options: [])
    @head = head
    @requested_options = requested_options.map(&:to_s)
  end

  def head?
    @head
  end

  def stable?
    !@head
  end

  # Homebrew's `build.with?("moonshot")` is true when `--with-moonshot` was
  # passed for a declared `option "with-moonshot"`.
  def with?(name)
    @requested_options.include?("with-#{name}") || @requested_options.include?(name.to_s)
  end

  def without?(name)
    !with?(name)
  end
end

# A Pathname-backed stand-in for `bin`/`var`/`opt_bin` that also records
# `bin.install` calls.
class StubPath
  attr_reader :installs

  def initialize(dir, installs = [])
    @dir = Pathname.new(dir)
    @installs = installs
  end

  def /(other)
    StubPath.new(@dir.join(other.to_s), @installs)
  end

  def exist?
    @dir.exist?
  end

  def executable?
    @dir.exist?
  end

  def install(*sources)
    @installs.concat(sources.map(&:to_s))
  end

  def to_s
    @dir.to_s
  end
  alias to_str to_s
end

class StubStable
  def initialize(url)
    @url = url
  end

  attr_reader :url
end

class OdieError < StandardError; end

class Formula
  class << self
    def declared_options
      @declared_options ||= []
    end

    def desc(*); end
    def homepage(*); end
    def license(*); end
    def url(*); end
    def sha256(*); end
    def mirror(*); end
    def revision(*); end
    def keg_only(*); end
    def depends_on(*); end
    def uses_from_macos(*); end
    def conflicts_with(*); end
    def disable!(*); end
    def deprecate!(*); end
    def deprecated_option(*); end
    def livecheck(*); end
    def bottle(*); end
    def service(*); end
    def test(*); end

    def option(name, description = nil)
      declared_options << [name.to_s, description.to_s]
    end

    def head(*args, &block)
      block ? instance_eval(&block) : nil
    end

    # Platform blocks are not evaluated: which branch Homebrew would take is
    # irrelevant to the source/HEAD build contract under test here, and not
    # evaluating them keeps the stub honest about what it models.
    def on_macos(*); end
    def on_linux(*); end
    def on_arm(*); end
    def on_intel(*); end
    def on_system(*); end
  end

  attr_reader :build, :bin, :var, :opt_bin, :system_calls, :completion_calls, :odie_messages

  def initialize(build:, prefix:, stable: StubStable.new(""))
    @build = build
    @prefix = Pathname.new(prefix)
    @stable = stable
    @installs = []
    @bin = StubPath.new(@prefix.join("bin"), @installs)
    @var = StubPath.new(@prefix.join("var"), @installs)
    @opt_bin = @bin
    @system_calls = []
    @completion_calls = []
    @odie_messages = []
  end

  attr_reader :stable

  def std_cargo_args
    ["--locked", "--root", @prefix.to_s, "--path", "."]
  end

  def system(*args)
    @system_calls << args.map(&:to_s)
    true
  end

  def generate_completions_from_executable(*args)
    @completion_calls << args.map(&:to_s)
  end

  def odie(message)
    @odie_messages << message.to_s
    raise OdieError, message.to_s
  end

  def version
    "0.0.0"
  end
end

# The formula is UTF-8 (its comments carry em dashes), and Ruby tags file
# reads with Encoding.default_external, which is US-ASCII under LC_ALL=C. The
# encoding is therefore stated explicitly rather than inherited from the
# ambient locale: without it, the first source-level regex scan below raises
# `invalid byte sequence in US-ASCII` and the suite dies mid-run on any C/POSIX
# locale runner. `load` is unaffected — Ruby always parses source as UTF-8 —
# so only this read needs pinning.
SOURCE = FORMULA_PATH.read(encoding: Encoding::UTF_8)
load FORMULA_PATH.to_s

puts "==> Loading '#{FORMULA_PATH}' against a stub Homebrew DSL"
check(defined?(Streamline) && Streamline < Formula,
      "formula defines class Streamline < Formula",
      "formula did not define a Streamline formula class")

# Regression guard for the locale-dependent read above. Under LC_ALL=C the
# formula source used to come back tagged US-ASCII, and every source-level
# check in Contract 5 died with `invalid byte sequence in US-ASCII`. Asserting
# the encoding here means a future reader that drops the explicit encoding
# fails with a named contract violation instead of a stack trace.
check(SOURCE.encoding == Encoding::UTF_8 && SOURCE.valid_encoding?,
      "formula source is read as valid UTF-8 independently of the ambient locale " \
      "(Encoding.default_external: #{Encoding.default_external})",
      "formula source was read as #{SOURCE.encoding} " \
      "(valid: #{SOURCE.valid_encoding?}); it must be read explicitly as UTF-8, " \
      "not inherited from Encoding.default_external (#{Encoding.default_external})")

# The scan itself must survive too: a US-ASCII-tagged string only raises when a
# UTF-8 regexp meets a non-ASCII byte, so the encoding assertion alone could
# pass on an all-ASCII formula while the real hazard remains.
scan_ok =
  begin
    SOURCE.lines.each { |line| line =~ /^\s*option\s+"/ }
    true
  rescue ArgumentError, Encoding::CompatibilityError => e
    fail_test("scanning the formula source raised #{e.class}: #{e.message}")
    false
  end
pass("source-level regex scanning works under LC_ALL=C and any other locale") if scan_ok

# ---------------------------------------------------------------------------
puts "==> Contract 1: the '#{OPTION_NAME}' option is declared"
declared = Streamline.declared_options
matching = declared.select { |name, _| name == OPTION_NAME }
check(matching.length == 1,
      "option \"#{OPTION_NAME}\" is declared exactly once (declared: #{declared.map(&:first).inspect})",
      "expected exactly one option \"#{OPTION_NAME}\", found #{matching.length} (declared: #{declared.map(&:first).inspect})")

if matching.length == 1
  description = matching.first[1]
  check(!description.empty? && description.downcase.include?(FEATURE_NAME),
        "the option carries a user-facing description naming the #{FEATURE_NAME} features",
        "option description does not describe the #{FEATURE_NAME} features: #{description.inspect}")
end

# Homebrew's FormulaAudit/Options cop requires option names to begin with
# `with`/`without`; a rename would break both the audit and the public flag.
check(OPTION_NAME.start_with?("with-"),
      "option name begins with 'with-' as Homebrew requires",
      "option name '#{OPTION_NAME}' does not begin with 'with-'")

# ---------------------------------------------------------------------------
# A single prefix is shared by every run so that argument lists from different
# builds are directly comparable (std_cargo_args embeds the prefix).
PREFIX = Pathname.new(Dir.mktmpdir("streamline-formula-options"))
at_exit { FileUtils.remove_entry(PREFIX) if PREFIX.exist? }

def run_install(build)
  bindir = PREFIX.join("bin")
  bindir.mkpath
  # The installed server binary must exist or `install` odies at its final
  # guard; the CLI is deliberately absent so completion generation is skipped.
  bindir.join("streamline").write("#!/bin/sh\nexit 0\n")
  formula = Streamline.new(build: build, prefix: PREFIX,
                           stable: StubStable.new("https://example.invalid/streamline.tar.gz"))
  formula.install
  formula
end

puts "==> Contract 2: a normal HEAD install omits the #{FEATURE_NAME} feature"
plain_head = run_install(StubBuild.new(head: true))
plain_calls = plain_head.system_calls
check(plain_calls.length == 1 && plain_calls.first[0, 2] == ["cargo", "install"],
      "HEAD install runs exactly one `cargo install` (#{plain_calls.inspect})",
      "expected one `cargo install` invocation, got #{plain_calls.inspect}")

plain_args = plain_calls.empty? ? [] : plain_calls.first
check(!plain_args.include?(FEATURE_FLAG) && !plain_args.include?(FEATURE_NAME),
      "no `#{FEATURE_FLAG} #{FEATURE_NAME}` is passed without the option",
      "unrequested #{FEATURE_NAME} feature leaked into a plain HEAD build: #{plain_args.inspect}")

check(plain_args[2..-1] == plain_head.std_cargo_args,
      "plain HEAD build passes exactly the standard cargo arguments",
      "plain HEAD build arguments diverged from std_cargo_args: #{plain_args.inspect}")

# ---------------------------------------------------------------------------
puts "==> Contract 3: `--#{OPTION_NAME}` adds `#{FEATURE_FLAG} #{FEATURE_NAME}` once, in position"
moonshot_head = run_install(StubBuild.new(head: true, requested_options: [OPTION_NAME]))
moonshot_calls = moonshot_head.system_calls
check(moonshot_calls.length == 1 && moonshot_calls.first[0, 2] == ["cargo", "install"],
      "HEAD install with the option still runs exactly one `cargo install`",
      "expected one `cargo install` invocation, got #{moonshot_calls.inspect}")

args = moonshot_calls.empty? ? [] : moonshot_calls.first
flag_positions = args.each_index.select { |i| args[i] == FEATURE_FLAG }
check(flag_positions.length == 1,
      "`#{FEATURE_FLAG}` appears exactly once (#{args.inspect})",
      "expected exactly one `#{FEATURE_FLAG}`, found #{flag_positions.length}: #{args.inspect}")

check(args.count(FEATURE_NAME) == 1,
      "`#{FEATURE_NAME}` appears exactly once",
      "expected exactly one `#{FEATURE_NAME}` argument, found #{args.count(FEATURE_NAME)}: #{args.inspect}")

if flag_positions.length == 1
  idx = flag_positions.first
  check(args[idx + 1] == FEATURE_NAME,
        "`#{FEATURE_FLAG}` is immediately followed by its value `#{FEATURE_NAME}`",
        "`#{FEATURE_FLAG}` is not followed by `#{FEATURE_NAME}`: #{args.inspect}")
  check(idx >= 2,
        "the feature flag comes after the `cargo install` subcommand",
        "the feature flag was placed before the subcommand: #{args.inspect}")
end

# Position: the standard cargo arguments must be preserved verbatim and in
# order, with the feature pair appended after them.
expected_args = ["cargo", "install"] + moonshot_head.std_cargo_args + [FEATURE_FLAG, FEATURE_NAME]
check(args == expected_args,
      "full command is `#{expected_args.join(" ")}`",
      "command differed from the expected contract.\n     expected: #{expected_args.inspect}\n     actual:   #{args.inspect}")

# The option must change nothing else about the build.
check(args[0, args.length - 2] == plain_args,
      "the option is purely additive: everything else matches the plain HEAD build",
      "the option changed arguments other than the feature pair: #{args.inspect} vs #{plain_args.inspect}")

# ---------------------------------------------------------------------------
puts "==> Contract 4: the option never affects a bottle/stable install"
stable_build = run_install(StubBuild.new(head: false, requested_options: [OPTION_NAME]))
check(stable_build.system_calls.empty?,
      "a stable install runs no cargo build at all",
      "a stable install invoked: #{stable_build.system_calls.inspect}")

# ---------------------------------------------------------------------------
puts "==> Contract 5: source placement keeps the contract Homebrew-compatible and updater-safe"
lines = SOURCE.lines.map(&:chomp)
option_lines = lines.each_index.select { |i| lines[i] =~ /^\s*option\s+"#{Regexp.escape(OPTION_NAME)}"/ }
check(option_lines.length == 1,
      "the source declares the option on exactly one line",
      "expected one `option \"#{OPTION_NAME}\"` line, found #{option_lines.length}")

begin_idx = lines.index { |l| l.include?(BEGIN_MARKER) }
end_idx = lines.index { |l| l.include?(END_MARKER) }
head_block_idx = lines.index { |l| l =~ /^\s*head do\s*$/ }
install_idx = lines.index { |l| l =~ /^\s*def install\s*$/ }

if option_lines.length == 1 && begin_idx && end_idx && head_block_idx && install_idx
  option_idx = option_lines.first

  # FormulaAudit/ComponentsOrder: option sorts after the `head do` block and
  # before `disable!` / `on_macos` / `on_linux` — i.e. before the generated
  # region, in both its blocked and its released form.
  check(option_idx > head_block_idx,
        "the option is declared after the `head do` block (component order)",
        "the option is declared before the `head do` block, which violates FormulaAudit/ComponentsOrder")
  check(option_idx < begin_idx,
        "the option is declared before the generated stable-artifacts region (component order)",
        "the option is declared at or after the generated region; `option` must precede `disable!`/`on_macos`")
  check(!(option_idx > begin_idx && option_idx < end_idx),
        "the option lives outside the generated region, so update-formula.sh cannot overwrite it",
        "the option lives inside the generated region and would be destroyed on regeneration")
  check(option_idx < install_idx,
        "the option is declared before `def install`",
        "the option is declared after `def install`")
end

conditional_lines = lines.each_index.select do |i|
  lines[i].include?("build.with?(\"#{FEATURE_NAME}\")")
end
check(conditional_lines.length == 1,
      "the conditional `build.with?(\"#{FEATURE_NAME}\")` appears exactly once",
      "expected one `build.with?(\"#{FEATURE_NAME}\")`, found #{conditional_lines.length}")

if conditional_lines.length == 1 && begin_idx && end_idx && install_idx
  cond_idx = conditional_lines.first
  check(cond_idx > install_idx,
        "the conditional lives inside `def install`",
        "the conditional is not inside `def install`")
  check(cond_idx < begin_idx || cond_idx > end_idx,
        "the conditional lives outside the generated region",
        "the conditional lives inside the generated region and would be destroyed on regeneration")
end

feature_literals = lines.count { |l| l.include?("\"#{FEATURE_FLAG}\", \"#{FEATURE_NAME}\"") }
check(feature_literals == 1,
      "the `#{FEATURE_FLAG} #{FEATURE_NAME}` argument pair is written exactly once in the source",
      "expected one `#{FEATURE_FLAG}, #{FEATURE_NAME}` literal pair, found #{feature_literals}")

puts
if @failed
  warn "Formula option/HEAD-contract tests FAILED"
  exit 1
end
puts "Formula option/HEAD-contract tests passed"
