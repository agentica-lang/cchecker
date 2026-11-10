## Running gcc and clang-tidy on one translation unit and turning what they print into findings.

import Commands from "commands"
import Diagnostics from "diagnostics"
import {Finding, ToolError, UncheckedFile} from "findings"
import {Options} from "options"
import Paths from "paths"
import Scan from "scan"
import ToolKind from "tool_kind"
import {Tool} from "tool_kind"
import UnitReader from "unit"
import {Unit} from "unit"

# Flags before the user's: a database made for gcc has flags that clang does not know, and it would stop with an error.
# clang-tidy turns no warning into an error and prints no colours, whatever the .clang-tidy of the project says: a
# failed run is a tool error, and a coloured line is not read (see `Diagnostics.unparsed`).
CLANG_FLAGS = [
  "--warnings-as-errors=-*",
  "--use-color=false",
  "--extra-arg-before=-Wno-unknown-warning-option",
  "--extra-arg-before=-Wno-unknown-argument",
]

# After the flags of the database: a `-Werror` there would make every warning of the build an error of the tool. The
# analyzer warnings named with `-Werror=analyzer-...` stay errors, and cchecker reports them as findings. A
# `-fdiagnostics-color=always` or `-fdiagnostics-urls=always` there would print escape sequences, and a line with one
# is not read (see `Diagnostics.unparsed`).
GCC_AFTER = ["-Wno-error", "-fdiagnostics-color=never", "-fdiagnostics-urls=never"]

# What `timeout` gets to stop the whole process group after it sent the signal: gcc runs cc1 and as as its children,
# and a
# child that outlives its parent would keep running after a timeout.
KILL_AFTER_S = 2

# The flags that choose the target of a compile command, alone or with the value after them.
TARGET_FLAGS = Set.new(["-m32", "-m64", "-mx32", "-m16"])
TARGET_PAIRS = Set.new(["-target", "--target", "-arch"])

# The flags of the AST dump for the rules, after those of the build: no warnings (the build may have -Werror), no
# colours (the build may have -fcolor-diagnostics), and the annotations of cchecker.h as attributes whose JSON keeps
# their text (see cchecker.h).
AST_FLAGS = ["-w", "-fno-color-diagnostics", "-DCCHECKER_AST"]

# The JSON AST of a file is tens of MiB, more than `Process.output` holds: a shell writes it into a FIFO, which
# `Scan.compact` copies to the dump file (see there).
DUMP_SCRIPT = "exec \"$0\" \"$@\" > \"$CCHECKER_FIFO\""

# How gcc and clang end the message of an `#include` they did not find.
GCC_MISSING = ": No such file or directory"
CLANG_MISSING = "' file not found"

# How much of a diagnostic line that cchecker cannot read its tool error shows, in characters.
STRAY_SHOWN = 200

# The time a wrapped run has beyond the timeout for the kill and the exit, so `timeout` ends the run before
# cchecker does.
WRAPPER_MS = 6_000

## One tool on one translation unit. `shown` is the path of the file in the report. `wrapped` runs the tool under
## `timeout`, which stops the children of the tool too. A job of the rules writes the AST to `dump` and keeps the
## declarations of the files under `cwd`. `acquires` and `releases` are the lock wrappers of `[assume]`.
export struct Job
  tool: Tool
  entry: Commands.Entry
  options: Options
  shown: String
  wrapped: Bool
  dump: String = ""
  cwd: String = ""
  budget: Optional[Budget] = none
  target: String = ""
  acquires: List[String] = []
  releases: List[String] = []
end

## How much of the kept AST the jobs of the rules parse and read at once, in MiB of its text: the parsed tree is
## some ten times the text, so a run with many large files at once would hold all their trees. A job takes its share
## (1 MiB for each MiB of text, at most all of it) before it parses and gives it back when its unit is read. `turn`
## lets one job take tokens at a time, so two jobs never wait on each other with half a share each.
export struct Budget
  turn: Channel[Int]
  tokens: Channel[Int]
  mib: Int
end

