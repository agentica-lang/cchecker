## The command line of cchecker.

import OP from "std/option_parser"
import {Opt, Kind} from "std/option_parser"

# The clang-tidy checks of a run without --checks: the path-sensitive analyzer families that find real bugs in C, and a
# few bugprone checks that are about C itself. Off because they only made noise on the Agentica VM and agentica-db (see
# the PR of phase 0): the insecureAPI checks (they ask for strlcpy in code that bounds its copies), deadcode (dead
# stores), bugprone-not-null-terminated-result (a length-based buffer is not a C string) and
# bugprone-multi-level-implicit-pointer-conversion (void ** into void * in FFI code). A .clang-tidy file of the
# project is
# applied first, and these checks come after it.
DEFAULT_CHECKS = (
  "-*,clang-analyzer-core.*,clang-analyzer-unix.*,clang-analyzer-security.*,-clang-analyzer-security.insecureAPI.*," +
  "bugprone-sizeof-expression,bugprone-integer-division,bugprone-suspicious-memory-comparison," +
  "bugprone-signed-char-misuse,bugprone-misplaced-widening-cast,bugprone-unused-return-value"
)

TOOLS = ["gcc", "clang-tidy"]

DESCRIPTION = <<~TEXT.strip
  Runs gcc -fanalyzer and clang-tidy on C files and prints their findings in one format.
  The files come from a compile database (-p, default compile_commands.json) or from the command line:
  cchecker [options] FILE... -- COMPILER-FLAGS...
  Exit codes: 0 no new findings, 1 new findings, 2 usage or tool error.
TEXT

OPTIONS = [
  Opt(name: "compile-commands", short: "p", metavar: "PATH", help: "compile database: a file or its folder"),
  Opt(name: "tools", short: "t", default: "gcc,clang-tidy", metavar: "LIST", help: "tools to run, comma separated"),
  Opt(
    name: "checks",
    metavar: "LIST",
    help: "clang-tidy checks, after those of .clang-tidy (default: see the README)",
  ),
  Opt(name: "jobs", short: "j", kind: Kind.Int, default: "4", min: some(1), max: some(256), help: "tool runs at once"),
  Opt(name: "timeout", kind: Kind.Int, default: "300", min: some(1), help: "seconds for one tool on one file"),
  Opt(name: "baseline", short: "b", metavar: "FILE", help: "findings to accept; only others are reported"),
  Opt(name: "update-baseline", kind: Kind.Flag, help: "write the baseline from the findings and exit 0"),
  Opt(name: "exclude", metavar: "LIST", help: "comma separated path prefixes to skip"),
  Opt(name: "gcc", default: "gcc", metavar: "PROGRAM", help: "the gcc to run"),
  Opt(name: "clang-tidy", default: "clang-tidy", metavar: "PROGRAM", help: "the clang-tidy to run"),
  Opt(name: "json", kind: Kind.Flag, help: "print one JSON object"),
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
  tools: List[String]
  checks: String
  jobs: Int
  timeout_s: Int
  baseline: Optional[String]
  update_baseline: Bool
  exclude: List[String]
  gcc: String
  clang_tidy: String
  json: Bool
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
    jobs: OP.int(parsed, "jobs"),
    timeout_s: OP.int(parsed, "timeout"),
    baseline: OP.optional_string(parsed, "baseline"),
    update_baseline: OP.flag(parsed, "update-baseline"),
    exclude: names(OP.optional_string(parsed, "exclude").unwrap_or("")),
    gcc: OP.string(parsed, "gcc"),
    clang_tidy: OP.string(parsed, "clang-tidy"),
    json: OP.flag(parsed, "json"),
  )

  problem = mistake(options)
  if problem != ""
    return error("cchecker: #{problem}\n#{hint()}")
  end

  return ok(options)
end

# Returns what is wrong with a combination of options that option_parser cannot tell, or "".
def mistake(options: Options) -> String
  if options.tools.empty?
    return "--tools needs at least one of #{TOOLS.join(" or ")}"
  end

  if options.update_baseline and not options.baseline.some?
    return "--update-baseline needs --baseline FILE"
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

def tool_list(text: String) -> Result[List[String]]
  tools = names(text)
  for tool in tools
    if not TOOLS.include?(tool)
      return error("cchecker: unknown tool '#{tool}', expected #{TOOLS.join(" or ")}\n#{hint()}")
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
