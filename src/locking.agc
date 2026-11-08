## The lock rules on the paths of each function: a lock that a function takes is released on every path that returns,
## and a lock that it releases is one it holds. A function with CC_ACQUIRES or CC_RELEASES is a helper that takes or
## drops a lock for its callers: its body is how the lock works (a count of nested takes, a spin before the wait), and
## the rules trust it and check its callers.
##
## The walk follows the graph of `Flow` in breadth, with the state of each path: how many times it took each lock less
## the times it released it, and the value of the conditions it went through that the function tests twice (`if
## (locked) lock(); ... if (locked) unlock();`), so a path that would need a condition to be true and false is not
## followed. A write to a variable forgets the conditions that read it.

import Effects from "effects"
import {Finding} from "findings"
import {Body, Event, Fact, Mark, Site} from "flow"
import {Function, Unit} from "unit"

## The code of a path that returns with a lock that the function took.
export NOT_RELEASED = "CC-PATH-LOCK-NOT-RELEASED"

## The code of a path that releases a lock that the function did not take.
export NOT_HELD = "CC-PATH-LOCK-NOT-HELD"

# A lock taken or released more times than this on one path counts as this many, so a loop ends.
MAX_COUNT = 2

# The states the walk of one function may visit, with the conditions and then without them. A function with more
# paths than this is not checked.
MAX_STATES = 200_000

# The most steps of a path a finding shows: the first ones and the last ones.
MAX_PATH = 24

# The state of a path: for each lock key, the takes less the releases, and the known value of each tracked condition.
struct State
  held: Map[String, Int]
  facts: Map[String, Bool]
end

# One step of a path, as the finding shows it, and the key and the text of the lock it took or released ("" for none).
struct Step
  text: String
  lock: String = ""
  shown: String = ""
end

struct Item
  node: Int
  state: State
  path: List[Step]
end

# What a node does to a path: it goes on with a new state, it ends with this path (a return), or it stops (a call
# that does not come back, or a condition that the path already knows is the other way).
enum Moved
  Went(Item)
  Ended(List[Step])
  Stopped
end

# What a walk found: the findings by code and lock key, and whether it went through every path.
struct Walk
  findings: Map[String, Finding]
  complete: Bool
end

## Returns the findings of the lock rules on the functions of the units. A function defined in several units (a static
## inline function of a header) is checked once.
export def check(units: List[Unit]) -> List[Finding]
  functions: Map[String, Function] = {}
  for function in Effects.functions(units)
    functions = functions.put(function.key, function)
  end

  done: Set[String] = Set.new([])
  findings: List[Finding] = []
  for unit in units
    for body in unit.bodies
      if not done.include?(body.key) and not helper?(functions.get(body.key))
        findings = findings.concat(checked(body, functions))
      end

      done = done.add(body.key)
    end
  end

  return findings
end

def helper?(function: Optional[Function]) -> Bool
  marks = function.map do |f| f.marks end.unwrap_or([])
  return marks.any? do |mark| mark.start_with?("acquires(") or mark.start_with?("releases(") end
end

# The findings of one function: with the conditions it tests twice, or without them when there are too many paths.
def checked(body: Body, functions: Map[String, Function]) -> List[Finding]
  walk = walked(body, functions, tracked_of(body))
  if not walk.complete
    walk = walked(body, functions, Set.new([]))
  end

  return walk.findings.values
end

# The conditions that the function tests in two places or more: only those can make a path impossible.
def tracked_of(body: Body) -> Set[String]
  seen: Set[String] = Set.new([])
  twice: Set[String] = Set.new([])
  for node in body.nodes
    case node.event
      Event.Branch(fact) ->
        if fact.text != "" and fact.value
          if seen.include?(fact.text)
            twice = twice.add(fact.text)
          end

          seen = seen.add(fact.text)
        end

      _ -> next
    end
  end

  return twice
end

def walked(body: Body, functions: Map[String, Function], tracked: Set[String]) -> Walk
  roots = roots_of(body)
  queue = [Item(node: 0, state: State(held: {}, facts: {}), path: [])]
  visited: Set[String] = Set.new([])
  found: Map[String, Finding] = {}
  i = 0
  while i < queue.size
    if i >= MAX_STATES
      return Walk(findings: found, complete: false)
    end

    item = queue[i]
    i += 1
    node = body.nodes[item.node]
    case stepped(node.event, item, functions, tracked, roots)
      Moved.Ended(path) -> found = with_exit(found, body, item.state, path)
      Moved.Stopped -> next
      Moved.Went(moved) ->
        for after in node.next
          seen = "#{after}|#{encoded(moved.state)}"
          if not visited.include?(seen)
            visited = visited.add(seen)
            queue = queue.push(moved.with(node: after))
          end
        end
    end
  end

  return Walk(findings: found, complete: true)
end

