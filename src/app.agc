## One run of cchecker: the files, the tools on each, the baseline and the report.

import Baseline from "baseline"
import Commands from "commands"
import Config from "config"
import Effects from "effects"
import Findings from "findings"
import Known from "known"
import {Finding, IncompleteFunction, ToolError, UncheckedFile, UnresolvedCallback} from "findings"
import Locking from "locking"
import {Options} from "options"
import Ownership from "ownership"
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

# The kept AST that the jobs of the rules parse and read at once, in MiB of its text (Tools.Budget). On the 84 files of
# the VM of Agentica at -j 8 it took the peak memory from 721 MB to 336 MB for half a second more; 8 MiB saved nothing
# more.
READ_BUDGET_MIB = 16

# The start of the name of the folder of the AST dumps of a run, in $TMPDIR.
SCRATCH_PREFIX = "cchecker-"

# The mode of that folder, 0700: only its user can read it.
PRIVATE_MODE = 448

# What the tools made of all the jobs, before the paths are shortened and the repeats taken out. `units` are the
# translation units of the rules, which also hold the CC_IGNORE of the functions. `unchecked` are the files whose
# header was not found, once each.
struct Collected
  findings: List[Finding]
  errors: List[ToolError]
  ran: List[String]
  units: List[Unit]
  skipped_declarations: Int = 0
  incomplete_functions: List[IncompleteFunction] = []
  unresolved: List[UnresolvedCallback] = []
  missing_roots: List[String] = []
  missing_assumed: List[String] = []
  unknown_targets: List[String] = []
  unchecked: List[UncheckedFile] = []
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
  if options.update_baseline and options.tools.include?(Tool.Rules)
    try full_rules(options, config, cwd)
  end

  if not options.json
    IO.warn("cchecker: settings: #{config.origin}")
  end

  loaded = try baseline_file(options)
  gathered = Commands.fold(try gather(options))
  scratch = try scratch_path(cwd)
  plan = try plan_for(options, gathered.entries, cwd, scratch)
  if plan.jobs.empty?
    return error("no C files to check")
  end

  if not plan.skipped.empty?
    IO.warn(skipped_line(plan.skipped))
    if options.update_baseline
      return error("the baseline is not updated: files of the database were not run, and it would lose their findings")
    end
  end

  collected = try collect_in_scratch(options, config, plan.jobs, scratch, cwd)
  if not config.off.include?(Known.NONBLOCKING_FLAG)
    for target in collected.unknown_targets
      if target == ""
        IO.warn(
          "cchecker: clang printed no target, so the flags of open, recv and send are not read: they count as blocking",
        )
      else
        IO.warn(
          "cchecker: the flags of #{target} are not known: open, recv and send count as blocking whatever their flags",
        )
      end
    end
  end

  if collected.skipped_declarations > 0
    IO.warn(
      "cchecker: skipped #{collected.skipped_declarations} declarations too large to read, which name no function",
    )
  end

  incomplete = collected.incomplete_functions
  if not incomplete.empty?
    IO.warn(
      "cchecker: the findings of these functions are those of the paths followed, as they have more paths than the " +
      "path rules follow: #{incomplete.map do |f| "#{f.file}:#{f.line} #{f.function}" end.join(", ")}",
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
  if options.tools.include?(Tool.Rules) and not (config.short.empty? and config.hot.empty?)
    if not scope.full
      IO.warn("cchecker: the names of [roots] were not checked: only a full run of a compile database sees them all")
    elsif not collected.missing_roots.empty?
      missing = collected.missing_roots.join(", ")
      return error("#{config.origin}: no function of the compile database is named #{missing} ([roots])")
    end
  end

  assumes = not (
    config.trusted.empty? and
    config.stops.empty? and
    config.short_locks.empty? and
    config.stop_fields.empty? and
    config.jumps.empty?
  )

  if options.tools.include?(Tool.Rules) and assumes
    if not scope.full
      IO.warn("cchecker: the names of [assume] were not checked: only a full run of a compile database sees them all")
    elsif not collected.missing_assumed.empty?
      missing = collected.missing_assumed.join(", ")
      return error("#{config.origin}: no function, lock or field of the compile database is named #{missing}")
    end
  end

  ignores = try ignores_of(found, plan, collected.units, cwd)
  applied = Suppressions.apply(found, ignores, scope.pairs)
  findings = Findings.sort(applied.findings)

  case options.baseline
    some(path) ->
      if options.update_baseline
        return update(path, loaded, scope, findings, collected.errors, options)
      end

      split = Baseline.split(findings, loaded.entries, scope)
      changes = Baseline.changes(loaded.tools, Tools.versions_of(options, loaded.tools.keys))
      rules_off = (
        options.strict_baseline and
        options.tools.include?(Tool.Rules) and
        not full_rules(options, config, cwd).ok?
      )

      failing = failing_of(options, rules_off, split.stale)
      return ok(
        finish(
          options,
          Report.Report(
            findings: split.new_findings,
            baselined: split.accepted,
            fixed: split.fixed,
            stale: split.stale,
            failing: failing,
            rules_off: rules_off,
            version_changes: changes,
            errors: collected.errors,
            skipped: plan.skipped.size,
            skipped_declarations: collected.skipped_declarations,
            incomplete_functions: collected.incomplete_functions,
            suppressed: applied.suppressed,
            config: config.origin,
            unresolved_callbacks: collected.unresolved,
            unchecked_files: collected.unchecked,
            folded: gathered.folded,
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
            incomplete_functions: collected.incomplete_functions,
            suppressed: applied.suppressed,
            config: config.origin,
            unresolved_callbacks: collected.unresolved,
            unchecked_files: collected.unchecked,
            folded: gathered.folded,
          ),
        ),
      )
  end
end

# A baseline written with a check off, or with fewer roots than the project names, would drop the accepted findings of
# that check or root, as --checks would: --update-baseline is refused then, naming what causes it. Of the settings only
# [roots] is compared: follow_cold and [assume] can also change the findings and are not checked.
def full_rules(options: Options, config: Config.Config, cwd: String) -> Result[Void]
  causes: List[String] = []
  if not options.infer
    causes = causes.push("drop --no-infer")
  end

  if not config.off.empty?
    causes = causes.push("set the [library] flags of #{config.origin} to true (#{config.off.to_a.sort.join(", ")})")
  end

  if options.config.some?
    project = try Config.load(none, cwd)
    missing = left_out("short", project.short, config.short).concat(left_out("hot", project.hot, config.hot))
    if not missing.empty?
      causes = causes.push("name the [roots] of #{project.origin} in #{config.origin} (#{missing.join("; ")})")
    end
  end

  if causes.empty?
    return ok()
  end

  return error(
    "--update-baseline needs every check of the rules on: #{causes.join(", and ")}, or the baseline would " +
    "lose their findings (of the settings, only [roots] is compared)",
  )
end

# The names of a list of [roots] of the project that the file of -c leaves out, as "short: a, b", or nothing.
def left_out(key: String, project: List[String], given: List[String]) -> List[String]
  names = project.uniq.select do |name| not given.include?(name) end
  if names.empty?
    return []
  end

  return ["#{key}: #{names.join(", ")}"]
end

# The baseline file, read before any tool runs so that a baseline that cannot be read costs no time. A baseline that is
# not there yet is empty when it is about to be written.
def baseline_file(options: Options) -> Result[Baseline.Loaded]
  case options.baseline
    some(path) ->
      if options.update_baseline and not File.stat(path).ok?
        return ok(Baseline.Loaded(entries: []))
      end

      return Baseline.load(path)
    none -> return ok(Baseline.Loaded(entries: []))
  end
end

# Writes the baseline when every tool ran: a baseline made from a half run would accept less than the project has. The
# entries of the tools and files that the run did not cover stay as they were. The versions of the tools are written
# only by a run of every file (no FILE, no --exclude): see `Baseline.updated_tools`.
def update(
  path: String,
  loaded: Baseline.Loaded,
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
  entries = Baseline.merged(loaded.entries, scope, kept)
  ran = options.tools.map(&Tools.version_key)
  versions = Tools.versions_of(options, ran)
  for tool in ran
    if not versions.key?(tool)
      IO.warn(
        "cchecker: warning: no version from #{tool}: its --version printed nothing or failed, so none is recorded",
      )
    end
  end

  whole = options.files.empty? and options.exclude.empty?
  try Baseline.write(path, entries, Baseline.updated_tools(loaded.tools, versions, ran, whole))
  puts("cchecker: wrote #{entries.reduce(0) do |total, entry| total + entry.count end} findings to #{path}")
  return ok(0)
end

def finish(options: Options, report: Report.Report) -> Int
  versions = Report.version_line(report)
  if not options.json and versions.some?
    IO.warn(versions.unwrap!)
  end

  if options.json
    puts(Report.json(report))
  else
    puts(Report.text(report))
  end

  for line in Report.error_lines(report)
    IO.warn(line)
  end

  for line in Report.unchecked_lines(report)
    IO.warn(line)
  end

  unresolved = Report.unresolved_line(report)
  if not options.json and unresolved.some?
    IO.warn(unresolved.unwrap!)
  end

  if not report.errors.empty?
    return 2
  end

  if not report.findings.empty? or Report.failed_stale?(report)
    return 1
  end

  return 0
end

# The stale entries that fail the run with `--strict-baseline`: those of the scope of the run (`Baseline.split` keeps
# only those). With a check of the rules off (`rules_off`: `--no-infer`, a `[library]` flag set to false, a file of -c
# without the [roots] of the project), the entries of the rules may look stale while they are not, so they do not fail
# the run, with a warning when there is one; the entries of the other tools still do.
def failing_of(options: Options, rules_off: Bool, stale: List[Baseline.Entry]) -> List[Baseline.Entry]
  if not options.strict_baseline
    return []
  end

  if not rules_off
    return stale
  end

  rules = ToolKind.name(Tool.Rules)
  kept = stale.select do |entry| Baseline.tool_of(entry.code) != rules end
  if kept.size < stale.size
    IO.warn(
      "cchecker: warning: --strict-baseline does not fail on the stale entries of the rules: a check of them is off",
    )
  end

  return kept
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
  # The target of the rules, once for each set of flags that choose one: most databases have one.
  targets: Map[String, String] = {}
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
            target = ""
            if tool == Tool.Rules
              chosen = Tools.target_flags(entry.args).join(" ")
              if not targets.key?(chosen)
                targets = targets.put(chosen, Tools.target_of(options.clang, entry))
              end

              target = targets.get(chosen).unwrap_or("")
            end

            jobs = jobs.push(
              Tools.Job(
                tool: tool,
                entry: entry,
                options: options,
                shown: shown,
                wrapped: wrapped,
                dump: dump,
                cwd: cwd,
                target: target,
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
    collected.errors.empty? and
    collected.unchecked.empty?
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
# dumps (`N.json`) and their FIFOs (`N.fifo`). Anything else of that name is left alone. A process is known to be
# gone only where /proc lists the running ones.
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

# Whether a path is a folder of dumps of the user: a private directory, not a link, that holds only `N.json` and
# `N.fifo` files.
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

# A dump `N.json`, or the FIFO `N.fifo` that clang writes it into.
def dump_name?(name: String) -> Bool
  return (name.end_with?(".json") or name.end_with?(".fifo")) and name.slice(0, name.length - 5).to_i.ok?
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

# Runs the jobs, those of the largest source files first, so that a large file does not run alone at the end. The
# results are in the order of the jobs.
def run_largest_first(options: Options, jobs: List[Tools.Job]) -> List[Result[Tools.Outcome]]
  sizes = jobs.map(&source_size)

  order = (0...jobs.size).to_a.sort_by do |i| -sizes[i] end
  ran = Task.map(order.map do |i| jobs[i] end, options.jobs, Tools.limit_ms(options), &Tools.run)
  # The place of each job in `order`, to put its result back.
  places = (0...order.size).to_a.sort_by do |k| order[k] end
  return places.map do |k| ran[k] end
end

# The size of the source file of a job, or 0 when it cannot be read (the tool then says why).
def source_size(job: Tools.Job) -> Int
  path = Paths.absolute(job.entry.directory, job.entry.file).unwrap_or(job.entry.file)
  case File.stat(path)
    ok(info) -> return info.size_bytes
    error(_) -> return 0
  end
end

# Runs the jobs, with the folder of the dumps when the rules run. The rules check the units of all the files at once.
def collect_in_scratch(
  options: Options,
  config: Config.Config,
  jobs: List[Tools.Job],
  folder: String,
  cwd: String,
) -> Result[Collected]
  if not options.tools.include?(Tool.Rules)
    return ok(collect(options, config, jobs, cwd))
  end

  try Dir.mkdir_private(folder)
  remove_stale(folder)
  collected = collect(options, config, jobs, cwd)
  _ = Path.remove(folder)
  return ok(collected)
end

def collect(options: Options, config: Config.Config, jobs: List[Tools.Job], cwd: String) -> Collected
  budget = Tools.budget(READ_BUDGET_MIB)
  budgeted = jobs.map do |job| job.with(budget: some(budget)) end
  results = Profile.measure("jobs") do run_largest_first(options, budgeted) end
  findings: List[Finding] = []
  errors: List[ToolError] = []
  ran: List[String] = []
  units: List[Unit] = []
  unchecked: List[UncheckedFile] = []
  skipped_declarations = 0
  for i in 0...jobs.size
    job = jobs[i]
    case results[i]
      ok(outcome) ->
        findings = findings.concat(outcome.findings)
        errors = errors.concat(outcome.errors)
        units = units.concat(outcome.units)
        skipped_declarations = skipped_declarations + outcome.skipped_declarations
        unchecked = unchecked.concat(outcome.unchecked)
        if outcome.errors.empty? and outcome.unchecked.empty?
          ran = ran.push(Baseline.pair(ToolKind.name(job.tool), job.shown))
        end

      error(message) ->
        errors = errors.push(ToolError(tool: ToolKind.name(job.tool), file: job.entry.file, message: message))
    end
  end

  # `[assume]` holds for every rule, as the marks it stands for.
  cut_missing = Effects.missing_fields(units, config)
  units = Effects.assumed(units, config)
  checked = Profile.measure("effects") do Effects.check(units, config, options.infer, options.all_paths, cwd) end
  locked = Profile.measure("locking") do Locking.check(units) end
  owned = Profile.measure("ownership") do Ownership.check(units) end
  return Collected(
    findings: (
      findings.concat(checked.findings)
        .concat(locked.findings)
        .concat(owned.findings)
        .concat(units.flat_map do |unit| unit.collected end.select do |f| not config.off.include?(f.source) end)
    ),
    errors: once(errors),
    ran: ran,
    units: units,
    skipped_declarations: skipped_declarations,
    incomplete_functions: incomplete_of(locked.incomplete.concat(owned.incomplete), cwd),
    unresolved: checked.unresolved,
    missing_roots: checked.missing_roots,
    missing_assumed: checked.missing_assumed.concat(cut_missing),
    unknown_targets: checked.unknown_targets,
    unchecked: unchecked.group_by do |u| "#{u.file}\n#{u.missing}" end
      .values
      .map do |same| same.first end
      .sort_by do |u| u.file end,
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

# The errors of the tools in their order, each once: a mark of a header that several units include gives the same
# error in each. Every repeated tool error is dropped this way, not only those of the marks.
def once(errors: List[ToolError]) -> List[ToolError]
  seen: Set[String] = Set.new([])
  kept: List[ToolError] = []
  for e in errors
    key = "#{e.tool}\n#{e.file}\n#{e.message}"
    if not seen.include?(key)
      seen = seen.add(key)
      kept = kept.push(e)
    end
  end

  return kept
end

# The functions with too many paths, once each (both rules may walk one, and a function of a header is in each unit
# that includes it), in the order of the files, with paths shown as findings are.
def incomplete_of(functions: List[IncompleteFunction], cwd: String) -> List[IncompleteFunction]
  shown = functions.map do |f| f.with(file: Paths.inside(cwd, f.file).unwrap_or(f.file)) end
  return shown.group_by do |f| "#{f.file}\n#{Findings.pad(f.line)}\n#{f.function}" end
    .values
    .map do |same| same.first end
    .sort_by do |f| "#{f.file}\n#{Findings.pad(f.line)}" end
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
