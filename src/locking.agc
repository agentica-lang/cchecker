## The lock rules on the paths of each function: a lock that a function takes is released on every path that returns,
## and a lock that it releases is one it holds. The set of a CC_PAIR is a lock too, which its restore releases; a
## restore with no set before it is a finding in a function that calls the set, and does nothing in one that does not.
## The body of a set with its own CC_PAIR is how the pair works, and may leave another pair set for its caller, except
## on a return of an error value, after which the caller does not restore. A function with CC_ACQUIRES or CC_RELEASES
## is a helper that takes or drops a lock for its callers: its body is how the lock works (a count of nested takes, a
## spin before the wait), and the rules trust it and check its callers.
##
## The walk follows the graph of `Flow` in breadth, with the state of each path: how many times it took each lock less
## the times it released it, and the value of the conditions it went through that the function tests twice (`if
## (locked) lock(); ... if (locked) unlock();`), so a path that would need a condition to be true and false is not
## followed. A write to a variable forgets the conditions that read it. A call that may jump out (CC_MAY_JUMP) is also
## a way out of the function, with the locks held before it, and so is one that always jumps (CC_JUMPS), where the path
## ends.

import Effects from "effects"
import {Finding, IncompleteFunction} from "findings"
import Flow from "flow"
import {Body, Event, Fact, Lock, Mark, Site} from "flow"
import Held from "held"
import {Function, PAIR_MARK, Unit} from "unit"

## The code of a path that returns with a lock that the function took.
export NOT_RELEASED = "CC-PATH-LOCK-NOT-RELEASED"

## The code of a path that releases a lock that the function did not take.
export NOT_HELD = "CC-PATH-LOCK-NOT-HELD"

## The code of a path that returns after a call of the set of a CC_PAIR and no call of its restore.
export PAIR_NOT_RESTORED = "CC-PATH-PAIR-NOT-RESTORED"

## The code of a path that calls the restore of a CC_PAIR with no call of its set before it, in a function that calls
## the set on some path.
export PAIR_NOT_SET = "CC-PATH-PAIR-NOT-SET"

# A lock taken or released more times than this on one path counts as this many, so a loop ends.
MAX_COUNT = 2

# The states the walk of one function may visit, with the conditions and then without them. A function with more
# paths than this is checked on those it went through only, and counted (`Checked.incomplete`).
MAX_STATES = 200_000

# The most steps of a path a finding shows: the first ones and the last ones.
MAX_PATH = 24

# The state of a path: for each lock key, the takes less the releases, and the known value of each tracked condition.
struct State
  held: Map[String, Int]
  facts: Map[String, Bool]
  # The pairs set more than MAX_COUNT times on the path: their count is a floor, so a restore at zero is no finding.
  clamped: Set[String]
end

# One step of a path, as the finding shows it, and the key and the text of the lock it took (`took`) or released (""
# for none).
struct Step
  text: String
  lock: String = ""
  shown: String = ""
  took: Bool = false
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

# What the walk of one function reads: the merged functions of the project, the rules on held locks, the conditions it
# tracks and the variables they read, the locks of its calls by key, and the keys of its own CC_NO_SYSCALL_UNDER(lock).
struct Walker
  body: Body
  functions: Map[String, Function]
  rules: Held.Rules
  tracked: Set[String]
  roots: Map[String, List[String]]
  locks: Map[String, Lock]
  quiet: Set[String]
  # The keys of the pairs whose set the function calls on some path.
  sets: Set[String]
  # Whether the function is the set of its own CC_PAIR, whose successful returns may leave another pair set.
  own_set: Bool
end

# What a walk found: the findings by code and lock key, and whether it went through every path.
struct Walk
  findings: Map[String, Finding]
  complete: Bool
end

## The findings of the lock rules, and how many functions had more paths than the walk follows (their findings are
## those of the paths it went through).
export struct Checked
  findings: List[Finding]
  incomplete: List[IncompleteFunction]
end

