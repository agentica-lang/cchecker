## The effect rules on the call graph of the project: a CC_SHORT function never reaches a blocking call, and a CC_HOT
## function never allocates or makes a system call.

import Config from "config"
import {Finding, UnresolvedCallback} from "findings"
import {Body, Event} from "flow"
import Known from "known"
import Paths from "paths"
import {Call, Callback, Function, Section, Source, Store, Target, Unit} from "unit"

## The tool name of the findings of the rules.
TOOL = "rules"

## The mark of a function that counts as fine for CC_SHORT (CC_ASSUME_SHORT, `[assume] short`).
ASSUME_SHORT = "assume_short"

## The mark of a function that no walk goes into (CC_STOP, `[assume] stop`).
STOP = "stop"

## The mark of a function whose call may jump out of its caller (CC_MAY_JUMP, `[assume] may_jump`).
MAY_JUMP = "may_jump"
## The mark of a function that catches the jumps of the functions it calls (CC_CATCHES, `[assume] catches`).
CATCHES = "catches"
## The mark of a helper whose lock the catcher of a jump gives back (CC_JUMP_RELEASES, `[assume] jump_releases`).
JUMP_RELEASES = "jump_releases"
## The mark of a function whose call always jumps out of its caller and never returns (CC_JUMPS, `[assume] jumps`).
JUMPS = "jumps"
## The mark of a function whose descriptors are non-blocking (`[assume] nonblocking`).
NONBLOCKING = "nonblocking"

## The call graph of the project. A function is merged from all its declarations: the marks of each, and the place of
## its definition. A slot holds every function stored in it. `pointers` are the slots of each call through a pointer,
## by its caller and place (`caller LINE:COL`). `locks` are the classes of the locks that a function takes with each
## call of a lock function, by caller and callee (`caller>callee`), "" for a lock the rules cannot tell, and `quiet`
## whether each call of a function of `Known.FLAG_ARGUMENTS` has the flag that makes it return at once, by the same
## key. `unknown_targets` are the targets whose flags the rules do not know, of the units that call one with a
## constant flag.
struct Graph
  functions: Map[String, Function]
  edges: Map[String, List[Target]]
  slots: Map[String, List[String]]
  pointers: Map[String, List[String]] = {}
  locks: Map[String, List[String]] = {}
  quiet: Map[String, List[Bool]] = {}
  unknown_targets: List[String] = []
  declared: Map[String, List[String]] = {}
end

## What the rules found: the findings, and the callbacks of libuv calls they could not follow to a function.
## `missing_roots` are the names of `[roots]` that no function of the units defines, and `missing_assumed` those of
## `[assume]` that no function of the units declares, each with its key (`trace (assume.stop)`).
struct Checked
  findings: List[Finding]
  unresolved: List[UnresolvedCallback]
  missing_roots: List[String] = []
  missing_assumed: List[String] = []
  unknown_targets: List[String] = []
  short_locks: List[String] = []
end

## The critical sections of the locks (`Locking.check`): the calls made while a lock is held, the classes whose
## sections are not all known, and whether the run read every file of the compile database (`full`): the inference
## runs only then, as a file left out may hold a lock across a blocking call.
struct Sections
  calls: List[Section] = []
  partial: List[String] = []
  full: Bool = false
end

## Returns the findings of the rules on the units of a run. A root is a function marked in the C, named in the
## `[roots]` of the settings, or, when `infer`, passed as a callback to a libuv call that runs it on the loop. The
## `[library]` flags that are off take their families out of the blocking calls. A root gives one finding for each
## rule it breaks, at the nearest bad call, or one for each bad call it reaches when `all_paths`. `cwd` shortens the
## paths of the inferred roots and of the unresolved callbacks; one outside it stays absolute. A lock whose sections
## reach no blocking call is short too (`inferred_locks`), unless `[library] short_lock_sections` is off.
def check(
  units: List[Unit],
  config: Config.Config,
  infer: Bool,
  all_paths: Bool,
  cwd: String,
  sections: Sections,
) -> Checked
  graph = graph_of(units)
  families = Known.BLOCKING_FAMILIES.select do |family| not config.off.include?(family.flag) end
  walk = Walk(
    families: families,
    follow_cold: config.follow_cold,
    all: all_paths,
    short_locks: short_locks_of(units, config),
    inferred: Set.new([]),
    flags: not config.off.include?(Known.NONBLOCKING_FLAG),
    short_wrappers: wrappers_of(config.short_locks),
  )

  inferred_short: Set[String] = Set.new([])
  if sections.full and not config.off.include?(Known.SECTIONS_FLAG)
    inferred_short = inferred_locks(graph, walk, sections)
    walk = walk.with(inferred: inferred_short)
  end

  short_roots = listing_of(config.short)
  hot_roots = listing_of(config.hot)
  inferred = Inferred(roots: {}, unresolved: [])
  if infer and not config.off.include?(Known.CALLBACKS_FLAG)
    inferred = inferred_of(graph, units, cwd)
  end

  findings: List[Finding] = []
  for function in graph.functions.values
    if function.defined
      if function.marks.include?("short") or listed?(short_roots, function)
        findings = findings.concat(broken(graph, walk, function, Effect.Blocks))
      elsif inferred.roots.key?(function.key)
        # A marked or listed root needs no inference: the finding stays when the flag is off, so it names no flag.
        root = inferred.roots.get(function.key).unwrap!
        findings = findings.concat(
          broken(graph, walk, function, Effect.Blocks).map do |f|
            f.with(source: inferred_source(f.source), root: root)
          end,
        )
      end

      if function.marks.include?("hot") or listed?(hot_roots, function)
        findings = findings.concat(broken(graph, walk, function, Effect.Allocates))
        findings = findings.concat(broken(graph, walk, function, Effect.System))
      end
    end
  end

  Checked(
    findings: findings,
    unresolved: inferred.unresolved,
    missing_roots: missing_roots(graph, config),
    missing_assumed: missing_assumed(units, config).concat(missing_locks(units, graph, config)),
    unknown_targets: graph.unknown_targets,
    short_locks: inferred_short.to_a.sort,
  )
