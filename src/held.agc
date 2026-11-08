## The rules on what runs while a lock is held, at each call of a path: no system call or blocking call under a lock
## marked CC_NO_SYSCALL_UNDER, directly or through the functions the call reaches, and the lock order of
## CC_LOCK_LEVEL: a lock is taken only while every lock held has a lower level.

import Effects from "effects"
import Flow from "flow"
import {Body, Event, Lock, Site} from "flow"
import Known from "known"
import {Unit} from "unit"

## The code of a system call or a blocking call under a lock marked CC_NO_SYSCALL_UNDER.
export SYSCALL_UNDER_LOCK = "CC-PATH-SYSCALL-UNDER-LOCK"

## The code of a lock taken while a lock of the same or a higher level is held.
export LOCK_ORDER = "CC-PATH-LOCK-ORDER"

# The marks of a lock class (a field or a global).
QUIET_MARK = "no_syscall_under()"
LEVEL_PREFIX = "lock_level("

## What the rules know of the project: its call graph, the classes of the locks marked CC_NO_SYSCALL_UNDER(), the level
## of each class with CC_LOCK_LEVEL, the classes each function takes in its own body, and the graphs of the functions
## that take or release a lock, by key.
export struct Rules
  graph: Effects.Graph
  quiet: Set[String]
  levels: Map[String, Int]
  takes: Map[String, Set[String]]
  bodies: Map[String, Body] = {}
end

## A lock that a path holds at a call, and the steps of the path from its take to the call. `quiet` is a lock that the
## function's own CC_NO_SYSCALL_UNDER(lock) names.
export struct Held
  lock: Lock
  quiet: Bool
  path: List[String]
end

## A rule that a call breaks: `id` tells two apart (one finding for each), and the message and the path of the finding.
export struct Breach
  id: String
  code: String
  message: String
  path: List[String]
end

## Returns what the rules need from the units: the marks of their lock fields and globals, and the classes that each
## function takes.
export def rules_of(units: List[Unit], graph: Effects.Graph) -> Rules
  quiet: Set[String] = Set.new([])
  levels: Map[String, Int] = {}
  takes: Map[String, Set[String]] = {}
  bodies: Map[String, Body] = {}
  for unit in units
    for mark in unit.lock_marks
      if mark.mark == QUIET_MARK
        quiet = quiet.add(mark.class)
      end

      case level_of(mark.mark)
        some(level) -> levels = levels.put(mark.class, level)
        none -> next
      end
    end

    for body in unit.bodies
      bodies = bodies.put(body.key, body)
      classes = takes.get(body.key).unwrap_or(Set.new([]))
      for node in body.nodes
        case node.event
          Flow.Event.Call(site) ->
            for lock in waited(site)
              if lock.class != ""
                classes = classes.add(lock.class)
              end
            end

          _ -> next
        end
      end

      takes = takes.put(body.key, classes)
    end
  end

  return Rules(graph: graph, quiet: quiet, levels: levels, takes: takes, bodies: bodies)
end

## Returns the rules that a call of `body` breaks while the path holds `held`; `at` is the step of the call
## (`LINE:COL`).
export def at_call(rules: Rules, body: Body, held: List[Held], site: Site, at: String) -> List[Breach]
  return under_quiet(rules, body, held, site, at).concat(out_of_order(rules, body, held, site, at))
end

# A call under a quiet lock that is, or reaches, a system call. The release of the lock and a wait on it are how the
# lock works, and so is the release of a lock taken under it, whose take is the finding. A function of the project
# that releases (CC_RELEASES) the quiet lock is held to the system calls it may make before that release, and one that
# releases a lock taken under it to all of them.
def under_quiet(rules: Rules, body: Body, held: List[Held], site: Site, at: String) -> List[Breach]
  quiet = held.select do |h| h.quiet or rules.quiet.include?(h.lock.class) end
  if quiet.empty?
    return []
  end

  reached = system_call(rules, body, site)
  found: List[Breach] = []
  for h in quiet
    path = reached
    if site.drops.concat(site.waits).any? do |lock| lock.key == h.lock.key end
      path = before_release(rules, body, site, some(h))
    elsif nested_release?(rules, body, held, h, site)
      path = before_release(rules, body, site, none)
    end

    if not path.empty?
      step = "#{at} calls #{site.name}"
      if path.size > 1 or site.pointer
        step = "#{step}: #{path.join(" -> ")}"
      end

      found = found.push(
        Breach(
          id: "#{SYSCALL_UNDER_LOCK} #{h.lock.key} #{site.name}",
          code: SYSCALL_UNDER_LOCK,
          message: "#{body.name} calls #{site.name} while holding #{h.lock.shown}",
          path: h.path.push(step),
        ),
      )
    end
  end

  return found
