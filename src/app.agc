## One run of cchecker: the files, the tools on each, the baseline and the report.

import Baseline from "baseline"
import Commands from "commands"
import Effects from "effects"
import Findings from "findings"
import {Finding, ToolError} from "findings"
import {Options} from "options"
import Paths from "paths"
import Report from "report"
import ToolKind from "tool_kind"
import {Tool} from "tool_kind"
import Tools from "tools"
import {Unit} from "unit"

# The compile database that a run without FILE or -p reads.
DEFAULT_DATABASE = "compile_commands.json"

# What the tools made of all the jobs, before the paths are shortened and the repeats taken out.
struct Collected
  findings: List[Finding]
  errors: List[ToolError]
  ran: List[String]
end

# The jobs of a run, the files that were left out because they are outside the working directory, and the entries of
# the database that are not C files (they are not run, and so a run of the database is not a run of all its files).
struct Plan
  jobs: List[Tools.Job]
  skipped: List[String]
  ignored: List[String]
end

## Runs the tools, prints the report and returns the exit code: 0 for no new findings, 1 for new ones, 2 for an error
## of a tool. A setup error (no files, a bad baseline) is an `error`.
export def run(options: Options) -> Result[Int]
  cwd = try Paths.working_directory()
  accepted = try baseline_entries(options)
  entries = try gather(options)
  scratch = scratch_path()
  plan = try plan_for(options, entries, cwd, scratch)
  if plan.jobs.empty?
    return error("no C files to check")
  end

  if not plan.skipped.empty?
    IO.warn(skipped_line(plan.skipped))
    if options.update_baseline
      return error("the baseline is not updated: files of the database were not run, and it would lose their findings")
    end
  end

  collected = try collect_in_scratch(options, plan.jobs, scratch)
  findings = (
    collected.findings
    |> localize(cwd, options.exclude)
    |> Findings.unique()
    |> Findings.sort()
  )

  scope = scope_of(options, plan, collected)
  case options.baseline
    some(path) ->
      if options.update_baseline
        return update(path, accepted, scope, findings, collected.errors, options)
      end

      split = Baseline.split(findings, accepted, scope)
      return ok(
        finish(
          options,
          Report.Report(
            findings: split.new_findings,
            baselined: split.accepted,
            fixed: split.fixed,
            errors: collected.errors,
            skipped: plan.skipped.size,
          ),
        ),
      )
    none ->
      return ok(
        finish(
          options,
          Report.Report(
            findings: findings,
            baselined: 0,
            fixed: 0,
            errors: collected.errors,
            skipped: plan.skipped.size,
          ),
        ),
      )
  end
end

# The accepted findings, read before any tool runs so that a baseline that cannot be read costs no time. A baseline
# that is not there yet is empty when it is about to be written.
def baseline_entries(options: Options) -> Result[List[Baseline.Entry]]
  case options.baseline
    some(path) ->
      if options.update_baseline and not File.stat(path).ok?
        return ok([])
      end

      return Baseline.load(path)
    none -> return ok([])
  end
end

# Writes the baseline when every tool ran: a baseline made from a half run would accept less than the project has. The
# entries of the tools and files that the run did not cover stay as they were.
def update(
  path: String,
  accepted: List[Baseline.Entry],
  scope: Baseline.Scope,
  findings: List[Finding],
  errors: List[ToolError],
  options: Options,
) -> Result[Int]
  if not errors.empty?
    return ok(finish(options, Report.Report(findings: [], baselined: 0, fixed: 0, errors: errors, skipped: 0)))
  end

  entries = Baseline.merged(accepted, scope, findings)
  try Baseline.write(path, entries)
  puts("cchecker: wrote #{entries.reduce(0) do |total, entry| total + entry.count end} findings to #{path}")
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
# its name; any other file of the database is ignored).
# Excluded files are not run. Files outside the working directory are not run either, as their findings would be
# dropped, and the report says so.
def plan_for(options: Options, entries: List[Commands.Entry], cwd: String, scratch: String) -> Result[Plan]
  wrapped = Tools.timeout_available?()
  jobs: List[Tools.Job] = []
  skipped: List[String] = []
  ignored: List[String] = []
  for entry in entries
    path = try Paths.absolute(entry.directory, entry.file)
    if not (options.files.include?(entry.file) or entry.file.end_with?(".c"))
      ignored = ignored.push(entry.file)
      next
    end

    case Paths.inside(cwd, path)
      none -> skipped = skipped.push(entry.file)
      some(shown) ->
        if not Paths.excluded?(cwd, shown, options.exclude)
          for tool in options.tools
            dump = dump_path(tool, scratch, jobs.size)
            jobs = jobs.push(
              Tools.Job(
                tool: tool,
                entry: entry,
                options: options,
                shown: shown,
                wrapped: wrapped,
                dump: dump,
                cwd: cwd,
              ),
            )
          end
        end
    end
  end

  return ok(Plan(jobs: jobs, skipped: skipped, ignored: ignored))
