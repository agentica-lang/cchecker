## The effect rules on the call graph of the project: a CC_SHORT function never reaches a blocking call, and a CC_HOT
## function never allocates or makes a system call.

import {Config} from "config"
import {Finding, UnresolvedCallback} from "findings"
import Known from "known"
import Paths from "paths"
import {Callback, Function, Source, Store, Target, Unit} from "unit"

## The tool name of the findings of the rules.
export TOOL = "rules"

## The mark of a function that counts as fine for CC_SHORT (CC_ASSUME_SHORT, `[assume] short`).
export ASSUME_SHORT = "assume_short"

## The mark of a function that no walk goes into (CC_STOP, `[assume] stop`).
export STOP = "stop"

# The mark of a short lock: a field or a global marked CC_NO_SYSCALL_UNDER().
SHORT_LOCK_MARK = "no_syscall_under()"

# The effects a rule looks for.
enum Effect
  Blocks
  Allocates
  System
end

## The call graph of the project. A function is merged from all its declarations: the marks of each, and the place of
## its definition. A slot holds every function stored in it. `pointers` are the slots of each call through a pointer,
## by its caller and place (`caller LINE:COL`). `locks` are the classes of the locks that a function takes with each
## call of a lock function, by caller and callee (`caller>callee`), "" for a lock the rules cannot tell.
export struct Graph
  functions: Map[String, Function]
  edges: Map[String, List[Target]]
  slots: Map[String, List[String]]
  pointers: Map[String, List[String]] = {}
  locks: Map[String, List[String]] = {}
end

# How a rule walks the graph: the families of blocking calls that are on, whether it goes into the functions that never
# return or are cold, whether it finds every bad call or stops at the first, and the classes of the short locks, whose
# taking is not blocking.
struct Walk
  families: List[Known.Family]
  follow_cold: Bool
  all: Bool
  short_locks: Set[String]
end

## What the rules found: the findings, and the callbacks of libuv calls they could not follow to a function.
## `missing_roots` are the names of `[roots]` that no function of the units defines, and `missing_assumed` those of
## `[assume]` that no function of the units declares, each with its key (`trace (assume.stop)`).
export struct Checked
  findings: List[Finding]
  unresolved: List[UnresolvedCallback]
  missing_roots: List[String] = []
  missing_assumed: List[String] = []
end

# The CC_SHORT roots inferred from the callbacks of libuv, by function key, each with the call that made it, and the
# callbacks that name no function.
struct Inferred
  roots: Map[String, String]
  unresolved: List[UnresolvedCallback]
end

## Returns the findings of the rules on the units of a run. A root is a function marked in the C, named in the
## `[roots]` of the settings, or, when `infer`, passed as a callback to a libuv call that runs it on the loop. The
## `[library]` flags that are off take their families out of the blocking calls. A root gives one finding for each
## rule it breaks, at the nearest bad call, or one for each bad call it reaches when `all_paths`. `cwd` shortens the
## paths of the inferred roots and of the unresolved callbacks; one outside it stays absolute.
export def check(units: List[Unit], config: Config, infer: Bool, all_paths: Bool, cwd: String) -> Checked
  graph = graph_of(units)
  families = Known.BLOCKING_FAMILIES.select do |family| not config.off.include?(family.flag) end
  walk = Walk(
    families: families,
    follow_cold: config.follow_cold,
    all: all_paths,
    short_locks: short_locks_of(units, config),
  )

  inferred = Inferred(roots: {}, unresolved: [])
  if infer and not config.off.include?(Known.CALLBACKS_FLAG)
    inferred = inferred_of(graph, units, cwd)
  end

  findings: List[Finding] = []
  for function in graph.functions.values
    if function.defined
      if function.marks.include?("short") or config.short.include?(function.name)
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

      if function.marks.include?("hot") or config.hot.include?(function.name)
        findings = findings.concat(broken(graph, walk, function, Effect.Allocates))
        findings = findings.concat(broken(graph, walk, function, Effect.System))
      end
    end
  end

  return Checked(
    findings: findings,
    unresolved: inferred.unresolved,
    missing_roots: missing_roots(graph, config),
    missing_assumed: missing_assumed(graph, config).concat(missing_locks(units, graph, config)),
  )
