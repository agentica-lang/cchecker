## The command line of cchecker.

import OP from "std/option_parser"
import {Opt, Kind} from "std/option_parser"
import ToolKind from "tool_kind"
import {Tool} from "tool_kind"

# The clang-tidy checks of a run without --checks: the path-sensitive analyzer families that find real bugs in C, and a
# few bugprone checks that are about C itself.
# A .clang-tidy file of the project is applied first, and these checks come after it.
# Left out because they only made noise on the large C projects this was tried on (the PR of phase 0 has the numbers):
# the insecureAPI checks ask for strlcpy in code that bounds its copies; deadcode reports dead stores;
# bugprone-not-null-terminated-result flags a buffer that is built by length and is no C string;
# bugprone-multi-level-implicit-pointer-conversion flags void ** passed as void * in FFI code.
DEFAULT_CHECKS = (
  "-*,clang-analyzer-core.*,clang-analyzer-unix.*,clang-analyzer-security.*,-clang-analyzer-security.insecureAPI.*," +
  "bugprone-sizeof-expression,bugprone-integer-division,bugprone-suspicious-memory-comparison," +
  "bugprone-signed-char-misuse,bugprone-misplaced-widening-cast,bugprone-unused-return-value"
)

TOOLS = ["gcc", "clang-tidy", "rules"]

# The tool runs at once when the number of cores is not known.
DEFAULT_JOBS = 4

DESCRIPTION = <<~TEXT.strip
  Runs gcc -fanalyzer, clang-tidy and the rules of the annotations on C files and prints their findings in one format.
  The files come from a compile database (-p, default compile_commands.json) or from the command line:
  cchecker [options] FILE... -- COMPILER-FLAGS...
  Exit codes: 0 no new findings, 1 new findings, 2 usage or tool error.
TEXT

OPTIONS = [
  Opt(name: "compile-commands", short: "p", metavar: "PATH", help: "compile database: a file or its folder"),
  Opt(
    name: "tools",
    short: "t",
    default: "gcc,clang-tidy,rules",
    metavar: "LIST",
    help: "tools to run, comma separated",
  ),
  Opt(
    name: "checks",
    metavar: "LIST",
    help: "clang-tidy checks, after those of .clang-tidy (default: see docs/usage.md)",
  ),
  Opt(
    name: "jobs",
    short: "j",
    kind: Kind.Int,
    min: some(1),
    max: some(256),
    help: "tool runs at once (default: the number of cores)",
  ),
  Opt(name: "timeout", kind: Kind.Int, default: "300", min: some(1), help: "seconds for one tool on one file"),
  Opt(name: "baseline", short: "b", metavar: "FILE", help: "findings to accept; only others are reported"),
  Opt(name: "update-baseline", kind: Kind.Flag, help: "write the baseline from the findings and exit 0"),
  Opt(
    name: "strict-baseline",
    kind: Kind.Flag,
    help: "exit 1 when a whole run finds an entry of the baseline fixed (stale)",
  ),
  Opt(name: "exclude", metavar: "LIST", help: "comma separated files or folders to skip"),
  Opt(name: "gcc", default: "gcc", metavar: "PROGRAM", help: "the gcc to run"),
  Opt(name: "clang-tidy", default: "clang-tidy", metavar: "PROGRAM", help: "the clang-tidy to run"),
  Opt(name: "clang", default: "clang", metavar: "PROGRAM", help: "the clang that dumps the AST for the rules"),
  Opt(name: "json", kind: Kind.Flag, help: "print one JSON object"),
  Opt(
    name: "config",
    short: "c",
    metavar: "FILE",
    help: "the settings file (default: cchecker.toml, else [tool.cchecker] of agentica.toml)",
  ),
  Opt(name: "no-infer", kind: Kind.Flag, help: "no CC_SHORT roots from the callbacks of libuv calls"),
  Opt(name: "all-paths", kind: Kind.Flag, help: "a finding of the rules for each bad call a root reaches, not one"),
]

VALUE_LONG = Set.new(OPTIONS.select do |o| o.kind != Kind.Flag end.map do |o| o.name end)
VALUE_SHORT = Set.new(OPTIONS.select do |o| o.kind != Kind.Flag and o.short != "" end.map do |o| o.short end)

# The words before `--`, told apart: the FILEs and the words for option_parser.
struct Words
  files: List[String]
  options: List[String]
end

## What a run was asked to do.
export struct Options
  files: List[String]
  flags: List[String]
  database: Optional[String]
  tools: List[Tool]
  checks: String
  custom_checks: Bool
  jobs: Int
  timeout_s: Int
  baseline: Optional[String]
  update_baseline: Bool
  exclude: List[String]
  gcc: String
  clang_tidy: String
  clang: String
  json: Bool
  config: Optional[String] = none
  infer: Bool = true
  all_paths: Bool = false
  strict_baseline: Bool = false