end

## Returns the units with the marks that `[assume]` gives the functions it names, as if the C had them, and without
## the calls through the fields of `[assume] stop_fields`, which no walk follows, and the direct calls of the pairs of
## `[assume] stop_calls`. A call through a copy of such a field (a local that got it) is still followed.
def assumed(units: List[Unit], config: Config.Config) -> List[Unit]
  return units if not Config.assumes_any?(config)

  cut = Set.new(config.stop_fields.map do |field| "#{FIELD_SLOT}#{field}" end)
  edges = edges_of(config)
  functions = functions_by_key(units)
  lists = Assumed(
    short: listing_of(config.trusted),
    stop: listing_of(config.stops),
    may_jump: listing_of(config.may_jump),
    jumps: listing_of(config.jumps),
    catches: listing_of(config.catches),
    jump_releases: listing_of(config.jump_releases),
    nonblocking: listing_of(config.nonblocking),
  )

  units.map do |unit|
    unit.with(
      functions: unit.functions.map do |f| with_assumed(f, lists) end,
      calls: unit.calls.select do |call| not cut_call?(cut, call) and not cut_edge?(edges, functions, call) end,
    )
  end
end

## Returns the units with `may_jump` inferred through the call graph: a function that calls a function that may jump
## out or jumps (marked, listed or inferred), directly, may jump out too, unless it catches the jump (it calls `setjmp`
## or `sigsetjmp`, or is CC_CATCHES or `[assume] catches`) or no rule walks into it (CC_STOP). A call of `setjmp`
## anywhere in a function catches every jump of its calls: an approximation. Its `via` is the chain of calls down to
## the marked function, a shortest one, where a name that two functions share has its file, relative to `cwd`. A
## function that never returns and may jump out is a way out where the path ends, as CC_JUMPS is.
def with_jumps(units: List[Unit], cwd: String) -> List[Unit]
  graph = graph_of(units)
  callers: Map[String, List[String]] = {}
  catchers: Set[String] = Set.new([])
  for caller in graph.edges.keys
    for target in graph.edges[caller]
      case target
        Target.Direct(to) ->
          if Known.SETJMP.include?(name_of_key(graph.functions, to))
            catchers = catchers.add(caller)
          end

          callers = callers.put(to, callers.get(to).unwrap_or([]).push(caller))
        _ -> next
      end
    end
  end

  jumping = graph.functions.values.select(&jumping?).map do |f| f.key end
  queue = jumping.sort
  via: Map[String, List[String]] = {}
  for key in queue
    via = via.put(key, [])
  end

  # A name that two functions share (static functions of two files) is shown with its file, relative to `cwd`.
  counts: Map[String, Int] = {}
  for function in graph.functions.values
    counts = counts.put(function.name, counts.get(function.name).unwrap_or(0) + 1)
  end

  seeds = queue.size
  at = 0
  while at < queue.size
    key = queue[at]
    at += 1
    for caller in callers.get(key).unwrap_or([])
      if not via.key?(caller) and not catchers.include?(caller) and not catches?(graph.functions.get(caller))
        name = name_of_key(graph.functions, key)
        shown = name
        if counts.get(name).unwrap_or(0) > 1
          found = graph.functions.get(key).map do |f| f.file end
          file = found.unwrap_or("")
          shown = "#{name}@#{Paths.inside(cwd, file).unwrap_or(file)}"
        end

        via = via.put(caller, [shown].concat(via[key]))
        queue = queue.push(caller)
      end
    end
  end

  return units if queue.size == seeds

  units.map do |unit| unit.with(functions: unit.functions.map do |f| with_via(f, via) end) end
end

## Returns the fields of `[assume] stop_fields` that the units neither store a function in nor call through, each with
## its key (`request.cal (assume.stop_fields)`). It reads the units before `assumed` takes the calls out.
def missing_fields(units: List[Unit], config: Config.Config) -> List[String]
  return [] if config.stop_fields.empty?

  known: Set[String] = Set.new([])
  for unit in units
    for store in unit.stores
      known = known.add(store.slot)
    end

    for call in unit.calls
      case call.target
        Target.Slot(slot) -> known = known.add(slot)
        Target.Direct(_) -> next
      end
    end
  end

  missing = config.stop_fields.uniq.select do |field| not known.include?("#{FIELD_SLOT}#{field}") end
  missing.map do |field| "#{field} (assume.stop_fields)" end
end

## Returns the pairs of `[assume] stop_calls` that match no call of the units, each with its key
## (`on_exit>close (assume.stop_calls)`). It reads the units before `assumed` takes the calls out.
def missing_calls(units: List[Unit], config: Config.Config) -> List[String]
  return [] if config.stop_calls.empty?

  functions = functions_by_key(units)
  calls = units.flat_map do |unit| unit.calls end
  missing = config.stop_calls.uniq.select do |text|
    edge = edges_of_texts([text])
    not calls.any? do |call| cut_edge?(edge, functions, call) end
  end

  missing.map do |text| "#{text} (assume.stop_calls)" end
end

## Returns whether no walk goes into a function: it is marked CC_STOP or named in `[assume] stop`.
def stopped?(graph: Graph, key: String) -> Bool = marked?(graph, key, STOP)

## Returns the functions of the units, each merged from all its declarations.
def functions(units: List[Unit]) -> List[Function] = graph_of(units).functions.values

## Returns the names of the shortest call path from a function of the project to a system call, a blocking one
## included: [`key`'s name, ..., the call]; none when it makes none. A library function is a path of its own name when
## it is a system call.
def system_path(graph: Graph, key: String) -> Optional[List[String]]
  # A function of the project marked CC_BLOCKING is one itself, whatever its body does. Every blocking call enters the
  # kernel whatever the `[library]` flags say, so the families passed do not change what a system call is.
  families = Known.BLOCKING_FAMILIES
  return none if stopped?(graph, key)

  return some([name_of(graph, key)]) if has?(graph, families, key, Effect.System)

  # The lock rules follow every call, cold ones included: `[effects] follow_cold` is about the roots of the
  # effect rules.
  walk = Walk(families: families, follow_cold: true, all: false, short_locks: Set.new([]), inferred: Set.new([]))
  paths = search(graph, walk, key, Effect.System)
  return none if paths.empty?

  some(paths.first.map do |k| name_of(graph, k) end)
