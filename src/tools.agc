## Running gcc and clang-tidy on one translation unit and turning what they print into findings.

import Commands from "commands"
import Diagnostics from "diagnostics"
import {Finding, ToolError} from "findings"
import {Options} from "options"
import Paths from "paths"

# Flags before the user's: a database made for gcc has flags that clang does not know, and it would stop with an error.
CLANG_QUIET = ["--extra-arg-before=-Wno-unknown-warning-option", "--extra-arg-before=-Wno-unknown-argument"]

## The tools cchecker runs.
export enum Tool
  Gcc
  ClangTidy
end

## One tool on one translation unit.
export struct Job
  tool: Tool
  entry: Commands.Entry
  options: Options
end

## What a job found, and what kept it from finding more.
export struct Outcome
  findings: List[Finding]
  errors: List[ToolError]
end

## Returns the name of the tool, as the findings and the `--tools` option spell it.
export def name(tool: Tool) -> String
  case tool
    Tool.Gcc -> return "gcc"
    Tool.ClangTidy -> return "clang-tidy"
  end
end

## Returns the tool of a name given to `--tools`.
export def named(text: String) -> Tool
  if text == "gcc"
    return Tool.Gcc
  end

  return Tool.ClangTidy
end

## Runs the job. An error is a tool that did not start or did not finish in time; a file that does not compile is an
## `Outcome` with an error in it. Findings keep the path the tool printed, made absolute.
export def run(job: Job) -> Result[Outcome]
  program = executable(job)
  timeout_ms = job.options.timeout_s * 1000
  process = try start(program, arguments(job), job.entry.directory, timeout_ms)
  output = try Process.output(process, timeout_ms)
  code = try Process.wait(process, timeout_ms)
  Process.close(process)
  if output.truncated
    return error("#{program} printed more than 1 MiB for #{job.entry.file}; narrow the checks or exclude the file")
  end

  return ok(outcome(job, "#{output.stdout}\n#{output.stderr}", code))
end

def executable(job: Job) -> String
  case job.tool
    Tool.Gcc -> return job.options.gcc
    Tool.ClangTidy -> return job.options.clang_tidy
  end
end

# LC_ALL=C keeps the messages in English with plain quotes, so a baseline holds on any machine.
def start(program: String, args: List[String], directory: String, timeout_ms: Int) -> Result[Process]
  case Process.spawn_captured(program, args, directory, timeout_ms, {"LC_ALL": "C"})
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
          .concat(["-c", entry.file, "-o", "/dev/null"])
      )
    Tool.ClangTidy ->
      return (
        ["--quiet", "--checks=#{job.options.checks}", "--header-filter=.*"]
          .concat(CLANG_QUIET)
          .concat([entry.file, "--"])
          .concat(entry.args)
      )
  end
end

def outcome(job: Job, text: String, code: Int) -> Outcome
  findings: List[Finding] = []
  errors: List[ToolError] = []
  tool = name(job.tool)
  for d in Diagnostics.parse(text)
    if compile_error?(d)
      errors = errors.push(ToolError(tool: tool, file: job.entry.file, message: where(job, d)))
    else
      findings = findings.push(finding(job, d))
    end
  end

  if code != 0 and findings.empty? and errors.empty?
    errors = errors.push(
      ToolError(tool: tool, file: job.entry.file, message: "exited with code #{code}: #{first_line(text)}"),
    )
  end

  return Outcome(findings: findings, errors: errors)
end

# An error without a check name is the compiler refusing the file; clang-tidy names those clang-diagnostic-error.
def compile_error?(d: Diagnostics.Diagnostic) -> Bool
  if d.severity == "warning"
    return false
  end

  case Diagnostics.option(d)
    some(option) -> return option.start_with?("clang-diagnostic")
    none -> return true
  end
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
    tool: name(job.tool),
    file: Paths.absolute(job.entry.directory, d.file).unwrap_or(d.file),
    line: d.line,
    column: d.column,
    message: d.message.split(" ").select do |word| word != "" end.join(" "),
  )
end

# gcc -Wanalyzer-malloc-leak is CC-GCC-ANALYZER-MALLOC-LEAK; clang-analyzer-unix.Malloc is
# CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC. A diagnostic with no name is CC-GCC-WARNING or CC-TIDY-WARNING.
def code_of(tool: Tool, option: Optional[String]) -> String
  case tool
    Tool.Gcc ->
      text = option.unwrap_or("-WWARNING")
      return "CC-GCC-" + text.slice(2, text.length - 2).replace("=", "").upcase
    Tool.ClangTidy -> return "CC-TIDY-" + option.unwrap_or("WARNING").replace(".", "-").upcase
  end
end

# The line that says why a tool stopped: the first error, else the first line.
def first_line(text: String) -> String
  lines = text.split("\n").map do |line| line.strip end.select do |line| line != "" end
  if lines.empty?
    return "no output"
  end

  errors = lines.select do |line| line.include?("error") end
  if errors.empty?
    return lines.first
  end

  return errors.first
end