## What a job found, and what kept it from finding more. A job of the rules finds nothing alone: it gives the unit
## that the rules check with the units of the other files, and the count of declarations too large to read that name
## no function. `unchecked` names the file when a header it includes is not found: the job then has no findings and
## no errors.
export struct Outcome
  findings: List[Finding]
  errors: List[ToolError]
  units: List[Unit] = []
  skipped_declarations: Int = 0
  unchecked: List[UncheckedFile] = []
end

# What a diagnostic of a tool is for cchecker.
enum Verdict
  Report
  Failure
  Ignore
end

## Returns the time in milliseconds after which nothing of a job is left to wait for.
export def limit_ms(options: Options) -> Int
  return options.timeout_s * 1000 + WRAPPER_MS + 5_000
end

## Returns a budget of `mib` MiB, all of it free.
export def budget(mib: Int) -> Budget
  turn: Channel[Int] = Channel.new(1)
  tokens: Channel[Int] = Channel.new(mib)
  _ = Channel.send(turn, 0, 1_000)
  for _ in 0...mib
    _ = Channel.send(tokens, 1, 1_000)
  end

  return Budget(turn: turn, tokens: tokens, mib: mib)
end

## Returns whether `timeout` of coreutils is installed. Without it a timeout stops the tool but not its children.
export def timeout_available?() -> Bool
  case Process.spawn_captured("timeout", ["--version"], Process.Options(timeout_ms: 5_000))
    ok(process) ->
      code = Process.wait(process, 5_000).unwrap_or(1)
      Process.close(process)
      return code == 0
    error(_) -> return false
  end
end

## Returns the triple of clang for the flags of a compile command (`x86_64-pc-linux-gnu`), from the flags that choose
## the target; "" when `clang` does not say.
export def target_of(clang: String, entry: Commands.Entry) -> String
  args = ["-print-target-triple"].concat(target_flags(entry.args))
  case Process.spawn_captured(clang, args, Process.Options(timeout_ms: 5_000, chdir: entry.directory))
    ok(process) ->
      line = Process.read_line(process, 5_000).unwrap_or("")
      code = Process.wait(process, 5_000).unwrap_or(1)
      Process.close(process)
      if code != 0
        return ""
      end

      return line.strip
    error(_) -> return ""
  end
end

## Returns the name that the baseline gives the program of a tool: `gcc`, `clang-tidy`, and `clang` for the rules.
export def version_key(tool: Tool) -> String
  case tool
    Tool.Gcc -> return "gcc"
    Tool.ClangTidy -> return "clang-tidy"
    Tool.Rules -> return "clang"
  end
end

## Returns the first line of what `--version` prints for the programs of the tools of `options` that `keys` names
## (see `version_key`), by key. A program that does not start, fails, or prints nothing has no entry.
export def versions_of(options: Options, keys: List[String]) -> Map[String, String]
  found: Map[String, String] = {}
  for tool in options.tools
    key = version_key(tool)
    if keys.include?(key)
      line = version_line(program_of(options, tool))
      if line != ""
        found = found.put(key, line)
      end
    end
  end

  return found
end

## Returns the flags of a compile command that choose its target: `--target=`, `-target T`, `-arch A`, `-m32`, ...
export def target_flags(args: List[String]) -> List[String]
  found: List[String] = []
  i = 0
  while i < args.size
    arg = args[i]
    if TARGET_PAIRS.include?(arg) and i + 1 < args.size
      found = found.push(arg).push(args[i + 1])
      i += 1
    elsif arg.start_with?("--target=") or TARGET_FLAGS.include?(arg)
      found = found.push(arg)
    end

    i += 1
  end

  return found
end