## Returns the findings of the lock rules on the functions of the units. A function defined in several units (a static
## inline function of a header) is checked once.
export def check(units: List[Unit]) -> Checked
  graph = Effects.graph_of(units)
  rules = Held.rules_of(units, graph)
  functions: Map[String, Function] = {}
  for function in graph.functions.values
    functions = functions.put(function.key, function)
  end

  done: Set[String] = Set.new([])
  findings: List[Finding] = []
  incomplete: List[IncompleteFunction] = []
  for unit in units
    for body in unit.bodies
      if not done.include?(body.key) and not helper?(functions.get(body.key)) and not locks_of(body).empty?
        walk = checked(body, functions, rules)
        findings = findings.concat(walk.findings.values)
        if not walk.complete
          incomplete = incomplete.push(IncompleteFunction(file: body.file, line: body.line, function: body.name))
        end
      end

      done = done.add(body.key)
    end
  end

  return Checked(findings: findings, incomplete: incomplete)
end

## Returns the conditions that the function tests in two places or more: only those can make a path impossible.
export def tracked_of(body: Body) -> Set[String]
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

## Returns a finding at the function, with its path cut to the first and the last steps when it is long.
export def located(body: Body, code: String, message: String, path: List[String]) -> Finding
  texts = path
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

## Returns the variables each condition reads, so a write to one of them forgets the condition.
export def roots_of(body: Body) -> Map[String, List[String]]
  roots: Map[String, List[String]] = {}
  for node in body.nodes
    case node.event
      Event.Branch(fact) -> roots = roots.put(fact.text, fact.roots)
      _ -> next
    end
  end

  return roots
end

## Returns the known conditions without those that read one of `names`, which a path just wrote.
export def forgotten(
  facts: Map[String, Bool],
  roots: Map[String, List[String]],
  names: List[String],
) -> Map[String, Bool]
  return facts.select do |text, _value| not roots.get(text, []).any? do |root| names.include?(root) end end
end

## Returns whether a call never comes back: by its type or name, or by a CC_NORETURN on the function.
export def stops?(site: Site, functions: Map[String, Function]) -> Bool
  noreturn = functions.get(site.key).map do |f| f.noreturn end.unwrap_or(false)
  return site.stops or noreturn
end

## Returns whether a call may jump out of its caller (CC_MAY_JUMP, `[assume] may_jump`, CC_JUMPS, `[assume] jumps`):
## the call is a way out of the caller. When it also never comes back (`stops?`), the jump is its only way out and the
## path ends there; otherwise the path goes on after the call too.
export def jumps?(site: Site, functions: Map[String, Function]) -> Bool
  marks = functions.get(site.key).map do |f| f.marks end.unwrap_or([])
  return marks.include?(Effects.MAY_JUMP) or marks.include?(Effects.JUMPS)
end

## Returns the step that ends a path at a call that jumps out of the caller: `jumps in` for a call that never comes
## back (`stops`), `may jump in` for one that may also return, with the chain of calls of an inferred jump
## (`may jump in path_of (as_string, wrong_tag)`).
export def jump_text(site: Site, stops: Bool, functions: Map[String, Function]) -> String
  via = functions.get(site.key).map do |f| f.via end.unwrap_or([])
  chain = ""
  if not via.empty?
    chain = " (#{via.join(", ")})"
  end

  if stops
    return "#{site.line}:#{site.column} jumps in #{site.name}#{chain}"
  end

  return "#{site.line}:#{site.column} may jump in #{site.name}#{chain}"
end

## Returns the word of the value of a condition on a step of a path.
export def truth(fact: Fact) -> String
  if fact.value
    return "true"
  end

  return "false"
end

def helper?(function: Optional[Function]) -> Bool
  marks = function.map do |f| f.marks end.unwrap_or([])
  return marks.any? do |mark| mark.start_with?("acquires(") or mark.start_with?("releases(") end
end

# The findings of one function: with the conditions it tests twice, or without them when there are too many paths.
def checked(body: Body, functions: Map[String, Function], rules: Held.Rules) -> Walk
  marks = functions.get(body.key).map do |f| f.marks end.unwrap_or([])
  walker = Walker(
    body: body,
    functions: functions,
    rules: rules,
    tracked: tracked_of(body),
    roots: roots_of(body),
    locks: locks_of(body),
    quiet: Set.new(marks.flat_map(&quiet_keys)),
    sets: sets_of(body),
    own_set: pair_set?(body.name, marks),
  )

  walk = walked(walker)
  if not walk.complete
    walk = walked(walker.with(tracked: Set.new([])))
  end

  return walk
end

# Whether a function is the set of a CC_PAIR on its own declaration: `pair(name, ...)`.
def pair_set?(name: String, marks: List[String]) -> Bool
  return marks.any? do |mark| mark.start_with?("#{PAIR_MARK}#{name},") end
end