end

## Returns the functions that a call through a pointer at `line`:`column` of `caller` reaches: those stored in its slot.
def pointer_targets(graph: Graph, caller: String, line: Int, column: Int) -> List[String]
  slots = graph.pointers.get("#{caller} #{line}:#{column}").unwrap_or([])
  targets = slots.flat_map do |slot| graph.slots.get(slot).unwrap_or([]) end
  targets.uniq
end

## Returns the functions that a function calls, directly or through a slot.
def callees(graph: Graph, key: String) -> List[String]
  found: List[String] = []
  for target in graph.edges.get(key).unwrap_or([])
    case target
      Target.Direct(to) -> found = found.push(to)
      Target.Slot(slot) -> found = found.concat(graph.slots.get(slot).unwrap_or([]))
    end
  end

  found
end

## Returns whether the project defines the function.
def defined?(graph: Graph, key: String) -> Bool
  found = graph.functions.get(key).map do |f| f.defined end
  found.unwrap_or(false)
end

## Returns the call graph of the units.
def graph_of(units: List[Unit]) -> Graph
  functions: Map[String, Function] = {}
  edges: Map[String, List[Target]] = {}
  pointers: Map[String, List[String]] = {}
  locks: Map[String, List[String]] = {}
  quiet: Map[String, List[Bool]] = {}
  unknown: List[String] = []
  declared: Map[String, List[String]] = {}
  stores: List[Store] = []
  for unit in units
    for function in unit.functions
      functions = functions.put(function.key, merged(functions.get(function.key), function))
      files = declared.get(function.key).unwrap_or([])
      if not files.include?(function.file)
        declared = declared.put(function.key, files.push(function.file))
      end
    end

    for call in unit.calls
      known = edges.get(call.caller).unwrap_or([])
      if not known.include?(call.target)
        edges = edges.put(call.caller, known.push(call.target))
      end

      case call.target
        Target.Direct(to) if Known.TAKES.include?(name_of_key(functions, to)) ->
          at = "#{call.caller}>#{to}"
          locks = locks.put(at, locks.get(at).unwrap_or([]).push(call.lock))
        Target.Direct(to) if Known.FLAG_ARGUMENTS.key?(name_of_key(functions, to)) ->
          at = "#{call.caller}>#{to}"
          callee = name_of_key(functions, to)
          bit = Known.nonblocking_bit(unit.target, callee)
          # Only a flag value can matter: 0 is no flag at all.
          if bit == 0 and call.flags > 0 and not call.named and not unknown.include?(unit.target)
            unknown = unknown.push(unit.target)
          end

          set = call.named or (bit != 0 and call.flags >= 0 and Known.flags_return_at_once?(callee, call.flags, bit))

          quiet = quiet.put(at, quiet.get(at).unwrap_or([]).push(set))
        Target.Slot(slot) if call.line > 0 ->
          at = "#{call.caller} #{call.line}:#{call.column}"
          pointers = pointers.put(at, pointers.get(at).unwrap_or([]).push(slot))
        _ -> next
      end
    end

    stores = stores.concat(unit.stores)
  end

  Graph(
    functions: functions,
    edges: edges,
    slots: slots_of(stores),
    pointers: pointers,
    locks: locks,
    quiet: quiet,
    unknown_targets: unknown,
    declared: declared,
  )
end

## Returns whether a lock class is among the classes of a list of `[assume]` (`short_locks`, `owned_locks`): as it is,
## or by the name of a static global (`big_lock` for `big_lock@src/a.c`, as `[assume]` names a static function), or by
## its name and the end of its file (`big_lock@a.c`).
def named_class?(names: Set[String], class: String) -> Bool
  names.include?(class) or names.include?(bare_class(class)) or names.to_a.any? do |entry| in_file?(entry, class) end
end

private

# The start of the slot of a field (`field:request.call`).
FIELD_SLOT = "field:"

# The mark of a short lock: a field or a global marked CC_NO_SYSCALL_UNDER().
SHORT_LOCK_MARK = "no_syscall_under()"

# The effects a rule looks for.
enum Effect
  Blocks
  Allocates
  System
end

# How a rule walks the graph: the families of blocking calls that are on, whether it goes into the functions that never
# return or are cold, whether it finds every bad call or stops at the first, and the classes of the short locks, whose
# taking is not blocking, and whether a call with a flag that makes it return at once is not blocking (`flags`).
# `short_wrappers` are the functions of `[assume] short_locks` whose locks are short, whatever the lock.
struct Walk
  families: List[Known.Family]
  follow_cold: Bool
  all: Bool
  short_locks: Set[String]
  flags: Bool = false
  # The classes inferred short, matched as they are: `short_locks` is matched as `[assume]` names them.
  inferred: Set[String]
  # Whether a call through a pointer that the run stores no function in is a bad call (for the inference of short
  # locks, where it may be any function); the rules reach nothing through it.
  empty_slots: Bool = false
  short_wrappers: List[Config.Wrapper] = []
end

# One entry of `[roots]` or `[assume]`: a bare name (every function of that name, a static one in any file), or
# `name@file`, whose `tail` is the end of the path of the file. A `./` before the path is ignored. An entry with an
# empty path (`name@`) is neither: it names nothing, so it is reported as missing.
struct Entry
  name: String
  bare: Bool
  tail: String
end

# The entries of a list, split once: the bare names, and the ends of the paths of `name@file` by name.
struct Listing
  bare: Set[String]
  tails: Map[String, List[String]]
end

# A pair of `[assume] stop_calls` with each side as a listing: the functions that the call may come from and go to.
struct Cut
  caller: Listing
  callee: Listing