## Runs the job. An error is a tool that did not start or did not finish in time; a file that does not compile is an
## `Outcome` with an error in it. Findings keep the path the tool printed, made absolute.
export def run(job: Job) -> Result[Outcome]
  program = executable(job)
  timeout_ms = job.options.timeout_s * 1000
  command = program
  args = arguments(job)
  env = {"LC_ALL": "C"}
  if job.wrapped
    command = "timeout"
    args = ["--kill-after=#{KILL_AFTER_S}", "#{job.options.timeout_s}", program].concat(args)
    timeout_ms += WRAPPER_MS
  end

  fifo = ""
  raws: List[String] = []
  copy_error = ""
  if job.tool == Tool.Rules
    fifo = fifo_path(job.dump)
    args = ["-c", DUMP_SCRIPT, command].concat(args)
    command = "sh"
    env = env.put("CCHECKER_FIFO", fifo)
    try Scan.fifo(fifo)
  end

  started = start(command, args, job.entry.directory, timeout_ms, program, env)
  if job.tool == Tool.Rules and not started.ok?
    _ = Path.remove(fifo)
  end

  process = try started
  if job.tool == Tool.Rules
    # The copy runs while clang writes. Its deadline starts with the call, so a wait for a thread of the compute
    # pool does not count. Past it, or on an error before clang opened the FIFO (where it may wait for good), clang
    # is stopped before the FIFO goes. On another error clang has the FIFO closed under it and ends by itself: its
    # own outcome is still read, and its failure comes first.
    copied = Profile.measure("clang") do Scan.compact(fifo, job.dump, timeout_ms) end
    case copied
      ok(found) -> raws = found
      error(message) ->
        _ = Path.remove(job.dump)
        if message == Scan.TIMED_OUT or message.start_with?(Scan.UNSTARTED)
          Process.close(process)
          _ = Path.remove(fifo)
          return error(message)
        end

        copy_error = message
    end

    _ = Path.remove(fifo)
  end

  read_output = Profile.measure("clang") do Process.output(process, timeout_ms) end
  if not read_output.ok?
    Process.close(process)
  end

  output = try read_output
  code = try Process.wait(process, timeout_ms)
  Process.close(process)
  if output.truncated
    return error("#{program} printed more than 1 MiB for #{job.entry.file}; narrow the checks or exclude the file")
  end

  done = outcome(job, "#{output.stdout}\n#{output.stderr}", code)
  if job.tool != Tool.Rules
    return ok(done)
  end

  if copy_error != ""
    copy_failed = ToolError(tool: "rules", file: job.entry.file, message: copy_error)
    return ok(done.with(errors: done.errors.push(copy_failed)))
  end

  # The dump of a file whose header is not found is the part before the #include: nothing to read.
  if not done.unchecked.empty?
    _ = Path.remove(job.dump)
    return ok(done)
  end

  # The dump is tens of MiB: it goes as soon as it is read, or when clang failed.
  read = with_unit(job, done, raws)
  _ = Path.remove(job.dump)
  return read
end

## Returns the code of a diagnostic: `-Wanalyzer-malloc-leak` of gcc is CC-GCC-ANALYZER-MALLOC-LEAK, and the check
## `clang-analyzer-unix.Malloc` is CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC. A diagnostic with no name is CC-GCC-WARNING or
## CC-TIDY-WARNING.
export def code_of(tool: Tool, option: Optional[String]) -> String
  case tool
    Tool.Gcc -> return "CC-GCC-" + plain_option(option.unwrap_or("-WWARNING")).replace("=", "").upcase
    Tool.ClangTidy -> return "CC-TIDY-" + option.unwrap_or("WARNING").replace(".", "-").upcase
    # Never asked: the dump of the rules reports no diagnostic of clang, only its errors (see `verdict`).
    Tool.Rules -> return "CC-CLANG-" + plain_option(option.unwrap_or("-WWARNING")).upcase
  end
end

## Returns why a run with a non-zero exit code failed. Under `timeout` the code 124 is the timeout and 137 is the kill
## after it, but a tool that kills itself or is killed from outside (the OOM killer) gives the same codes, so the text
## says both.
export def failure(wrapped: Bool, timeout_s: Int, text: String, code: Int) -> String
  if wrapped and code == 124
    return "was stopped after #{timeout_s} seconds, or ended by itself with code 124"
  end

  if wrapped and code == 137
    return "was killed: it did not end in #{timeout_s} seconds, or a signal ended it"
  end

  return "exited with code #{code}: #{first_line(text)}"
