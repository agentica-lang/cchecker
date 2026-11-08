## The effect rules on the call graph of the project: a CC_SHORT function never reaches a blocking call, and a CC_HOT
## function never allocates or makes a system call.

import {Finding} from "findings"
import Known from "known"
import {Function, Source, Store, Target, Unit} from "unit"

## The tool name of the findings of the rules.
export TOOL = "rules"

# The effects a rule looks for.
enum Effect
  Blocks
  Allocates
  System
end

# The call graph of the project. A function is merged from all its declarations: the marks of each, and the place of
# its definition. A slot holds every function stored in it.
struct Graph
  functions: Map[String, Function]
  edges: Map[String, List[Target]]
  slots: Map[String, List[String]]
end

## Returns the findings of the rules on the units of a run.
export def check(units: List[Unit]) -> List[Finding]
  graph = graph_of(units)
  findings: List[Finding] = []
  for function in graph.functions.values
    if function.defined
      if function.marks.include?("short")
        findings = findings.concat(broken(graph, function, Effect.Blocks))
      end

      if function.marks.include?("hot")
        findings = findings.concat(broken(graph, function, Effect.Allocates))
        findings = findings.concat(broken(graph, function, Effect.System))
      end
    end
  end

  return findings
end

def graph_of(units: List[Unit]) -> Graph
  functions: Map[String, Function] = {}
  edges: Map[String, List[Target]] = {}
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
    end

    stores = stores.concat(unit.stores)
  end

  return Graph(functions: functions, edges: edges, slots: slots_of(stores))
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

# One function from two declarations: the marks of both, at the place of the definition.
def merged(known: Optional[Function], function: Function) -> Function
  case known
    some(before) ->
      marks = before.marks.concat(function.marks).uniq
      if before.defined
        return before.with(marks: marks)
      end

      return function.with(marks: marks)
    none -> return function
  end
end

# The finding of a rule on a function, when the function reaches what the rule forbids: the shortest call path.
def broken(graph: Graph, function: Function, effect: Effect) -> List[Finding]
  case search(graph, function.key, effect)
    some(path) ->
      names = path.map do |key| name_of(graph, key) end
      # The message has no path, so the baseline holds when the path changes; the report prints the path.
      return [
        Finding(
          code: code_of(effect),
          tool: TOOL,
          file: function.file,
          line: function.line,
          column: function.column,
          message: "#{kind_of(function, effect)} reaches #{call_of(effect)} #{names.last}",
          path: names,
        ),
      ]
    none -> return []
  end
end

# A walk of the graph in breadth from `start`, which stops at the first function with the effect, and gives the keys
# of the path to it. It goes only through the functions that the project defines: one it does not define is a call of
# a library.
def search(graph: Graph, start: String, effect: Effect) -> Optional[List[String]]
  callers: Map[String, String] = {}
  callers = callers.put(start, start)
  queue = [start]
  i = 0
  while i < queue.size
    key = queue[i]
    i += 1
    for callee in callees(graph, key)
      if callers.key?(callee)
        next
      end

      callers = callers.put(callee, key)
      if has?(graph, callee, effect)
        return some(path_to(callers, start, callee))
      end

      if defined?(graph, callee)
        queue = queue.push(callee)
      end
    end
  end

  return none
end

# The functions a function calls, directly or through a slot.
def callees(graph: Graph, key: String) -> List[String]
  found: List[String] = []
  for target in graph.edges.get(key).unwrap_or([])
    case target
      Target.Direct(to) -> found = found.push(to)
      Target.Slot(slot) -> found = found.concat(graph.slots.get(slot).unwrap_or([]))
    end
  end

  return found
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

def has?(graph: Graph, key: String, effect: Effect) -> Bool
  name = name_of(graph, key)
  marked = graph.functions.get(key).map do |f| f.marks.include?("blocking") end.unwrap_or(false)
  library = not defined?(graph, key)
  case effect
    Effect.Blocks -> return marked or (library and Known.BLOCKING.include?(name))
    Effect.Allocates -> return library and Known.ALLOCATING.include?(name)
    Effect.System -> return marked or (library and (Known.SYSTEM.include?(name) or Known.BLOCKING.include?(name)))
  end
end

def defined?(graph: Graph, key: String) -> Bool
  return graph.functions.get(key).map do |f| f.defined end.unwrap_or(false)
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