end

# The lists of `[assume] short`, `stop`, `may_jump`, `jumps`, `catches`, `jump_releases` and `nonblocking`.
struct Assumed
  short: Listing
  stop: Listing
  may_jump: Listing
  jumps: Listing
  catches: Listing
  jump_releases: Listing
  nonblocking: Listing
end

# The CC_SHORT roots inferred from the callbacks of libuv, by function key, each with the call that made it, and the
# callbacks that name no function.
struct Inferred
  roots: Map[String, String]
  unresolved: List[UnresolvedCallback]
end

# The classes of the short locks: those marked CC_NO_SYSCALL_UNDER() and those of `[assume] short_locks`. An entry
# `name(N)` is a wrapper (see `wrappers_of`), not a class.
def short_locks_of(units: List[Unit], config: Config.Config) -> Set[String]
  lock_marks = units.flat_map do |unit| unit.lock_marks end
  short = lock_marks.select do |m| m.mark == SHORT_LOCK_MARK end
  marked = short.map do |m| m.class end

  Set.new(marked.concat(config.short_locks.select do |entry| not entry.include?("(") end))
end

# The wrappers `name(N)` among the entries of `short_locks`.
def wrappers_of(entries: List[String]) -> List[Config.Wrapper]
  found: List[Config.Wrapper] = []
  for entry in entries
    case Config.wrapper_of(entry)
      some(wrapper) -> found = found.push(wrapper)
      none -> next
    end
  end

  found
end

# The classes of the locks that are short because no section of theirs reaches a blocking call, as the short rule
# sees one (a take of a lock that is not short is one). A class is inferred only when the rules know it and all its
# sections are known (`Locking.Checked.partial`). A section of a lock whose class the rules cannot trust ("": one
# taken through a parameter, `pthread_mutex_lock(m)`, or through a pointer field) may be of any class: when one
# blocks, or when such a lock has sections that are not all known, no class is inferred. A class whose sections take
# another one becomes short once that one is: the inference runs again with the classes it found until it finds no
# more, and never assumes a class to find it. Each round searches each function that the sections call once; there
# are as many rounds as the longest chain of classes taken one under another, plus one.
def inferred_locks(graph: Graph, walk: Walk, sections: Sections) -> Set[String]
  by_class: Map[String, List[Section]] = {}
  for section in sections.calls
    by_class = by_class.put(section.class, by_class.get(section.class).unwrap_or([]).push(section))
  end

  partial = Set.new(sections.partial)
  if partial.include?("") or quiet_classes(graph, walk.with(all: false, empty_slots: true), by_class, [""]).empty?
    return Set.new([])
  end

  candidates = by_class.keys.select do |class|
    class != "" and not partial.include?(class) and not named_class?(walk.short_locks, class)
  end

  found: Set[String] = Set.new([])
  added = quiet_classes(graph, walk.with(all: false, empty_slots: true), by_class, candidates)
  while not added.empty?
    found = found.union(Set.new(added))
    left = candidates.select do |class| not found.include?(class) end
    added = quiet_classes(graph, walk.with(inferred: found, all: false, empty_slots: true), by_class, left)
  end

  found
end

# The classes among `classes` none of whose sections reaches a blocking call with the short locks of `walk`. Each
# function the sections call is searched once.
def quiet_classes(
  graph: Graph,
  walk: Walk,
  by_class: Map[String, List[Section]],
  classes: List[String],
) -> List[String]
  sections = classes.flat_map do |class| by_class.get(class).unwrap_or([]) end
  targets = sections.flat_map do |section| targets_of(graph, section) end
  keys = targets.uniq
  blocking = Set.new(
    keys.select do |key|
      has?(graph, walk.families, key, Effect.Blocks) or not search(graph, walk, key, Effect.Blocks).empty?
    end,
  )

  classes.select do |class|
    by_class.get(class).unwrap_or([]).all? do |section| not blocks?(graph, walk, section, blocking) end
  end
end

# The functions a call of a section goes to: its callee, or the functions stored in the pointer it calls.
def targets_of(graph: Graph, section: Section) -> List[String]
  return pointer_targets(graph, section.caller, section.line, section.column) if section.pointer

  [section.callee]
end

# Whether a call of a section is, or reaches, a blocking call (one of `blocking`), as a call of a short function would
# be: the functions stored in a pointer it calls count each. A take of a lock of the library is judged by the classes
# it takes itself, not by every take of the same function in the caller, so a section may take a short lock and
# another may not.
def blocks?(graph: Graph, walk: Walk, section: Section, blocking: Set[String]) -> Bool
  if not section.pointer and not section.takes.empty? and not defined?(graph, section.callee)
    return true if marked?(graph, section.callee, "blocking")

    return false if wrapper_take?(graph, walk, section.caller, section.callee)

    return not section.tried and not section.takes.all? do |c| short_class?(walk, c) end
  end

  targets = targets_of(graph, section)
  # A pointer that the run stores no function in may hold any function: the inference counts it as blocking, where
  # the short rule reaches nothing through it.
  return section.pointer if targets.empty?

  targets.any? do |key|
    skipped = (
      cut?(graph, walk, key, Effect.Blocks, not walk.follow_cold) or
      short_takes?(graph, walk, section.caller, key) or
      returns_at_once?(graph, walk, section.caller, key)
    )

    not skipped and blocking.include?(key)
  end
end

# Whether every call of the lock function `callee` in `key` takes a short lock, so the short rule does not count it:
# the lock is of a short class, or the call is of a wrapper of `short_locks` (`uv_mutex_lock(0)`), or it is made in
# one (a lock wrapper of the project: the lock it takes is its parameter's, whatever the caller passes).
def short_takes?(graph: Graph, walk: Walk, key: String, callee: String) -> Bool
  return true if wrapper_take?(graph, walk, key, callee)

  classes = graph.locks.get("#{key}>#{callee}").unwrap_or([])
  not classes.empty? and classes.all? do |c| short_class?(walk, c) end
end