end

## Returns the line that says why a tool stopped: a fatal error (gcc says so when cc1 is killed), else the first error,
## else the first line.
export def first_line(text: String) -> String
  lines = text.split("\n").map do |line| line.strip end.select do |line| line != "" end
  if lines.empty?
    return "no output"
  end

  for marker in ["fatal error:", "error"]
    found = lines.select do |line| line.include?(marker) end
    if not found.empty?
      return found.first
    end
  end

  return lines.first
end

## Returns the path of the FIFO that clang writes the dump into: the dump's, `N.fifo` for `N.json`.
export def fifo_path(dump: String) -> String
  return "#{dump.slice(0, dump.length - ".json".length)}.fifo"
end

def executable(job: Job) -> String
  return program_of(job.options, job.tool)
end

def program_of(options: Options, tool: Tool) -> String
  case tool
    Tool.Gcc -> return options.gcc
    Tool.ClangTidy -> return options.clang_tidy
    Tool.Rules -> return options.clang
  end
end

# The first line of `PROGRAM --version`, or "" when it does not say. The C locale keeps the text the same from one
# machine to the next. The timeout of `spawn_captured` is not documented as a kill, so `close` ends a program that
# is still running, and the waits are short: the first line is out by then.
def version_line(program: String) -> String
  case Process.spawn_captured(program, ["--version"], Process.Options(timeout_ms: 5_000, env: {"LC_ALL": "C"}))
    ok(process) ->
      line = Process.read_line(process, 5_000).unwrap_or("")
      code = Process.wait(process, 1_000).unwrap_or(1)
      Process.close(process)
      if code != 0
        return ""
      end

      return line.strip
    error(_) -> return ""
  end
end

# The outcome of a job of the rules with the declarations of the project in its dump, read into a unit, when clang
# ended well. `raws` are the files that the dump names.
def with_unit(job: Job, done: Outcome, raws: List[String]) -> Result[Outcome]
  if not done.errors.empty?
    return ok(done)
  end

  scanned = Profile.measure("scan") do Scan.decls_in(job.dump, raws, job.entry.directory, job.cwd) end
  dump = try scanned
  share = 0
  timeout_ms = job.options.timeout_s * 1000
  if job.budget.some?
    b = job.budget.unwrap!
    share = try take(b, (dump.decls.length / 1_048_576 + 1).clamp(1, b.mib), timeout_ms)
  end

  read = parse_and_read(dump.decls, job.acquires, job.releases)
  if job.budget.some?
    give_back(job.budget.unwrap!, share)
  end

  unit = try read
  # A declaration too large to keep leaves the graph incomplete: the run says so, and the rest is checked.
  errors = dump.oversized.map do |name|
    ToolError(
      tool: "rules",
      file: job.entry.file,
      message: "#{name} is too large to read, so its calls are not followed",
    )
  end

  # A function too large for the path rules is not checked by them: the run says so.
  large = unit.too_large.map do |name|
    ToolError(tool: "rules", file: job.entry.file, message: "#{name} is too large for the path rules")
  end

  # A lock mark that cannot be read would leave a rule off without a word. The error names the file of the mark (as
  # the file of the job is named: relative to its folder when the database gives it so), so that one in a shared
  # header is told once (`App.collect` drops the repeats).
  source = Paths.absolute(job.entry.directory, job.entry.file).unwrap_or(job.entry.file)
  marks = unit.mark_errors.map do |e|
    file = e.file
    if file == "" or file == source
      file = job.entry.file
    elsif not job.entry.file.start_with?("/")
      file = Paths.inside(job.entry.directory, file).unwrap_or(file)
    end

    ToolError(tool: "rules", file: file, message: e.message)
  end

  return ok(
    done.with(
      units: [unit.with(target: job.target)],
      errors: done.errors.concat(errors).concat(large).concat(marks),
      skipped_declarations: dump.skipped,
    ),
  )
end