end

## Returns the units with the marks that `[assume]` gives the functions it names, as if the C had them.
export def assumed(units: List[Unit], config: Config) -> List[Unit]
  if config.trusted.empty? and config.stops.empty?
    return units
  end

  return units.map do |unit| unit.with(functions: unit.functions.map do |f| with_assumed(f, config) end) end
end

## Returns whether no walk goes into a function: it is marked CC_STOP or named in `[assume] stop`.
export def stopped?(graph: Graph, key: String) -> Bool
  return marked?(graph, key, STOP)
end

## Returns the functions of the units, each merged from all its declarations.
export def functions(units: List[Unit]) -> List[Function]
  return graph_of(units).functions.values
end

## Returns the names of the shortest call path from a function of the project to a system call, a blocking one
## included: [`key`'s name, ..., the call]; none when it makes none. A library function is a path of its own name when
## it is a system call.
export def system_path(graph: Graph, key: String) -> Optional[List[String]]
  # A function of the project marked CC_BLOCKING is one itself, whatever its body does. Every blocking call enters the
  # kernel whatever the `[library]` flags say, so the families passed do not change what a system call is.
  families = Known.BLOCKING_FAMILIES
  if stopped?(graph, key)
    return none
  end

  if has?(graph, families, key, Effect.System)
    return some([name_of(graph, key)])
  end

  # The lock rules follow every call, cold ones included: `[effects] follow_cold` is about the roots of the
  # effect rules.
  walk = Walk(families: families, follow_cold: true, all: false, short_locks: Set.new([]))
  paths = search(graph, walk, key, Effect.System)
  if paths.empty?
    return none
  end

  return some(paths.first.map do |k| name_of(graph, k) end)
end

## Returns the functions that a call through a pointer at `line`:`column` of `caller` reaches: those stored in its slot.
export def pointer_targets(graph: Graph, caller: String, line: Int, column: Int) -> List[String]
  slots = graph.pointers.get("#{caller} #{line}:#{column}").unwrap_or([])
  return slots.flat_map do |slot| graph.slots.get(slot).unwrap_or([]) end.uniq
end

## Returns the functions that a function calls, directly or through a slot.
export def callees(graph: Graph, key: String) -> List[String]
  found: List[String] = []
  for target in graph.edges.get(key).unwrap_or([])
    case target
      Target.Direct(to) -> found = found.push(to)
      Target.Slot(slot) -> found = found.concat(graph.slots.get(slot).unwrap_or([]))
    end
  end

  return found
end

## Returns whether the project defines the function.
export def defined?(graph: Graph, key: String) -> Bool
  return graph.functions.get(key).map do |f| f.defined end.unwrap_or(false)
end

## Returns the call graph of the units.
export def graph_of(units: List[Unit]) -> Graph
  functions: Map[String, Function] = {}
  edges: Map[String, List[Target]] = {}
  pointers: Map[String, List[String]] = {}
  locks: Map[String, List[String]] = {}
  stores: List[Store] = []
  for unit in units
    for function in unit.functions
      functions = functions.put(function.key, merged(functions.get(function.key), function))
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
        Target.Slot(slot) if call.line > 0 ->
          at = "#{call.caller} #{call.line}:#{call.column}"
          pointers = pointers.put(at, pointers.get(at).unwrap_or([]).push(slot))
        _ -> next
      end
    end

    stores = stores.concat(unit.stores)
  end

  return Graph(functions: functions, edges: edges, slots: slots_of(stores), pointers: pointers, locks: locks)
end

# The classes of the short locks: those marked CC_NO_SYSCALL_UNDER() and those of `[assume] short_locks`.
def short_locks_of(units: List[Unit], config: Config) -> Set[String]
  marked = units.flat_map do |unit| unit.lock_marks end
    .select do |m| m.mark == SHORT_LOCK_MARK end
    .map do |m| m.class end

  return Set.new(marked.concat(config.short_locks))