# Whether a class is short: one the rules know, marked or named in `[assume] short_locks` (`named_class?`), or
# inferred, as it is.
def short_class?(walk: Walk, class: String) -> Bool
  class != "" and (named_class?(walk.short_locks, class) or walk.inferred.include?(class))
end

# Whether a call of the known take `callee` in `key` is of a wrapper of `short_locks`, or made in one.
def wrapper_take?(graph: Graph, walk: Walk, key: String, callee: String) -> Bool
  (
    not walk.short_wrappers.empty? and
    Known.TAKES.include?(name_of_key(graph.functions, callee)) and
    (listed_wrapper?(graph, walk, callee) or listed_wrapper?(graph, walk, key))
  )
end

# Whether the function of a key is a wrapper of `short_locks`: by its name, and the end of the file of any declaration
# of it when the entry gives one.
def listed_wrapper?(graph: Graph, walk: Walk, key: String) -> Bool
  name = name_of_key(graph.functions, key)
  files = graph.declared.get(key).unwrap_or([])
  walk.short_wrappers.any? do |wrapper|
    wrapper.name == name and (wrapper.tail == "" or files.any? do |file| ends_with_path?(file, wrapper.tail) end)
  end
end

# Whether `entry` (`name@file`) names the static global `class` by the end of its file's path.
def in_file?(entry: String, class: String) -> Bool
  name = bare_class(entry)
  return false if name == entry or name != bare_class(class)

  file = entry.slice(name.length + 1, entry.length - name.length - 1)
  path = class.slice(name.length + 1, class.length - name.length - 1)
  ends_with_path?(path, file)
end

# Whether `path` is `tail` or ends with it after a slash: whole parts of the path, so `b.c` is not `ab.c`.
def ends_with_path?(path: String, tail: String) -> Bool = path == tail or path.end_with?("/#{tail}")

def entry_of(entry: String) -> Entry
  case entry.index_of("@")
    some(at) ->
      tail = entry.slice(at + 1, entry.length - at - 1)
      if tail.start_with?("./")
        tail = tail.slice(2, tail.length - 2)
      end

      Entry(name: entry.slice(0, at), bare: false, tail: tail)
    none -> Entry(name: entry, bare: true, tail: "")
  end
end

def listing_of(entries: List[String]) -> Listing
  bare: List[String] = []
  tails: Map[String, List[String]] = {}
  for entry in entries.map(&entry_of)
    if entry.bare
      bare = bare.push(entry.name)
    elsif entry.tail != ""
      tails = tails.put(entry.name, tails.get(entry.name).unwrap_or([]).push(entry.tail))
    end
  end

  Listing(bare: Set.new(bare), tails: tails)
end

# Whether the list names the function: by its name, or by its name and the end of the path of its file.
def listed?(listing: Listing, function: Function) -> Bool
  (
    listing.bare.include?(function.name) or
    listing.tails.get(function.name).unwrap_or([]).any? do |tail| ends_with_path?(function.file, tail) end
  )
end

# A class without the file of a static global.
def bare_class(class: String) -> String
  case class.index_of("@")
    some(at) -> class.slice(0, at)
    none -> class
  end
end

# Whether every call of `callee` in `key` has the flag that makes it return at once, or is a call on a descriptor in a
# function of `[assume] nonblocking`, so the short rule does not count it.
def returns_at_once?(graph: Graph, walk: Walk, key: String, callee: String) -> Bool
  # A function of the project named `read` is not the call of libc: what it calls still counts.
  if (
    marked?(graph, key, NONBLOCKING) and
    not defined?(graph, callee) and
    Known.FD_CALLS.include?(name_of_key(graph.functions, callee))
  )
    return true
  end

  calls = graph.quiet.get("#{key}>#{callee}").unwrap_or([])
  walk.flags and not calls.empty? and calls.all? do |set| set end
end

# Whether a call goes through one of the slots `cut`.
def cut_call?(cut: Set[String], call: Call) -> Bool
  case call.target
    Target.Slot(slot) -> cut.include?(slot)
    Target.Direct(_) -> false
  end
end

def edges_of(config: Config.Config) -> List[Cut] = edges_of_texts(config.stop_calls)

def edges_of_texts(texts: List[String]) -> List[Cut]
  edges: List[Cut] = []
  for text in texts
    case Config.edge_of(text)
      some(edge) -> edges = edges.push(Cut(caller: listing_of([edge.caller]), callee: listing_of([edge.callee])))
      none -> next
    end
  end

  edges
end

# Every declaration and definition of the functions of the units, by key: a name in `[assume]` may be the file of any.
def functions_by_key(units: List[Unit]) -> Map[String, List[Function]]
  found: Map[String, List[Function]] = {}
  for unit in units
    for function in unit.functions
      known = found.get(function.key).unwrap_or([])
      # One entry for each file: a header read by many units declares the same function in each.
      if not known.any? do |f| f.file == function.file end
        found = found.put(function.key, known.push(function))
      end
    end
  end

  found
end

# Whether a call is the one of a pair of `[assume] stop_calls`: a direct call whose caller and callee are the functions
# that the two sides name.
def cut_edge?(edges: List[Cut], functions: Map[String, List[Function]], call: Call) -> Bool
  case call.target
    Target.Direct(callee) ->
      edges.any? do |edge| named?(edge.caller, functions, call.caller) and named?(edge.callee, functions, callee) end

    Target.Slot(_) -> false
  end
end

def named?(listing: Listing, functions: Map[String, List[Function]], key: String) -> Bool
  functions.get(key).unwrap_or([]).any? do |function| listed?(listing, function) end
end