def stepped(
  event: Event,
  item: Item,
  functions: Map[String, Function],
  tracked: Set[String],
  roots: Map[String, List[String]],
) -> Moved
  state = item.state
  case event
    Event.Join -> return Moved.Went(item)
    Event.Call(site) ->
      if stops?(site, functions)
        return Moved.Stopped
      end

      return Moved.Went(after_call(item, site))
    Event.Branch(fact) ->
      step = Step(text: "#{fact.line}:#{fact.column} #{truth(fact)}")
      if not tracked.include?(fact.text)
        return Moved.Went(item.with(path: item.path.push(step)))
      end

      if state.facts.get(fact.text).map do |known| known != fact.value end.unwrap_or(false)
        return Moved.Stopped
      end

      facts = state.facts.put(fact.text, fact.value)
      return Moved.Went(item.with(state: state.with(facts: facts), path: item.path.push(step)))
    Event.Writes(names) -> return Moved.Went(item.with(state: state.with(facts: forgotten(state.facts, roots, names))))
    Event.Note(mark) -> return Moved.Went(item.with(path: item.path.push(marked(mark))))
    Event.Exit(mark) -> return Moved.Ended(item.path.push(marked(mark)))
  end
end

def marked(mark: Mark) -> Step
  return Step(text: "#{mark.line}:#{mark.column} #{mark.word}")
end

# The state and the path after a call: the locks it takes and releases.
def after_call(item: Item, site: Site) -> Item
  held = item.state.held
  steps = item.path
  for lock in site.takes
    held = counted(held, lock.key, 1)
    steps = steps.push(
      Step(text: "#{site.line}:#{site.column} takes #{lock.shown}", lock: lock.key, shown: lock.shown),
    )
  end

  for lock in site.drops
    held = counted(held, lock.key, -1)
    steps = steps.push(
      Step(text: "#{site.line}:#{site.column} releases #{lock.shown}", lock: lock.key, shown: lock.shown),
    )
  end

  return item.with(state: item.state.with(held: held), path: steps)
end

# A count of zero leaves the map, so two paths that hold the same locks have the same state.
def counted(held: Map[String, Int], key: String, by: Int) -> Map[String, Int]
  count = held.get(key, 0) + by
  if count > MAX_COUNT
    count = MAX_COUNT
  end

  if count < -MAX_COUNT
    count = -MAX_COUNT
  end

  if count == 0
    return held.delete(key)
  end

  return held.put(key, count)
end

# The findings of a path that ends: each lock it holds that it took, and each it released and did not take. One finding
# for each code and lock: the first path, which is a shortest one.
def with_exit(found: Map[String, Finding], body: Body, state: State, path: List[Step]) -> Map[String, Finding]
  kept = found
  for key in state.held.keys
    count = state.held[key]
    code = NOT_RELEASED
    if count < 0
      code = NOT_HELD
    end

    id = "#{code} #{key}"
    if not kept.key?(id)
      kept = kept.put(id, finding(body, code, key, path))
    end
  end

  return kept
end

def finding(body: Body, code: String, key: String, path: List[Step]) -> Finding
  start = 0
  for i in 0...path.size
    if path[i].lock == key
      start = i
    end
  end

  steps = path.drop(start)
  shown = steps.first.shown
  message = "#{body.name} does not release #{shown} on every path"
  if code == NOT_HELD
    message = "#{body.name} releases #{shown}, which it does not hold, on a path"
  end

  texts = steps.map do |step| step.text end
  if texts.size > MAX_PATH
    texts = texts.take(MAX_PATH / 2).push("...").concat(texts.drop(texts.size - MAX_PATH / 2))
  end

  return Finding(
    code: code,
    tool: Effects.TOOL,
    file: body.file,
    line: body.line,
    column: body.column,
    message: message,
    path: texts,
  )
end

# The variables each tracked condition reads, so a write to one of them forgets the condition.
def roots_of(body: Body) -> Map[String, List[String]]
  roots: Map[String, List[String]] = {}
  for node in body.nodes
    case node.event
      Event.Branch(fact) -> roots = roots.put(fact.text, fact.roots)
      _ -> next
    end
  end

  return roots
end

def forgotten(facts: Map[String, Bool], roots: Map[String, List[String]], names: List[String]) -> Map[String, Bool]
  return facts.select do |text, _value| not roots.get(text, []).any? do |root| names.include?(root) end end
end

def stops?(site: Site, functions: Map[String, Function]) -> Bool
  marked = functions.get(site.key).map do |f| f.marks.include?("noreturn") end.unwrap_or(false)
  return site.stops or marked
end

def truth(fact: Fact) -> String
  if fact.value
    return "true"
  end

  return "false"
end

# The state as a text, the same for two states with the same locks and conditions whatever their order.
def encoded(state: State) -> String
  held = state.held.keys.sort.map do |key| "#{key}=#{state.held[key]}" end
  facts = state.facts.keys.sort.map do |text| "#{text}=#{state.facts[text]}" end
  return "#{held.join(";")}|#{facts.join(";")}"
end