# The keys of the locks of a mark `no_syscall_under(a, b)` of the function itself.
def quiet_keys(mark: String) -> List[String]
  prefix = "no_syscall_under("
  if not mark.start_with?(prefix) or not mark.end_with?(")")
    return []
  end

  inside = mark.slice(prefix.length, mark.length - prefix.length - 1)
  return inside.split(",").map do |text| text.strip end.select do |text| text != "" end.map(&Flow.key_of)
end

# The locks that the calls of a function take, release or wait on, by key.
def locks_of(body: Body) -> Map[String, Lock]
  locks: Map[String, Lock] = {}
  for node in body.nodes
    case node.event
      Event.Call(site) ->
        for lock in site.takes.concat(site.drops).concat(site.waits)
          if not locks.key?(lock.key) or locks[lock.key].class == ""
            locks = locks.put(lock.key, lock)
          end
        end

      _ -> next
    end
  end

  return locks
end

# The keys of the pairs whose set the body calls.
def sets_of(body: Body) -> Set[String]
  keys: Set[String] = Set.new([])
  for node in body.nodes
    case node.event
      Event.Call(site) ->
        for lock in site.takes
          if lock.pair != ""
            keys = keys.add(lock.key)
          end
        end

      _ -> next
    end
  end

  return keys
end

def walked(walker: Walker) -> Walk
  body = walker.body
  queue = [Item(node: 0, state: State(held: {}, facts: {}, clamped: Set.new([])), path: [])]
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
    found = with_breaches(found, walker, item, node.event)
    found = with_jump(found, walker, item, node.event)
    case stepped(walker, node.event, item)
      Moved.Ended(path) -> found = with_exit(found, walker, item.state, path, failed?(node.event))
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

# A call that may jump out is a way out of the function too, with the locks the path holds before the call: one that
# jumps did not finish, so it took and released nothing. The jump is an error exit (`failed: true` for `with_exit`).
# A call that never comes back and jumps (CC_JUMPS) is checked here too, before `stepped` ends its path.
def with_jump(found: Map[String, Finding], walker: Walker, item: Item, event: Event) -> Map[String, Finding]
  case event
    Event.Call(site) ->
      if not jumps?(site, walker.functions)
        return found
      end

      step = Step(text: jump_text(site, stops?(site, walker.functions), walker.functions))
      return with_exit(found, walker, item.state, item.path.push(step), true)
    _ -> return found
  end
end

# Whether an event is a return of an error value.
def failed?(event: Event) -> Bool
  case event
    Event.Exit(mark) -> return mark.failed
    _ -> return false
  end
end

# The findings of the rules on held locks at a call that the path makes, and of a restore with no set before it.
def with_breaches(found: Map[String, Finding], walker: Walker, item: Item, event: Event) -> Map[String, Finding]
  case event
    Event.Call(site) ->
      unset = with_unset(found, walker, item, site)
      held = item.state
        .held
        .keys
        .select do |key| item.state.held[key] > 0 end
        .map do |key| held_lock(walker, item, key) end

      kept = unset
      for breach in Held.at_call(walker.rules, walker.body, held, site, "#{site.line}:#{site.column}")
        if not kept.key?(breach.id)
          kept = kept.put(breach.id, located(walker.body, breach.code, breach.message, breach.path))
        end
      end

      return kept
    _ -> return found
  end
end

# A restore that restores nothing on the path, of a pair whose set the function calls: every pair it restores is at a
# count of zero (one restore of two sets restores either), and none was set more than MAX_COUNT times. The path goes
# from the last set (or the start) to the restore. A count of zero stays zero, so a set after it still needs its own
# restore.
def with_unset(found: Map[String, Finding], walker: Walker, item: Item, site: Site) -> Map[String, Finding]
  state = item.state
  pairs = site.drops.select do |lock| lock.pair != "" end
  if pairs.any? do |lock| state.held.get(lock.key, 0) > 0 or state.clamped.include?(lock.key) end
    return found
  end

  sets = pairs.select do |lock| walker.sets.include?(lock.key) end
  if sets.empty? or found.key?("#{PAIR_NOT_SET} #{sets.first.key}")
    return found
  end

  key = sets.first.key
  steps = from_last(item.path, key, true).map do |step| step.text end
  message = "#{walker.body.name} calls #{site.name} with no call of #{set_of(key)} before it on a path"
  path = steps.push("#{site.line}:#{site.column} calls #{site.name}")
  return found.put("#{PAIR_NOT_SET} #{key}", located(walker.body, PAIR_NOT_SET, message, path))
