## One run of cchecker: the files, the tools on each, the baseline and the report.

import Baseline from "baseline"
import Commands from "commands"
import Config from "config"
import Effects from "effects"
import Findings from "findings"
import {Finding, ToolError} from "findings"
import {Options} from "options"
import Paths from "paths"
import Report from "report"
import Suppressions from "suppressions"
import ToolKind from "tool_kind"
import {Tool} from "tool_kind"
import Tools from "tools"
import Files from "files"
import {Unit} from "unit"

# The compile database that a run without FILE or -p reads.
DEFAULT_DATABASE = "compile_commands.json"

# The start of the name of the folder of the AST dumps of a run, in $TMPDIR.
SCRATCH_PREFIX = "cchecker-"

# The mode of that folder, 0700: only its user can read it.
PRIVATE_MODE = 448

# What the tools made of all the jobs, before the paths are shortened and the repeats taken out. `units` are the
# translation units of the rules, which also hold the CC_IGNORE of the functions.
struct Collected
  findings: List[Finding]
  errors: List[ToolError]
  ran: List[String]
  units: List[Unit]
  skipped_declarations: Int = 0
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
  config = try Config.load(options.config, cwd)
  if not options.json
    IO.warn("cchecker: settings: #{config.origin}")
  end

  accepted = try baseline_entries(options)
  entries = try gather(options)
  scratch = try scratch_path(cwd)
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

  collected = try collect_in_scratch(options, config, plan.jobs, scratch)
  if collected.skipped_declarations > 0
    IO.warn(
      "cchecker: skipped #{collected.skipped_declarations} declarations too large to read; " +
      "they named no function in their first million lines, but may name one past it",
    )
  end

  found = (
    collected.findings
    |> localize(cwd, options.exclude)
    |> Findings.unique()
  )

  # A suppression is unused only where the run covered its tool and file, as the baseline counts a fixed finding.
  scope = scope_of(options, plan, collected)

  # Only a run of the whole database sees every function: one of some files would miss the roots of the others.
  missing = Effects.missing_roots(collected.units, config)
  if scope.full and options.tools.include?(Tool.Rules) and not missing.empty?
    return error("#{config.origin}: no function of the compile database is named #{missing.join(", ")} ([roots])")
  end

  ignores = try ignores_of(found, plan, collected.units, cwd)
  applied = Suppressions.apply(found, ignores, scope.pairs)
  findings = Findings.sort(applied.findings)

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
            skipped_declarations: collected.skipped_declarations,
            suppressed: applied.suppressed,
            config: config.origin,
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
            skipped_declarations: collected.skipped_declarations,
            suppressed: applied.suppressed,
            config: config.origin,
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

  # An unused suppression is fixed by editing its comment, never accepted: the baseline could not tell when it goes.
  kept = findings.select do |f| f.code != Suppressions.UNUSED end
  entries = Baseline.merged(accepted, scope, kept)
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
#
# A finding of the rules comes from the call graph of all the files, so only a full run covers one: a run of some of
# the files sees part of the graph, and what it does not find is not fixed.
def scope_of(options: Options, plan: Plan, collected: Collected) -> Baseline.Scope
  full = (
    options.files.empty? and
    options.exclude.empty? and
    plan.skipped.empty? and
    plan.ignored.empty? and
    collected.errors.empty?
  )

  rules = Baseline.pair(ToolKind.name(Tool.Rules), "")
  return Baseline.Scope(
    tools: Set.new(options.tools.map do |tool| ToolKind.name(tool) end),
    pairs: Set.new(collected.ran.select do |pair| full or not pair.start_with?(rules) end),
    full: full,
  )
end

# The folder of the AST dumps of a run: only this run uses it, and it is removed when the jobs end. It is absolute, as
# clang runs in the folder of each file.
def scratch_path(cwd: String) -> Result[String]
  base = System.env("TMPDIR").unwrap_or("/tmp")
  if base == ""
    base = "/tmp"
  end

  folder = try Paths.absolute(cwd, base)
  return ok("#{folder}/#{SCRATCH_PREFIX}#{System.pid()}-#{Time.now_ms()}")
end