end

# Whether every call of the lock function `callee` in `key` takes a short lock, so the short rule does not count it.
def short_takes?(graph: Graph, walk: Walk, key: String, callee: String) -> Bool
  classes = graph.locks.get("#{key}>#{callee}").unwrap_or([])
  return not classes.empty? and classes.all? do |c| c != "" and walk.short_locks.include?(c) end
end

# The classes of `[assume] short_locks` that no lock of the units has: none taken and none marked, with their key.
def missing_locks(units: List[Unit], graph: Graph, config: Config) -> List[String]
  if config.short_locks.empty?
    return []
  end

  known = Set.new(
    graph.locks
      .values
      .flat_map do |classes| classes end
      .concat(units.flat_map do |unit| unit.lock_marks end.map do |m| m.class end),
  )

  return config.short_locks.uniq.select do |c| not known.include?(c) end.map do |c| "#{c} (assume.short_locks)" end
end

# The name of a function by key, or the key itself for one the units do not declare.
def name_of_key(functions: Map[String, Function], key: String) -> String
  return functions.get(key).map do |f| f.name end.unwrap_or(key)
end

# A function with the marks of `[assume]` that name it.
def with_assumed(function: Function, config: Config) -> Function
  marks = function.marks
  if config.trusted.include?(function.name)
    marks = marks.push(ASSUME_SHORT)
  end

  if config.stops.include?(function.name)
    marks = marks.push(STOP)
  end

  return function.with(marks: marks.uniq)
end

# The names of `[assume]` that no function of the graph has, defined or declared, each with its key.
def missing_assumed(graph: Graph, config: Config) -> List[String]
  if config.trusted.empty? and config.stops.empty?
    return []
  end

  known = Set.new(graph.functions.values.map do |f| f.name end)
  short = config.trusted.uniq.select do |name| not known.include?(name) end.map do |name| "#{name} (assume.short)" end
  stop = config.stops.uniq.select do |name| not known.include?(name) end.map do |name| "#{name} (assume.stop)" end
  return short.concat(stop)
end

def marked?(graph: Graph, key: String, mark: String) -> Bool
  return graph.functions.get(key).map do |f| f.marks.include?(mark) end.unwrap_or(false)
end

# The names of `[roots]` that no function of the graph defines.
def missing_roots(graph: Graph, config: Config) -> List[String]
  names = config.short.concat(config.hot).uniq
  if names.empty?
    return []
  end

  defined = Set.new(graph.functions.values.select do |f| f.defined end.map do |f| f.name end)
  return names.select do |name| not defined.include?(name) end
end

# The source of a finding of an inferred root: the flag of the inference, and that of the family of the blocking call
# when one made it, as either flag turns the finding off.
def inferred_source(family: String) -> String
  if family == ""
    return Known.CALLBACKS_FLAG
  end

  return "#{Known.CALLBACKS_FLAG}+#{family}"
end

# The callbacks in the order of their places, so that the root of a function passed at several places is the first.
def inferred_of(graph: Graph, units: List[Unit], cwd: String) -> Inferred
  callbacks = units.flat_map do |unit| unit.callbacks end
    .sort_by do |c| "#{c.file}\n#{padded(c.line)}:#{c.argument}" end

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

  return Inferred(roots: roots, unresolved: unresolved)
end

# Zero-padded, so that the text order is the order of the numbers.
def padded(n: Int) -> String
  digits = n.to_s
  return "0" * (9 - digits.length) + digits
end

def same?(known: UnresolvedCallback, callback: Callback, shown: String) -> Bool
  return (
    known.file == shown and
    known.line == callback.line and
    known.call == callback.call and
    known.argument == callback.argument
  )
end

def keys_of(graph: Graph, source: Source) -> List[String]
  case source
    Source.Function(key) -> return [key]
    Source.Copy(from) -> return graph.slots.get(from).unwrap_or([])
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

  return slots
end

