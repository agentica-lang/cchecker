## One run of cchecker: the files, the tools on each, the baseline and the report.

import Baseline from "baseline"
import Commands from "commands"
import Findings from "findings"
import {Finding, ToolError} from "findings"
import {Options} from "options"
import Paths from "paths"
import Report from "report"
import Tools from "tools"

# The compile database that a run without FILE or -p reads.
DEFAULT_DATABASE = "compile_commands.json"

# A tool is stopped by its own timeout first, with a message that says so; the task's timeout is the last resort.
TASK_GRACE_MS = 5_000

# What the tools made of all the jobs, before the paths are shortened and the repeats taken out.
struct Collected
  findings: List[Finding]
  errors: List[ToolError]
end

## Runs the tools, prints the report and returns the exit code: 0 for no new findings, 1 for new ones, 2 for an error
## of a tool. A setup error (no files, a bad baseline) is an `error`.
export def run(options: Options) -> Result[Int]
  cwd = try Paths.working_directory()
  entries = try gather(options)
  jobs = try jobs_for(options, entries, cwd)
  if jobs.empty?
    return error("no C files to check")
  end

  collected = collect(options, jobs)
  findings = (
    collected.findings
    |> localize(cwd, options.exclude)
    |> Findings.unique()
    |> Findings.sort()
  )

  case options.baseline
    some(path) ->
      if options.update_baseline
        return update(path, findings, collected.errors, options)
      end

      accepted = try Baseline.load(path)
      split = Baseline.split(findings, accepted)
      return ok(
        finish(
          options,
          Report.Report(
            findings: split.new_findings,
            baselined: split.accepted,
            fixed: split.fixed,
            errors: collected.errors,
          ),
        ),
      )
    none ->
      return ok(finish(options, Report.Report(findings: findings, baselined: 0, fixed: 0, errors: collected.errors)))
  end
end

# Writes the baseline when every tool ran: a baseline made from a half run would accept less than the project has.
def update(path: String, findings: List[Finding], errors: List[ToolError], options: Options) -> Result[Int]
  if not errors.empty?
    return ok(finish(options, Report.Report(findings: [], baselined: 0, fixed: 0, errors: errors)))
  end

  try Baseline.write(path, findings)
  puts("cchecker: wrote #{findings.size} findings to #{path}")
  return ok(0)
end

def finish(options: Options, report: Report.Report) -> Int
  if options.json
    puts(Report.json(report))
  else
    puts(Report.text(report))
  end

  for line in Report.error_lines(report)
    IO.warn(line)
  end

  if not report.errors.empty?
    return 2
  end

  if not report.findings.empty?
    return 1
  end

  return 0
end

def gather(options: Options) -> Result[List[Commands.Entry]]
  case options.database
    some(path) -> return Commands.load(path)
    none -> return from_command_line(options)
  end
end

def from_command_line(options: Options) -> Result[List[Commands.Entry]]
  if not options.files.empty?
    return Commands.from_files(options.files, options.flags)
  end

  case File.stat(DEFAULT_DATABASE)
    ok(_) -> return Commands.load(DEFAULT_DATABASE)
    error(_) -> return error("give FILEs or a compile database (-p PATH): there is no #{DEFAULT_DATABASE} here")
  end
end

# One job for each tool and each C file of the database (a file named on the command line is checked whatever
# its name).
# Files that are outside the working directory or excluded are not run, as their findings would be dropped.
def jobs_for(options: Options, entries: List[Commands.Entry], cwd: String) -> Result[List[Tools.Job]]
  tools = options.tools.map do |name| Tools.named(name) end
  jobs: List[Tools.Job] = []
  for entry in entries
    path = try Paths.absolute(entry.directory, entry.file)
    wanted = options.files.include?(entry.file) or entry.file.end_with?(".c")
    shown = Paths.inside(cwd, path)
    if wanted and shown.some? and not excluded?(shown.unwrap!, options.exclude)
      for tool in tools
        jobs = jobs.push(Tools.Job(tool: tool, entry: entry, options: options))
      end
    end
  end

  return ok(jobs)
end

def collect(options: Options, jobs: List[Tools.Job]) -> Collected
  timeout_ms = options.timeout_s * 1000 + TASK_GRACE_MS
  results = Task.map(jobs, options.jobs, timeout_ms, &Tools.run)
  findings: List[Finding] = []
  errors: List[ToolError] = []
  for i in 0...jobs.size
    job = jobs[i]
    case results[i]
      ok(outcome) ->
        findings = findings.concat(outcome.findings)
        errors = errors.concat(outcome.errors)
      error(message) ->
        errors = errors.push(ToolError(tool: Tools.name(job.tool), file: job.entry.file, message: message))
    end
  end

  return Collected(findings: findings, errors: errors)
end

# Shortens the paths to be relative to the working directory, and drops what is outside it (system and third-party
# headers) or excluded.
def localize(findings: List[Finding], cwd: String, exclude: List[String]) -> List[Finding]
  kept: List[Finding] = []
  for f in findings
    shown = Paths.inside(cwd, f.file)
    if shown.some? and not excluded?(shown.unwrap!, exclude)
      kept = kept.push(f.with(file: shown.unwrap!))
    end
  end

  return kept
end

def excluded?(path: String, exclude: List[String]) -> Bool
  return exclude.any? do |prefix| path.start_with?(prefix) end
end