end

def held_lock(walker: Walker, item: Item, key: String) -> Held.Held
  lock = walker.locks.get(key).unwrap_or(Lock(key: key, shown: key))
  steps = from_last(item.path, key, true).map do |step| step.text end
  return Held.Held(lock: lock, quiet: walker.quiet.include?(key), path: steps)
end

def stepped(walker: Walker, event: Event, item: Item) -> Moved
  functions = walker.functions
  tracked = walker.tracked
  roots = walker.roots
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
    _ -> return Moved.Went(item)
  end
end

def marked(mark: Mark) -> Step
  return Step(text: "#{mark.line}:#{mark.column} #{mark.word}")
end

# The state and the path after a call: the locks it takes and releases. The step of a pair names the call.
def after_call(item: Item, site: Site) -> Item
  held = item.state.held
  clamped = item.state.clamped
  steps = item.path
  for lock in site.takes
    if lock.pair != "" and held.get(lock.key, 0) >= MAX_COUNT
      clamped = clamped.add(lock.key)
    end

    held = counted(held, lock.key, 1)
    text = "takes #{lock.shown}"
    if lock.pair != ""
      text = "calls #{site.name}"
    end

    steps = steps.push(
      Step(text: "#{site.line}:#{site.column} #{text}", lock: lock.key, shown: lock.shown, took: true),
    )
  end

  for lock in site.drops
    text = "releases #{lock.shown}"
    if lock.pair != ""
      text = "calls #{site.name}"
    end

    if lock.pair == "" or held.get(lock.key, 0) > 0
      held = counted(held, lock.key, -1)
    end

    steps = steps.push(Step(text: "#{site.line}:#{site.column} #{text}", lock: lock.key, shown: lock.shown))
  end

  return item.with(state: item.state.with(held: held, clamped: clamped), path: steps)
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
def with_exit(
  found: Map[String, Finding],
  walker: Walker,
  state: State,
  path: List[Step],
  failed: Bool,
) -> Map[String, Finding]
  kept = found
  for key in state.held.keys
    count = state.held[key]
    restore = walker.locks.get(key).map do |lock| lock.pair end.unwrap_or("")
    code = NOT_RELEASED
    if restore != ""
      code = PAIR_NOT_RESTORED
    elsif count < 0
      code = NOT_HELD
    end

    # The body of a set with its own pair leaves the other pairs set for its caller, unless it returns an error.
    trusted = code == PAIR_NOT_RESTORED and walker.own_set and not failed
    id = "#{code} #{key}"
    if not trusted and not kept.key?(id)
      kept = kept.put(id, finding(walker.body, code, key, restore, path))
    end
  end

  return kept
end

# The path starts at the last take of the lock for a lock left held (or a pair not restored), at its last release
# for one not held.
def finding(body: Body, code: String, key: String, restore: String, path: List[Step]) -> Finding
  steps = from_last(path, key, code != NOT_HELD)
  shown = steps.first.shown
  message = "#{body.name} does not release #{shown} on every path"
  if code == NOT_HELD
    message = "#{body.name} releases #{shown}, which it does not hold, on a path"
  elsif code == PAIR_NOT_RESTORED
    set = set_of(key)
    message = "#{body.name} calls #{set} and does not call #{restore} after it on every path"
  end

  return located(body, code, message, steps.map do |step| step.text end)
end

# The set of the lock key of a pair: `mask_signals` for `pair:mask_signals:restore_signals`.
def set_of(key: String) -> String
  return key.slice(Flow.PAIR_PREFIX.length, key.length - Flow.PAIR_PREFIX.length).split(":").first
end

# The steps of a path from the last one that took the lock (`took`) or released it.
def from_last(path: List[Step], key: String, took: Bool) -> List[Step]
  start = 0
  for i in 0...path.size
    if path[i].lock == key and path[i].took == took
      start = i
    end
  end

  return path.drop(start)
end

# The state as a text, the same for two states with the same locks and conditions whatever their order.
def encoded(state: State) -> String
  held = state.held.keys.sort.map do |key| "#{key}=#{state.held[key]}" end
  facts = state.facts.keys.sort.map do |text| "#{text}=#{state.facts[text]}" end
  return "#{held.join(";")}|#{facts.join(";")}|#{state.clamped.to_a.sort.join(";")}"
end