# The unit of the kept declarations.
def parse_and_read(decls: String, acquires: List[String], releases: List[String]) -> Result[Unit]
  parsed = Profile.measure("json") do JSON.parse(decls) end
  tree = try parsed
  return Profile.measure("unit") do UnitReader.read_with(tree, acquires, releases) end
end

# Takes `share` MiB of the budget, waiting for jobs that hold it; an error when they do not give it back in time.
def take(b: Budget, share: Int, timeout_ms: Int) -> Result[Int]
  _ = try Channel.recv(b.turn, timeout_ms)
  taken = 0
  while taken < share
    case Channel.recv(b.tokens, timeout_ms)
      ok(_) -> taken += 1
      error(message) ->
        give_back(b, taken)
        _ = Channel.send(b.turn, 0, timeout_ms)
        return error("the reading of the AST waited too long: #{message}")
    end
  end

  _ = Channel.send(b.turn, 0, timeout_ms)
  return ok(taken)
end

def give_back(b: Budget, share: Int) -> Void
  for _ in 0...share
    _ = Channel.send(b.tokens, 1, 1_000)
  end
end

# LC_ALL=C keeps the messages in English with plain quotes, so a baseline holds on any machine.
def start(
  command: String,
  args: List[String],
  directory: String,
  timeout_ms: Int,
  program: String,
  env: Map[String, String],
) -> Result[Process]
  case Process.spawn_captured(command, args, Process.Options(timeout_ms: timeout_ms, chdir: directory, env: env))
    ok(process) -> return ok(process)
    error(message) -> return error("cannot run #{program}: #{message}")
  end
end

def arguments(job: Job) -> List[String]
  entry = job.entry
  case job.tool
    Tool.Gcc ->
      return (
        ["-fanalyzer", "-fdiagnostics-path-format=none", "-fno-diagnostics-show-caret"]
          .concat(entry.args)
          .concat(GCC_AFTER)
          .concat(["-c", entry.file, "-o", "/dev/null"])
      )
    Tool.ClangTidy ->
      return (
        ["--quiet", "--checks=#{job.options.checks}", "--header-filter=.*"]
          .concat(CLANG_FLAGS)
          .concat([entry.file, "--"])
          .concat(entry.args)
      )
    Tool.Rules ->
      return (
        ["-Xclang", "-ast-dump=json", "-fsyntax-only", "-Wno-unknown-warning-option"]
          .concat(entry.args)
          .concat(AST_FLAGS)
          .concat([entry.file])
      )
  end
end

# A run that exits with a non-zero code is a tool error, unless the code is 1 and the output says why: a
# diagnostic that
# is an error, or a finding that -Werror made an error.
def outcome(job: Job, text: String, code: Int) -> Outcome
  findings: List[Finding] = []
  errors: List[ToolError] = []
  promoted = 0
  tool = ToolKind.name(job.tool)
  for d in Diagnostics.parse(text)
    case verdict(job.tool, d)
      Verdict.Report ->
        findings = findings.push(finding(job, d))
        if d.severity != "warning"
          promoted += 1
        end

      Verdict.Failure -> errors = errors.push(ToolError(tool: tool, file: job.entry.file, message: where(job, d)))
      Verdict.Ignore -> next
    end
  end

  # A missing header stops the compiler before it reads the rest: the file is not checked, and the run goes on.
  missing = Diagnostics.parse(text).flat_map do |d| missing_header(d) end
  if code != 0 and not missing.empty?
    return Outcome(findings: [], errors: [], unchecked: [UncheckedFile(file: job.shown, missing: missing.first)])
  end

  if code != 0 and not (code == 1 and (not errors.empty? or (promoted > 0 and treated_as_errors?(text))))
    message = failure(job.wrapped, job.options.timeout_s, text, code)
    errors = errors.push(ToolError(tool: tool, file: job.entry.file, message: message + hint(job.tool, code)))
  end

  # A diagnostic that cchecker cannot read may be a finding: the run must not look clean.
  strays = Diagnostics.unparsed(text)
  if not strays.empty?
    first = strays.first
    if first.length > STRAY_SHOWN
      first = first.slice(0, STRAY_SHOWN) + "..."
    end

    message = "printed diagnostic lines that cchecker cannot read (#{strays.size}), the first: #{first}"
    errors = errors.push(ToolError(tool: tool, file: job.entry.file, message: message))
  end

  return Outcome(findings: findings, errors: errors)