end

# Whether a call releases a lock taken while `h` was held: the path of a held lock starts at its last take, so a lock
# taken later has a shorter one.
def nested_release?(rules: Rules, body: Body, held: List[Held], h: Held, site: Site) -> Bool
  return site.drops.any? do |lock|
    held.any? do |other|
      other.lock.key == lock.key and other.path.size < h.path.size and system_take?(rules, body, other)
    end
  end
end

# Whether the take of a held lock was a system call, and so a finding of its own under the quiet lock: not a trylock,
# nor a helper whose body makes none. The first step of its path is its take (`LINE:COL takes LOCK`).
def system_take?(rules: Rules, body: Body, h: Held) -> Bool
  if h.path.empty?
    return false
  end

  at = h.path.first.split(" ").first
  for node in body.nodes
    case node.event
      Event.Call(call) ->
        taken = call.takes.any? do |lock| lock.key == h.lock.key end
        if taken and "#{call.line}:#{call.column}" == at
          return not system_call(rules, body, call).empty?
        end

      _ -> next
    end
  end

  return false
end

# The call path to a system call that a call which releases a lock makes while the quiet lock is held: none for a call
# of the library (the unlock, the wait), and for a function of the project the first system call on a path of its
# body, up to its unlock of `quiet` when it releases that lock, through the whole body when it releases another (a
# lock taken under the quiet one, the restore of a pair). An unlock or a wait in the body is a release, never the
# system call: its lock may be one under another name (`m = &q->mu`). A function with no graph (no lock call in it) is
# trusted when it releases `quiet`, and held to all it reaches otherwise.
def before_release(rules: Rules, body: Body, site: Site, quiet: Optional[Held]) -> List[String]
  case rules.bodies.get(site.key)
    some(helper) ->
      stops_at = quiet.map do |h| stop_keys(rules, helper, site, h) end.unwrap_or(Set.new([]))
      seen = Set.new([0])
      queue = [0]
      i = 0
      while i < queue.size
        node = helper.nodes[queue[i]]
        i += 1
        # The walk goes no further than the release of the quiet lock; after a wait it is held again.
        stops = false
        case node.event
          Event.Call(call) ->
            stops = call.drops.any? do |lock| stops_at.include?(lock.key) end
            path = system_call(rules, helper, call)
            if call.drops.concat(call.waits).empty? and not path.empty?
              return [site.name].concat(path)
            end

          _ -> stops = false
        end

        for after in node.next
          if not stops and not seen.include?(after)
            seen = seen.add(after)
            queue = queue.push(after)
          end
        end
      end

      return []
    none ->
      if quiet.some? or Known.DROPS.include?(site.name)
        return []
      end

      return system_call(rules, body, site)
  end
end

# The keys of the helper's own locks that the call releases as `h`. The locks of a call of the helper are those of its
# CC_RELEASES in order, one each; when the call has fewer (one it cannot name), any of them is. When the unit of the
# definition did not see the marked prototype (`releases` is empty), they are the marks merged from all declarations,
# in the names of the prototype that wrote them.
def stop_keys(rules: Rules, helper: Body, site: Site, h: Held) -> Set[String]
  if helper.releases.empty?
    return Set.new(marked_releases(rules, helper.key))
  end

  if helper.releases.size != site.drops.size
    return Set.new(helper.releases)
  end

  return Set.new(
    (0...site.drops.size).to_a.select do |i| site.drops[i].key == h.lock.key end.map do |i| helper.releases[i] end,
  )
end

# The keys of the locks of a function's CC_RELEASES marks, merged from all its declarations, as written.
def marked_releases(rules: Rules, key: String) -> List[String]
  marks = rules.graph.functions.get(key).map do |f| f.marks end.unwrap_or([])
  return marks.select do |mark| mark.start_with?("releases(") and mark.end_with?(")") end
    .flat_map do |mark| mark.slice(9, mark.length - 10).split(",") end
    .map do |lock| Flow.key_of(lock.strip) end