# The classes of `[assume] short_locks` that no lock of the units has (none taken and none marked), and those of
# `owned_locks` that no lock through a pointer has, with their key.
def missing_locks(units: List[Unit], graph: Graph, config: Config.Config) -> List[String]
  return [] if config.short_locks.empty? and config.owned_locks.empty?

  taken = graph.locks.values.flat_map do |found| found end
  lock_marks = units.flat_map do |unit| unit.lock_marks end
  classes = taken.concat(lock_marks.map do |m| m.class end)

  known = Set.new(classes.concat(classes.map(&bare_class)))
  files = files_by_name(units.flat_map do |unit| unit.functions end)
  missing = config.short_locks.uniq.select do |c|
    (
      (c.include?("(") and not known_take?(c) and not wrapper_matches?(c, files)) or
      (not c.include?("(") and not known.include?(c) and not classes.any? do |class| in_file?(c, class) end)
    )
  end

  short = missing.map do |c| "#{c} (assume.short_locks)" end
  short.concat(missing_owned(units, config))
end

# The classes of `[assume] owned_locks` that no lock through a pointer has, with their key: the name of a mutex that
# is not behind a pointer would do nothing.
def missing_owned(units: List[Unit], config: Config.Config) -> List[String]
  return [] if config.owned_locks.empty?

  bodies = units.flat_map do |unit| unit.bodies end
  classes = bodies.flat_map(&pointer_classes)
  known = Set.new(classes.concat(classes.map(&bare_class)))
  missing = config.owned_locks.uniq.select do |c|
    not known.include?(c) and not classes.any? do |class| in_file?(c, class) end
  end

  missing.map do |c| "#{c} (assume.owned_locks)" end
end

# The classes of the locks through a pointer field or global that the calls of a body take, release or wait on, a lock
# helper among them (`CC_ACQUIRES(l->mutex)` of `void *mutex`).
def pointer_classes(body: Body) -> List[String]
  classes: List[String] = []
  for node in body.nodes
    case node.event
      Event.Call(site) ->
        locks = site.takes.concat(site.drops).concat(site.waits).select do |lock| lock.through end
        classes = classes.concat(locks.map do |lock| lock.class end)
      _ -> next
    end
  end

  classes
end

# Whether a wrapper of `acquires`, `releases` or `tries` names a function with a named parameter at its place, in a
# declaration whose file ends with the path when it has one: a function with external linkage is one in the whole
# project, so any of its declarations tells the file.
def lock_declared?(text: String, functions: List[Function]) -> Bool
  case Config.wrapper_of(text)
    some(wrapper) ->
      functions.any? do |f| f.name == wrapper.name and f.arity > wrapper.index and file_named?(f, wrapper.tail) end

    none -> false
  end
end

# Whether the path `tail` ("" is any) names the function: the file of a static one is that of its definition, as its
# key says, and a function with external linkage has the file of any of its declarations.
def file_named?(function: Function, tail: String) -> Bool
  return true if tail == ""

  case function.key.index_of("@")
    some(at) -> ends_with_path?(function.key.slice(at + 1, function.key.length - at - 1), tail)
    none -> ends_with_path?(function.file, tail)
  end
end

# Whether a wrapper of `short_locks` names a known take (`uv_mutex_lock`): a library the project may use without
# declaring it in its own files, so it is not missing when no unit has it.
def known_take?(text: String) -> Bool
  case Config.wrapper_of(text)
    some(wrapper) -> wrapper.tail == "" and Known.TAKES.include?(wrapper.name)
    none -> false
  end
end

# Whether a wrapper `name(N)` or `name@path(N)` names a function of the units, whose files are `files` by name.
def wrapper_matches?(text: String, files: Map[String, List[String]]) -> Bool
  case Config.wrapper_of(text)
    some(wrapper) ->
      files.get(wrapper.name)
        .unwrap_or([])
        .any? do |file| wrapper.tail == "" or ends_with_path?(file, wrapper.tail) end

    none -> false
  end
end

# Whether a function may jump out or jumps by a mark (or `[assume]`): where the inference starts.
def jumping?(function: Function) -> Bool = function.marks.include?(MAY_JUMP) or function.marks.include?(JUMPS)

# Whether the inference stops at a function: it catches the jump, or no rule walks into it.
def catches?(function: Optional[Function]) -> Bool
  found = function.map do |f| f.marks end
  marks = found.unwrap_or([])
  marks.include?(CATCHES) or marks.include?(STOP)
end

# A function that may jump out through the functions it calls, with the mark and the chain.
def with_via(function: Function, via: Map[String, List[String]]) -> Function
  chain = via.get(function.key).unwrap_or([])
  return function if chain.empty? or jumping?(function)

  function.with(marks: function.marks.push(MAY_JUMP), via: chain)
end

# The name of a function by key, or the key itself for one the units do not declare.
def name_of_key(functions: Map[String, Function], key: String) -> String
  found = functions.get(key).map do |f| f.name end
  found.unwrap_or(key)
end

# A function with the marks of `[assume]` that name it.
def with_assumed(function: Function, lists: Assumed) -> Function
  marks = function.marks
  if listed?(lists.short, function)
    marks = marks.push(ASSUME_SHORT)
  end

  if listed?(lists.stop, function)
    marks = marks.push(STOP)
  end

  if listed?(lists.may_jump, function)
    marks = marks.push(MAY_JUMP)
  end

  noreturn = function.noreturn
  if listed?(lists.jumps, function)
    marks = marks.push(JUMPS)
    noreturn = true
  end

  if listed?(lists.catches, function)
    marks = marks.push(CATCHES)
  end

  if listed?(lists.jump_releases, function)
    marks = marks.push(JUMP_RELEASES)
  end

  if listed?(lists.nonblocking, function)
    marks = marks.push(NONBLOCKING)
  end

  function.with(marks: marks.uniq, noreturn: noreturn)
end