end

# The header of an `#include` that the compiler did not find, as gcc (`x.h: No such file or directory`) and clang
# (`'x.h' file not found`) say it in the C locale; empty for any other diagnostic.
def missing_header(d: Diagnostics.Diagnostic) -> List[String]
  if d.severity == "warning"
    return []
  end

  if d.message.end_with?(GCC_MISSING)
    return [d.message.slice(0, d.message.length - GCC_MISSING.length)]
  end

  if d.message.start_with?("'") and d.message.end_with?(CLANG_MISSING)
    return [d.message.slice(1, d.message.length - CLANG_MISSING.length - 1)]
  end

  return []
end

# The shell gives 127 for a program it cannot find. The rules are on by default, so a missing clang says how to go
# without them.
def hint(tool: Tool, code: Int) -> String
  if tool == Tool.Rules and code == 127
    return " (install clang or name it with --clang, or leave the rules out with --tools gcc,clang-tidy)"
  end

  return ""
end

# gcc reports its analyzer only. Its other warnings come from the flags of the build (-Wall), and clang-tidy leaves
# those out as well. An error is the compiler refusing the file, whatever its name: gcc 14 refuses an implicit
# declaration with [-Wimplicit-function-declaration]. An analyzer warning that -Werror made an error is still
# a finding.
def verdict(tool: Tool, d: Diagnostics.Diagnostic) -> Verdict
  failed = d.severity != "warning"
  case tool
    Tool.Gcc ->
      if analyzer?(Diagnostics.option(d))
        return Verdict.Report
      end

      if failed
        return Verdict.Failure
      end

      return Verdict.Ignore
    Tool.ClangTidy ->
      if failed
        return Verdict.Failure
      end

      return Verdict.Report
    Tool.Rules ->
      if failed
        return Verdict.Failure
      end

      return Verdict.Ignore
  end
end

def analyzer?(option: Optional[String]) -> Bool
  case option
    some(text) -> return plain_option(text).start_with?("analyzer-")
    none -> return false
  end
end

# The option without the -W, and without the -Werror= and -Wno-error= that gcc puts in front of a promoted warning.
def plain_option(option: String) -> String
  for prefix in ["-Werror=", "-Wno-error=", "-W"]
    if option.start_with?(prefix)
      return option.slice(prefix.length, option.length - prefix.length)
    end
  end

  return option
end

# Whether gcc says that it ended the run on purpose because of -Werror. A cc1 that was killed after it printed such an
# error prints a fatal error instead and exits 1 as well, and its output is not a whole run. With `-Wno-error` after
# the flags only the "some" line can come (the analyzer warnings named with `-Werror=analyzer-...` stay errors); the
# "all" line is kept for a gcc that prints it anyway.
def treated_as_errors?(text: String) -> Bool
  return (
    text.include?("cc1: all warnings being treated as errors") or
    text.include?("cc1: some warnings being treated as errors")
  )
end

# The place of a diagnostic, short when it is in the folder the tool ran in.
def where(job: Job, d: Diagnostics.Diagnostic) -> String
  path = Paths.absolute(job.entry.directory, d.file).unwrap_or(d.file)
  shown = Paths.inside(job.entry.directory, path).unwrap_or(path)
  return "#{shown}:#{d.line}:#{d.column}: #{d.message}"
end

def finding(job: Job, d: Diagnostics.Diagnostic) -> Finding
  return Finding(
    code: code_of(job.tool, Diagnostics.option(d)),
    tool: ToolKind.name(job.tool),
    file: Paths.absolute(job.entry.directory, d.file).unwrap_or(d.file),
    line: d.line,
    column: d.column,
    message: d.message.split(" ").select do |word| word != "" end.join(" "),
  )
end