# Removes the folders that runs which were killed left next to `folder`: those whose process is gone, and which look
# like a folder that cchecker made: a directory (not a link) of this user, private (mode 0700), with nothing in it but
# dumps (`N.json`). Anything else of that name is left alone. A process is known to be gone only where /proc lists the
# running ones.
def remove_stale(folder: String) -> Void
  if not File.stat("/proc/self").ok?
    return
  end

  base = Paths.parent(folder)
  user = owner(folder)
  nothing: List[String] = []
  for name in Dir.list(base).unwrap_or(nothing)
    path = "#{base}/#{name}"
    if path != folder and stale?(name) and scratch?(path, user)
      _ = Path.remove(path)
    end
  end
end

# Whether a path is a folder of dumps of the user: a private directory, not a link, that holds only `N.json` files.
def scratch?(path: String, user: Int) -> Bool
  case File.lstat(path)
    ok(info) ->
      if info.kind != "directory" or info.user_id != user or info.mode % 4096 != PRIVATE_MODE
        return false
      end

    error(_) -> return false
  end

  nothing: List[String] = []
  return Dir.list(path).unwrap_or(nothing).all? do |name| dump_name?(name) end
end

def dump_name?(name: String) -> Bool
  return name.end_with?(".json") and name.slice(0, name.length - 5).to_i.ok?
end

# The user id of a file, not following a link, or -1.
def owner(path: String) -> Int
  case File.lstat(path)
    ok(info) -> return info.user_id
    error(_) -> return -1
  end
end

# Whether a name is that of a scratch folder, `cchecker-PID-MS`, whose process is gone.
def stale?(name: String) -> Bool
  if not name.start_with?(SCRATCH_PREFIX)
    return false
  end

  parts = name.slice(SCRATCH_PREFIX.length, name.length - SCRATCH_PREFIX.length).split("-")
  if parts.size != 2 or not parts[0].to_i.ok? or not parts[1].to_i.ok?
    return false
  end

  return not File.stat("/proc/#{parts[0]}").ok?
end

# Runs the jobs, with the folder of the dumps when the rules run. The rules check the units of all the files at once.
def collect_in_scratch(
  options: Options,
  config: Config.Config,
  jobs: List[Tools.Job],
  folder: String,
) -> Result[Collected]
  if not options.tools.include?(Tool.Rules)
    return ok(collect(options, config, jobs))
  end

  try Dir.mkdir_private(folder)
  remove_stale(folder)
  collected = collect(options, config, jobs)
  _ = Path.remove(folder)
  return ok(collected)
end

def collect(options: Options, config: Config.Config, jobs: List[Tools.Job]) -> Collected
  results = Task.map(jobs, options.jobs, Tools.limit_ms(options), &Tools.run)
  findings: List[Finding] = []
  errors: List[ToolError] = []
  ran: List[String] = []
  units: List[Unit] = []
  skipped_declarations = 0
  for i in 0...jobs.size
    job = jobs[i]
    case results[i]
      ok(outcome) ->
        findings = findings.concat(outcome.findings)
        errors = errors.concat(outcome.errors)
        units = units.concat(outcome.units)
        skipped_declarations = skipped_declarations + outcome.skipped_declarations
        if outcome.errors.empty?
          ran = ran.push(Baseline.pair(ToolKind.name(job.tool), job.shown))
        end

      error(message) ->
        errors = errors.push(ToolError(tool: ToolKind.name(job.tool), file: job.entry.file, message: message))
    end
  end

  return Collected(
    findings: findings.concat(Effects.check(units, config)),
    errors: errors,
    ran: ran,
    units: units,
    skipped_declarations: skipped_declarations,
  )
end

# The suppressions of the run: the comments in the files it ran and in the files of its findings, and the CC_IGNORE of
# the functions it read. A file that cannot be read has none.
def ignores_of(
  findings: List[Finding],
  plan: Plan,
  units: List[Unit],
  cwd: String,
) -> Result[List[Suppressions.Ignore]]
  files = findings.map do |f| f.file end.concat(plan.jobs.map do |job| job.shown end).uniq
  ignores: List[Suppressions.Ignore] = []
  for file in files
    case Files.read_all(file)
      ok(text) -> ignores = ignores.concat(try Suppressions.in_text(file, text))
      error(_) -> next
    end
  end

  for function in Effects.functions(units)
    shown = Paths.inside(cwd, function.file)
    if function.defined and shown.some?
      for mark in function.marks
        case try Suppressions.of_mark(shown.unwrap!, function.line, function.column, mark)
          some(ignore) -> ignores = ignores.push(ignore)
          none -> next
        end
      end
    end
  end

  return ok(ignores)
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
