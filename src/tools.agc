## Running gcc and clang-tidy on one translation unit and turning what they print into findings.

import Commands from "commands"
import Diagnostics from "diagnostics"
import {Finding, ToolError} from "findings"
import {Options} from "options"
import Paths from "paths"
import Scan from "scan"
import ToolKind from "tool_kind"
import {Tool} from "tool_kind"
import UnitReader from "unit"
import {Unit} from "unit"

# Flags before the user's: a database made for gcc has flags that clang does not know, and it would stop with an error.
# clang-tidy turns no warning into an error, whatever the .clang-tidy of the project says: a failed run is a
# tool error.
CLANG_FLAGS = [
  "--warnings-as-errors=-*",
  "--extra-arg-before=-Wno-unknown-warning-option",
  "--extra-arg-before=-Wno-unknown-argument",
]

# After the flags of the database: a `-Werror` there would make every warning of the build an error of the tool. The
# analyzer warnings named with `-Werror=analyzer-...` stay errors, and cchecker reports them as findings.
NO_ERROR = "-Wno-error"

# What `timeout` gets to stop the whole process group after it sent the signal: gcc runs cc1 and as as its children,
# and a
# child that outlives its parent would keep running after a timeout.
KILL_AFTER_S = 2

# The flags of the AST dump for the rules, after those of the build: no warnings (the build may have -Werror), and the
# annotations of cchecker.h as attributes whose JSON keeps their text (see cchecker.h).
AST_FLAGS = ["-w", "-DCCHECKER_AST"]

# The JSON AST of a file is tens of MiB, more than `Process.output` holds: a shell writes it to a file.
DUMP_SCRIPT = "exec \"$0\" \"$@\" > \"$CCHECKER_DUMP\""

# The time a wrapped run has beyond the timeout for the kill and the exit, so `timeout` ends the run before
# cchecker does.
WRAPPER_MS = 6_000

## One tool on one translation unit. `shown` is the path of the file in the report. `wrapped` runs the tool under
## `timeout`, which stops the children of the tool too. A job of the rules writes the AST to `dump` and keeps the
## declarations of the files under `cwd`.
export struct Job
  tool: Tool
  entry: Commands.Entry
  options: Options
  shown: String
  wrapped: Bool
  dump: String = ""
  cwd: String = ""
end

## What a job found, and what kept it from finding more. A job of the rules finds nothing alone: it gives the unit
## that the rules check with the units of the other files, and the count of declarations too large to read that named
## no function.
export struct Outcome
  findings: List[Finding]
  errors: List[ToolError]
  units: List[Unit] = []
  skipped_declarations: Int = 0
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

## Returns whether `timeout` of coreutils is installed. Without it a timeout stops the tool but not its children.
export def timeout_available?() -> Bool
  case Process.spawn_captured("timeout", ["--version"], ".", 5_000)
    ok(process) ->
      code = Process.wait(process, 5_000).unwrap_or(1)
      Process.close(process)
      return code == 0
    error(_) -> return false
  end
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

  if job.tool == Tool.Rules
    args = ["-c", DUMP_SCRIPT, command].concat(args)
    command = "sh"
    env = env.put("CCHECKER_DUMP", job.dump)
  end

  process = try start(command, args, job.entry.directory, timeout_ms, program, env)
  output = try Process.output(process, timeout_ms)
  code = try Process.wait(process, timeout_ms)
  Process.close(process)
  if output.truncated
    return error("#{program} printed more than 1 MiB for #{job.entry.file}; narrow the checks or exclude the file")
  end

  done = outcome(job, "#{output.stdout}\n#{output.stderr}", code)
  if job.tool != Tool.Rules
    return ok(done)
  end

  # The dump is tens of MiB: it goes as soon as it is read, or when clang failed.
  read = with_unit(job, done)
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

def executable(job: Job) -> String
  case job.tool
    Tool.Gcc -> return job.options.gcc
    Tool.ClangTidy -> return job.options.clang_tidy
    Tool.Rules -> return job.options.clang
  end
end

# The outcome of a job of the rules with the declarations of the project in its dump, read into a unit, when clang
# ended well.
def with_unit(job: Job, done: Outcome) -> Result[Outcome]
  if not done.errors.empty?
    return ok(done)
  end

  dump = try Scan.project_decls(job.dump, job.entry.directory, job.cwd)
  decls = try JSON.parse(dump.decls)
  unit = try UnitReader.read(decls)
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

  # A lock mark that cannot be read would leave a rule off without a word.
  marks = unit.mark_errors.map do |message| ToolError(tool: "rules", file: job.entry.file, message: message) end

  return ok(
    done.with(
      units: [unit],
      errors: done.errors.concat(errors).concat(large).concat(marks),
      skipped_declarations: dump.skipped,
    ),
  )
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
  case Process.spawn_captured(command, args, directory, timeout_ms, env)
    ok(process) -> return ok(process)
    error(message) -> return error("cannot run #{program}: #{message}")
  end
end

def arguments(job: Job) -> List[String]
  entry = job.entry
  case job.tool
    Tool.Gcc ->
      return (
        ["-fanalyzer", "-fdiagnostics-color=never", "-fdiagnostics-path-format=none", "-fno-diagnostics-show-caret"]
          .concat(entry.args)
          .concat([NO_ERROR, "-c", entry.file, "-o", "/dev/null"])
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
        ["-Xclang", "-ast-dump=json", "-fsyntax-only", "-fno-color-diagnostics", "-Wno-unknown-warning-option"]
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

  if code != 0 and not (code == 1 and (not errors.empty? or (promoted > 0 and treated_as_errors?(text))))
    message = failure(job.wrapped, job.options.timeout_s, text, code)
    errors = errors.push(ToolError(tool: tool, file: job.entry.file, message: message + hint(job.tool, code)))
  end

  return Outcome(findings: findings, errors: errors)
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