# The entries of `[assume]` that no function of the units has, with their key. A `name@file` counts when the file of
# any declaration of the function, or of its definition, ends with the path: the same functions that `assumed` marks.
def missing_assumed(units: List[Unit], config: Config.Config) -> List[String]
  return [] if not Config.assumes_any?(config)

  files = files_by_name(units.flat_map do |unit| unit.functions end)
  short = unmatched(config.trusted, files).map do |name| "#{name} (assume.short)" end
  stop = unmatched(config.stops, files).map do |name| "#{name} (assume.stop)" end
  may_jump = unmatched(config.may_jump, files).map do |name| "#{name} (assume.may_jump)" end
  jumps = unmatched(config.jumps, files).map do |name| "#{name} (assume.jumps)" end
  catches = unmatched(config.catches, files).map do |name| "#{name} (assume.catches)" end
  releases = unmatched(config.jump_releases, files).map do |name| "#{name} (assume.jump_releases)" end
  declared = units.flat_map do |unit| unit.functions end
  unknown_acquires = config.acquires.uniq.select do |text| not lock_declared?(text, declared) end
  acquires = unknown_acquires.map do |text| "#{text} (assume.acquires)" end
  unknown_releases = config.releases.uniq.select do |text| not lock_declared?(text, declared) end
  given_back = unknown_releases.map do |text| "#{text} (assume.releases)" end
  unknown_tries = config.tries.uniq.select do |text| not lock_declared?(text, declared) end
  tried = unknown_tries.map do |text| "#{text} (assume.tries)" end

  nonblocking = unmatched(config.nonblocking, files).map do |name| "#{name} (assume.nonblocking)" end
  (
    short.concat(stop)
      .concat(may_jump)
      .concat(jumps)
      .concat(catches)
      .concat(releases)
      .concat(acquires)
      .concat(given_back)
      .concat(tried)
      .concat(nonblocking)
  )
end

# The files of the functions, by name.
def files_by_name(functions: List[Function]) -> Map[String, List[String]]
  files: Map[String, List[String]] = {}
  for function in functions
    known = files.get(function.name).unwrap_or([])
    if not known.include?(function.file)
      files = files.put(function.name, known.push(function.file))
    end
  end

  files
end

# The entries that name none of the functions, whose files are `files` by name.
def unmatched(entries: List[String], files: Map[String, List[String]]) -> List[String]
  entries.uniq.select do |text| not matches_any?(entry_of(text), files) end
end

def matches_any?(entry: Entry, files: Map[String, List[String]]) -> Bool
  return files.key?(entry.name) if entry.bare

  entry.tail != "" and files.get(entry.name).unwrap_or([]).any? do |file| ends_with_path?(file, entry.tail) end
end

def marked?(graph: Graph, key: String, mark: String) -> Bool
  found = graph.functions.get(key).map do |f| f.marks.include?(mark) end
  found.unwrap_or(false)
end

# The entries of `[roots]` that no function of the graph defines.
def missing_roots(graph: Graph, config: Config.Config) -> List[String]
  names = config.short.concat(config.hot).uniq
  return [] if names.empty?

  unmatched(names, files_by_name(graph.functions.values.select do |f| f.defined end))
end

# The source of a finding of an inferred root: the flag of the inference, and that of the family of the blocking call
# when one made it, as either flag turns the finding off.
def inferred_source(family: String) -> String
  return Known.CALLBACKS_FLAG if family == ""

  "#{Known.CALLBACKS_FLAG}+#{family}"
end

# The callbacks in the order of their places, so that the root of a function passed at several places is the first.
def inferred_of(graph: Graph, units: List[Unit], cwd: String) -> Inferred
  found = units.flat_map do |unit| unit.callbacks end
  callbacks = found.sort_by do |c| "#{c.file}\n#{padded(c.line)}:#{c.argument}" end

  roots: Map[String, String] = {}
  unresolved: List[UnresolvedCallback] = []
  for callback in callbacks
    # A call outside the working directory (a body that includes a file from outside) keeps its absolute path.
    shown = Paths.inside(cwd, callback.file).unwrap_or(callback.file)
    # A library function (`free`) leads somewhere too, but has no body to check: it is no root.
    keys = callback.sources.flat_map do |source| keys_of(graph, source) end
    # A header reached by several files holds the same call once for each.
    if keys.empty? and not unresolved.any? do |u| same?(u, callback, shown) end
      unresolved = unresolved.push(
        UnresolvedCallback(call: callback.call, argument: callback.argument, file: shown, line: callback.line),
      )
    end

    for key in keys
      if defined?(graph, key) and not roots.key?(key)
        roots = roots.put(key, "callback of #{callback.call} at #{shown}:#{callback.line}")
      end
    end
  end

  Inferred(roots: roots, unresolved: unresolved)
end

# Zero-padded, so that the text order is the order of the numbers.
def padded(n: Int) -> String
  digits = n.to_s
  "0" * (9 - digits.length) + digits
end

def same?(known: UnresolvedCallback, callback: Callback, shown: String) -> Bool
  (
    known.file == shown and
    known.line == callback.line and
    known.call == callback.call and
    known.argument == callback.argument
  )
end

def keys_of(graph: Graph, source: Source) -> List[String]
  case source
    Source.Function(key) -> [key]
    Source.Copy(from) -> graph.slots.get(from).unwrap_or([])
  end
end

# The functions each slot holds: those stored in it, and those of the slots copied into it, until nothing changes.
def slots_of(stores: List[Store]) -> Map[String, List[String]]
  slots: Map[String, List[String]] = {}
  changed = true
  while changed
    changed = false
    for store in stores
      held = slots.get(store.slot).unwrap_or([])
      incoming = case store.source
        Source.Function(key) -> [key]
        Source.Copy(from) -> slots.get(from).unwrap_or([])
      end

      added = incoming.select do |key| not held.include?(key) end
      if not added.empty?
        slots = slots.put(store.slot, held.concat(added))
        changed = true
      end
    end
  end

  slots
end

# One function from two declarations: the marks and attributes of both, at the place of the definition.
def merged(known: Optional[Function], function: Function) -> Function
  case known
    some(before) ->
      marks = before.marks.concat(function.marks).uniq
      noreturn = before.noreturn or function.noreturn
      cold = before.cold or function.cold
      return before.with(marks: marks, noreturn: noreturn, cold: cold) if before.defined

      function.with(marks: marks, noreturn: noreturn, cold: cold)
    none -> function
  end
end