# One function from two declarations: the marks and attributes of both, at the place of the definition.
def merged(known: Optional[Function], function: Function) -> Function
  case known
    some(before) ->
      marks = before.marks.concat(function.marks).uniq
      noreturn = before.noreturn or function.noreturn
      cold = before.cold or function.cold
      if before.defined
        return before.with(marks: marks, noreturn: noreturn, cold: cold)
      end

      return function.with(marks: marks, noreturn: noreturn, cold: cold)
    none -> return function
  end
end

# The findings of a rule on a function, when the function reaches what the rule forbids: one for each bad call the
# walk finds, each with its shortest call path.
def broken(graph: Graph, walk: Walk, function: Function, effect: Effect) -> List[Finding]
  return search(graph, walk, function.key, effect).map do |path|
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
    for callee in callees(graph, key)
      if callers.key?(callee) or cut?(graph, walk, callee, effect, not walk.follow_cold)
        next
      end

      if effect == Effect.Blocks and short_takes?(graph, walk, key, callee)
        next
      end

      callers = callers.put(callee, key)
      if has?(graph, walk.families, callee, effect)
        found = found.push(path_to(callers, start, callee))
        if not walk.all
          return found
        end
      elsif defined?(graph, callee)
        queue = queue.push(callee)
      end
    end
  end

  return found
end

# Whether the walk of a rule does not go into a function: it is stopped, trusted for the short rule, or (with `cold`)
# it never returns or is cold.
def cut?(graph: Graph, walk: Walk, key: String, effect: Effect, cold: Bool) -> Bool
  # A function that blocks itself (CC_BLOCKING) cannot be assumed short; CC_STOP wins over every mark.
  trusted = marked?(graph, key, ASSUME_SHORT) and not marked?(graph, key, "blocking")
  if stopped?(graph, key) or (effect == Effect.Blocks and trusted)
    return true
  end

  return cold and skips?(graph, key)
end

# A function that never returns or is cold, which the walk does not go into, unless a CC_BLOCKING mark says what it
# does: the mark wins.
def skips?(graph: Graph, key: String) -> Bool
  return graph.functions
    .get(key)
    .map do |f| (f.noreturn or f.cold) and not f.marks.include?("blocking") end
    .unwrap_or(false)
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

  return path
end

def has?(graph: Graph, families: List[Known.Family], key: String, effect: Effect) -> Bool
  name = name_of(graph, key)
  marked = graph.functions.get(key).map do |f| f.marks.include?("blocking") end.unwrap_or(false)
  library = not defined?(graph, key)
  case effect
    Effect.Blocks -> return marked or (library and families.any? do |family| family.calls.include?(name) end)
    Effect.Allocates -> return library and Known.ALLOCATING.include?(name)
    Effect.System -> return marked or (library and (Known.SYSTEM.include?(name) or Known.BLOCKING.include?(name)))
  end
end

# The `[library]` flag whose family made the last call of a path blocking, or "" when a mark did, or for the rules of
# CC_HOT, which no flag turns off.
def source_of(graph: Graph, families: List[Known.Family], key: String, effect: Effect) -> String
  if effect != Effect.Blocks or defined?(graph, key)
    return ""
  end

  name = name_of(graph, key)
  for family in families
    if family.calls.include?(name)
      return family.flag
    end
  end

  return ""
end

def name_of(graph: Graph, key: String) -> String
  return graph.functions.get(key).map do |f| f.name end.unwrap_or(key)
end

def code_of(effect: Effect) -> String
  case effect
    Effect.Blocks -> return "CC-EFFECT-SHORT-BLOCKS"
    Effect.Allocates -> return "CC-EFFECT-HOT-ALLOCATES"
    Effect.System -> return "CC-EFFECT-HOT-SYSCALL"
  end
end

def kind_of(function: Function, effect: Effect) -> String
  case effect
    Effect.Blocks -> return "short function #{function.name}"
    Effect.Allocates -> return "hot function #{function.name}"
    Effect.System -> return "hot function #{function.name}"
  end
end

def call_of(effect: Effect) -> String
  case effect
    Effect.Blocks -> return "the blocking call"
    Effect.Allocates -> return "the allocation"
    Effect.System -> return "the system call"
  end
end