end

# The call path from the call to a system call: [the call] for a system or blocking call (a CC_BLOCKING function
# included), [the call, ..., the system call] for a function of the project that reaches one, [] for neither. A call
# through a pointer goes to the functions stored in it, and the path starts at the first of them that reaches one.
def system_call(rules: Rules, body: Body, site: Site) -> List[String]
  if not site.pointer
    return Effects.system_path(rules.graph, site.key).unwrap_or([])
  end

  for target in Effects.pointer_targets(rules.graph, body.key, site.line, site.column)
    case Effects.system_path(rules.graph, target)
      some(path) -> return path
      none -> next
    end
  end

  return []
end

# A lock with a level taken while a lock of the same or a higher level is held: by the call itself, or by a function
# of the project that the call reaches.
def out_of_order(rules: Rules, body: Body, held: List[Held], site: Site, at: String) -> List[Breach]
  leveled = held.select do |h| rules.levels.key?(h.lock.class) end
  if leveled.empty?
    return []
  end

  found: List[Breach] = []
  for lock in waited(site)
    for h in leveled
      if lock.key != h.lock.key and higher_or_same?(rules, h.lock.class, lock.class)
        found = found.push(
          Breach(
            id: "#{LOCK_ORDER} #{h.lock.key} #{lock.key}",
            code: LOCK_ORDER,
            message: "#{body.name} takes #{lock.shown} while holding #{h.lock.shown}",
            path: h.path.push("#{at} takes #{lock.shown}"),
          ),
        )
      end
    end
  end

  if not site.takes.empty? or not site.drops.empty?
    return found
  end

  # A function that takes the class of a lock held may take that very lock again, which a lock that counts its nested
  # takes allows: only another class is out of order.
  for class in reached_by(rules, body, site)
    for h in leveled
      if h.lock.class != class and higher_or_same?(rules, h.lock.class, class)
        found = found.push(
          Breach(
            id: "#{LOCK_ORDER} #{h.lock.key} #{site.name} #{class}",
            code: LOCK_ORDER,
            message: "#{body.name} calls #{site.name}, which takes #{class}, while holding #{h.lock.shown}",
            path: h.path.push("#{at} calls #{site.name}, which takes #{class}"),
          ),
        )
      end
    end
  end

  return found
end

def higher_or_same?(rules: Rules, held: String, taken: String) -> Bool
  case rules.levels.get(taken)
    some(level) -> return rules.levels[held] >= level
    none -> return false
  end
end

# The locks a call waits for: a trylock waits for none, so it never takes part in a cycle of waits.
def waited(site: Site) -> List[Lock]
  if site.tried
    return []
  end

  return site.takes
end

# The classes that a call takes through the functions it reaches: those of the callee, or of every function stored in
# the pointer it calls.
def reached_by(rules: Rules, body: Body, site: Site) -> List[String]
  if not site.pointer
    return reached_takes(rules, site.key)
  end

  targets = Effects.pointer_targets(rules.graph, body.key, site.line, site.column)
  return targets.flat_map do |target| reached_takes(rules, target) end.uniq
end

# The classes that a function of the project takes, in its body or in the functions it reaches.
def reached_takes(rules: Rules, start: String) -> List[String]
  if not Effects.defined?(rules.graph, start) or Effects.stopped?(rules.graph, start)
    return []
  end

  seen = Set.new([start])
  queue = [start]
  classes: Set[String] = Set.new([])
  i = 0
  while i < queue.size
    key = queue[i]
    i += 1
    classes = classes.union(rules.takes.get(key).unwrap_or(Set.new([])))
    for callee in Effects.callees(rules.graph, key)
      if (
        not seen.include?(callee) and
        Effects.defined?(rules.graph, callee) and
        not Effects.stopped?(rules.graph, callee)
      )
        seen = seen.add(callee)
        queue = queue.push(callee)
      end
    end
  end

  return classes.to_a
end

# The level of a mark `lock_level(N)`, or none for another mark.
def level_of(mark: String) -> Optional[Int]
  if not mark.start_with?(LEVEL_PREFIX) or not mark.end_with?(")")
    return none
  end

  inside = mark.slice(LEVEL_PREFIX.length, mark.length - LEVEL_PREFIX.length - 1).strip
  case inside.to_i
    ok(level) -> return some(level)
    error(_) -> return none
  end
end