end

## Returns the options of the command line, or the error to print: a usage error, or the help text.
export def parse(args: List[String]) -> Result[Options]
  words = args.take_while do |word| word != "--" end
  flags = args.drop(words.size + 1)
  split = tell_apart(words)
  files = split.files
  parser = OP.new("cchecker", DESCRIPTION, [], OPTIONS)
  parsed = try OP.parse(parser, split.options)
  tools = try tool_list(OP.string(parsed, "tools"))
  database = OP.optional_string(parsed, "compile-commands")
  options = Options(
    files: files,
    flags: flags,
    database: database,
    tools: tools,
    checks: OP.optional_string(parsed, "checks").unwrap_or(DEFAULT_CHECKS),
    custom_checks: OP.optional_string(parsed, "checks").some?,
    jobs: jobs_of(OP.optional_int(parsed, "jobs")),
    timeout_s: OP.int(parsed, "timeout"),
    baseline: OP.optional_string(parsed, "baseline"),
    update_baseline: OP.flag(parsed, "update-baseline"),
    exclude: names(OP.optional_string(parsed, "exclude").unwrap_or("")),
    gcc: OP.string(parsed, "gcc"),
    clang_tidy: OP.string(parsed, "clang-tidy"),
    clang: OP.string(parsed, "clang"),
    json: OP.flag(parsed, "json"),
    config: OP.optional_string(parsed, "config"),
    infer: not OP.flag(parsed, "no-infer"),
    all_paths: OP.flag(parsed, "all-paths"),
    strict_baseline: OP.flag(parsed, "strict-baseline"),
  )

  problem = mistake(options)
  if problem != ""
    return error("cchecker: #{problem}\n#{hint()}")
  end

  return ok(options)
end

# The jobs of -j, or the number of cores without it.
def jobs_of(given: Optional[Int]) -> Int
  case given
    some(jobs) -> return jobs
    none -> return cores()
  end
end

# The number of cores that are online, as `getconf` says it on Linux and macOS, or 4 when it cannot tell.
def cores() -> Int
  case Process.spawn_captured("getconf", ["_NPROCESSORS_ONLN"], ".", 5_000)
    ok(process) ->
      text = Process.read_line(process, 5_000).unwrap_or("")
      _ = Process.wait(process, 5_000)
      Process.close(process)
      return text.strip.to_i.unwrap_or(DEFAULT_JOBS).clamp(1, 256)
    error(_) -> return DEFAULT_JOBS
  end
end

# Returns what is wrong with a combination of options that option_parser cannot tell, or "".
def mistake(options: Options) -> String
  if options.tools.empty?
    return "--tools needs at least one of #{TOOLS.join(" or ")}"
  end

  if options.update_baseline and not options.baseline.some?
    return "--update-baseline needs --baseline FILE"
  end

  if options.strict_baseline and not options.baseline.some?
    return "--strict-baseline needs --baseline FILE"
  end

  if options.strict_baseline and options.update_baseline
    return "give one of --strict-baseline, --update-baseline: an update drops the stale entries"
  end

  if options.update_baseline and options.custom_checks
    return "--update-baseline needs the default --checks: a baseline made with fewer checks would lose the others"
  end

  if not options.files.empty? and options.database.some?
    return "give FILEs or --compile-commands, not both"
  end

  if options.files.empty? and not options.flags.empty?
    return "the flags after -- need at least one FILE"
  end

  return ""
end

def hint() -> String
  return "Try 'cchecker --help' for more information"
end

def tool_list(text: String) -> Result[List[Tool]]
  tools: List[Tool] = []
  for word in names(text).uniq
    case ToolKind.named(word)
      some(tool) -> tools = tools.push(tool)
      none -> return error("cchecker: unknown tool '#{word}', expected #{TOOLS.join(" or ")}\n#{hint()}")
    end
  end

  return ok(tools)
end

def names(text: String) -> List[String]
  return text.split(",").map do |name| name.strip end.select do |name| name != "" end
end

# option_parser has no variable-length positional argument, so the files are told apart here: a word that does not
# start with "-" and is not the value of the option before it.
def tell_apart(words: List[String]) -> Words
  files: List[String] = []
  options: List[String] = []
  value_next = false
  for word in words
    if value_next
      options = options.push(word)
      value_next = false
    elsif word.start_with?("-")
      options = options.push(word)
      value_next = takes_value?(word)
    else
      files = files.push(word)
    end
  end

  return Words(files: files, options: options)
end

def takes_value?(word: String) -> Bool
  if word.start_with?("--")
    return not word.include?("=") and VALUE_LONG.include?(word.slice(2, word.length - 2))
  end

  return word.length == 2 and VALUE_SHORT.include?(word.slice(1, 1))
end