end

# The file where a job of the rules writes the AST; the other tools write none.
def dump_path(tool: Tool, scratch: String, n: Int) -> String
  if tool == Tool.Rules
    return "#{scratch}/#{n}.json"
  end

  return ""
end

def skipped_line(skipped: List[String]) -> String
  count = skipped.size
  word = "files"
  if count == 1
    word = "file"
  end

  return "cchecker: skipped #{count} #{word} outside the working directory: #{skipped.take(5).join(", ")}"
end

# What the run covered, for the baseline: its tools, the files each tool ended well on, and every file when it ran all
# the files of a database and every job ended well.
def scope_of(options: Options, plan: Plan, collected: Collected) -> Baseline.Scope
  return Baseline.Scope(
    tools: Set.new(options.tools.map do |tool| ToolKind.name(tool) end),
    pairs: Set.new(collected.ran),
    full: (
      options.files.empty? and
      options.exclude.empty? and
      plan.skipped.empty? and
      plan.ignored.empty? and
      collected.errors.empty?
    ),
  )
end

# The folder of the AST dumps of a run: only this run uses it, and it is removed when the jobs end.
def scratch_path() -> String
  base = System.env("TMPDIR").unwrap_or("/tmp")
  if base == ""
    base = "/tmp"
  end

  return "#{base}/cchecker-#{System.pid()}-#{Time.now_ms()}"
end

# Runs the jobs, with the folder of the dumps when the rules run. The rules check the units of all the files at once.
def collect_in_scratch(options: Options, jobs: List[Tools.Job], folder: String) -> Result[Collected]
  if not options.tools.include?(Tool.Rules)
    return ok(collect(options, jobs))
  end

  try Dir.mkdir_private(folder)
  collected = collect(options, jobs)
  _ = Path.remove(folder)
  return ok(collected)
end

def collect(options: Options, jobs: List[Tools.Job]) -> Collected
  results = Task.map(jobs, options.jobs, Tools.limit_ms(options), &Tools.run)
  findings: List[Finding] = []
  errors: List[ToolError] = []
  ran: List[String] = []
  units: List[Unit] = []
  for i in 0...jobs.size
    job = jobs[i]
    case results[i]
      ok(outcome) ->
        findings = findings.concat(outcome.findings)
        errors = errors.concat(outcome.errors)
        units = units.concat(outcome.units)
        if outcome.errors.empty?
          ran = ran.push(Baseline.pair(ToolKind.name(job.tool), job.shown))
        end

      error(message) ->
        errors = errors.push(ToolError(tool: ToolKind.name(job.tool), file: job.entry.file, message: message))
    end
  end

  return Collected(findings: findings.concat(Effects.check(units)), errors: errors, ran: ran)
end

# Shortens the paths to be relative to the working directory, and drops what is outside it (system and third-party
# headers) or excluded.
def localize(findings: List[Finding], cwd: String, exclude: List[String]) -> List[Finding]
  kept: List[Finding] = []
  for f in findings
    shown = Paths.inside(cwd, f.file)
    if shown.some? and not Paths.excluded?(cwd, shown.unwrap!, exclude)
      kept = kept.push(f.with(file: shown.unwrap!))
    end
  end

  return kept
end