# The findings of a rule on a function, when the function reaches what the rule forbids: one for each bad call the
# walk finds, each with its shortest call path.
def broken(graph: Graph, walk: Walk, function: Function, effect: Effect) -> List[Finding]
  search(graph, walk, function.key, effect).map do |path|
    names = path.map do |key| name_of(graph, key) end
    # The message has no path, so the baseline holds when the path changes; the report prints the path. It names the
    # bad call, so each finding of --all-paths has a key of its own, and the first is the one a run without it gives.
    Finding(
      code: code_of(effect),
      tool: TOOL,
      file: function.file,
      line: function.line,
      column: function.column,
      message: "#{kind_of(function, effect)} reaches #{call_of(effect)} #{names.last}",
      path: names,
      source: source_of(graph, walk.families, path.last, effect),
    )
  end
end

# A walk of the graph in breadth from `start`, which gives the keys of the path to each function with the effect, in
# the order it reaches them, and stops at the first unless `walk.all`. A function is reached once, by its shortest
# path, and the walk does not go past one with the effect. It goes only through the functions that the project
# defines (one it does not define is a call of a library), not into one that the project assumes away (`cut?`), and
# not into one that never returns or is cold unless `walk.follow_cold`: that call is an error exit, not the path the
# rule is about.
def search(graph: Graph, walk: Walk, start: String, effect: Effect) -> List[List[String]]
  callers: Map[String, String] = {}
  callers = callers.put(start, start)
  queue = [start]
  found: List[List[String]] = []
  i = 0
  while i < queue.size
    key = queue[i]
    i += 1
    if walk.empty_slots and empty_slot?(graph, key)
      found = found.push(path_to(callers, start, key))
      return found if not walk.all
    end

    for callee in callees(graph, key)
      next if callers.key?(callee) or cut?(graph, walk, callee, effect, not walk.follow_cold)

      if (
        effect == Effect.Blocks and
        (short_takes?(graph, walk, key, callee) or returns_at_once?(graph, walk, key, callee))
      )
        next
      end

      callers = callers.put(callee, key)
      if has?(graph, walk.families, callee, effect)
        found = found.push(path_to(callers, start, callee))
        return found if not walk.all
      elsif defined?(graph, callee)
        queue = queue.push(callee)
      end
    end
  end

  found
end

# Whether a function calls through a pointer that the run stores no function in.
def empty_slot?(graph: Graph, key: String) -> Bool
  graph.edges.get(key).unwrap_or([]).any? do |target|
    case target
      Target.Slot(slot) -> graph.slots.get(slot).unwrap_or([]).empty?
      Target.Direct(_) -> false
    end
  end
end

# Whether the walk of a rule does not go into a function: it is stopped, trusted for the short rule, or (with `cold`)
# it never returns or is cold.
def cut?(graph: Graph, walk: Walk, key: String, effect: Effect, cold: Bool) -> Bool
  # A function that blocks itself (CC_BLOCKING) cannot be assumed short; CC_STOP wins over every mark.
  trusted = marked?(graph, key, ASSUME_SHORT) and not marked?(graph, key, "blocking")
  return true if stopped?(graph, key) or (effect == Effect.Blocks and trusted)

  cold and skips?(graph, key)
end

# A function that never returns or is cold, which the walk does not go into, unless a CC_BLOCKING mark says what it
# does: the mark wins. A library call that never returns (`_exit`, `abort`, `Known.NORETURN`) is skipped as a project
# `_Noreturn` function is, though `_exit` also enters the kernel: it is the error exit, not the path the rule is about.
# A function of that name that the project defines (`static void err(...)`) is judged by its body.
def skips?(graph: Graph, key: String) -> Bool
  case graph.functions.get(key)
    some(f) ->
      exits = not f.defined and Known.NORETURN.include?(f.name)
      (f.noreturn or f.cold or exits) and not f.marks.include?("blocking")
    none -> Known.NORETURN.include?(key)
  end
end

# The path from `start` to `last`. `callers` maps a function to the one that called it first.
def path_to(callers: Map[String, String], start: String, last: String) -> List[String]
  path = [last]
  key = last
  while key != start
    # The walk put the caller of every function it reached before it reached the next one.
    key = callers.get(key).unwrap!
    path = [key].concat(path)
  end

  path
end

def has?(graph: Graph, families: List[Known.Family], key: String, effect: Effect) -> Bool
  name = name_of(graph, key)
  found = graph.functions.get(key).map do |f| f.marks.include?("blocking") end
  marked = found.unwrap_or(false)
  library = not defined?(graph, key)
  case effect
    Effect.Blocks -> marked or (library and families.any? do |family| family.calls.include?(name) end)
    Effect.Allocates -> library and Known.ALLOCATING.include?(name)
    Effect.System -> marked or (library and (Known.SYSTEM.include?(name) or Known.BLOCKING.include?(name)))
  end
end

# The `[library]` flag whose family made the last call of a path blocking, or "" when a mark did, or for the rules of
# CC_HOT, which no flag turns off.
def source_of(graph: Graph, families: List[Known.Family], key: String, effect: Effect) -> String
  return "" if effect != Effect.Blocks or defined?(graph, key)

  name = name_of(graph, key)
  for family in families
    return family.flag if family.calls.include?(name)
  end

  ""
end

def name_of(graph: Graph, key: String) -> String
  found = graph.functions.get(key).map do |f| f.name end
  found.unwrap_or(key)
end

def code_of(effect: Effect) -> String
  case effect
    Effect.Blocks -> "CC-EFFECT-SHORT-BLOCKS"
    Effect.Allocates -> "CC-EFFECT-HOT-ALLOCATES"
    Effect.System -> "CC-EFFECT-HOT-SYSCALL"
  end
end

def kind_of(function: Function, effect: Effect) -> String
  case effect
    Effect.Blocks -> "short function #{function.name}"
    Effect.Allocates -> "hot function #{function.name}"
    Effect.System -> "hot function #{function.name}"
  end
end

def call_of(effect: Effect) -> String
  case effect
    Effect.Blocks -> "the blocking call"
    Effect.Allocates -> "the allocation"
    Effect.System -> "the system call"
  end
end
