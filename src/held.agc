## The rules on what runs while a lock is held, at each call of a path: no system call or blocking call under a lock
## marked CC_NO_SYSCALL_UNDER, directly or through the functions the call reaches, and the lock order of
## CC_LOCK_LEVEL: a lock is taken only while every lock held has a lower level.

import Effects from "effects"
import Flow from "flow"
import {Lock, Site} from "flow"
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
## of each class with CC_LOCK_LEVEL, and the classes each function takes in its own body.
export struct Rules
  graph: Effects.Graph
  quiet: Set[String]
  levels: Map[String, Int]
  takes: Map[String, Set[String]]
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
      classes = takes.get(body.key).unwrap_or(Set.new([]))
      for node in body.nodes
        case node.event
          Flow.Event.Call(site) ->
            for lock in site.takes
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

  return Rules(graph: graph, quiet: quiet, levels: levels, takes: takes)
end

## Returns the rules that a call breaks while the path holds `held`. The caller is `name`; `at` is the step of the call
## (`LINE:COL`).
export def at_call(rules: Rules, name: String, held: List[Held], site: Site, at: String) -> List[Breach]
  return under_quiet(rules, name, held, site, at).concat(out_of_order(rules, name, held, site, at))
end

# A call under a quiet lock that is, or reaches, a system call. The release of the lock and a wait on it are how the
# lock works.
def under_quiet(rules: Rules, name: String, held: List[Held], site: Site, at: String) -> List[Breach]
  quiet = held.select do |h| h.quiet or rules.quiet.include?(h.lock.class) end
  if quiet.empty?
    return []
  end

  path = system_call(rules, site)
  if path.empty?
    return []
  end

  step = "#{at} calls #{site.name}"
  if path.size > 1
    step = "#{step}: #{path.join(" -> ")}"
  end

  found: List[Breach] = []
  for h in quiet
    own = site.drops.concat(site.waits).any? do |lock| lock.key == h.lock.key end
    if not own
      found = found.push(
        Breach(
          id: "#{SYSCALL_UNDER_LOCK} #{h.lock.key} #{site.name}",
          code: SYSCALL_UNDER_LOCK,
          message: "#{name} calls #{site.name} while holding #{h.lock.shown}",
          path: h.path.push(step),
        ),
      )
    end
  end

  return found
end

# The call path from the call to a system call: [the call] for a known one, [the call, ..., the system call] for a
# function of the project that reaches one, [] for neither.
def system_call(rules: Rules, site: Site) -> List[String]
  if not Effects.defined?(rules.graph, site.key)
    if Known.SYSTEM.include?(site.name) or Known.BLOCKING.include?(site.name)
      return [site.name]
    end

    return []
  end

  return Effects.system_path(rules.graph, site.key).unwrap_or([])
end

# A lock with a level taken while a lock of the same or a higher level is held: by the call itself, or by a function
# of the project that the call reaches.
def out_of_order(rules: Rules, name: String, held: List[Held], site: Site, at: String) -> List[Breach]
  leveled = held.select do |h| rules.levels.key?(h.lock.class) end
  if leveled.empty?
    return []
  end

  found: List[Breach] = []
  for lock in site.takes
    for h in leveled
      if lock.key != h.lock.key and higher_or_same?(rules, h.lock.class, lock.class)
        found = found.push(
          Breach(
            id: "#{LOCK_ORDER} #{h.lock.key} #{lock.key}",
            code: LOCK_ORDER,
            message: "#{name} takes #{lock.shown} while holding #{h.lock.shown}",
            path: h.path.push("#{at} takes #{lock.shown}"),
          ),
        )
      end
    end
  end

  if not site.takes.empty? or not site.drops.empty?
    return found
  end

  # A function that takes the class of a lock held may take that lock again, which a counted lock allows (the
  # nested takes of one runtime's lock): only another class is out of order.
  for class in reached_takes(rules, site.key)
    for h in leveled
      if h.lock.class != class and higher_or_same?(rules, h.lock.class, class)
        found = found.push(
          Breach(
            id: "#{LOCK_ORDER} #{h.lock.key} #{site.name} #{class}",
            code: LOCK_ORDER,
            message: "#{name} calls #{site.name}, which takes #{class}, while holding #{h.lock.shown}",
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

# The classes that a function of the project takes, in its body or in the functions it reaches.
def reached_takes(rules: Rules, start: String) -> List[String]
  if not Effects.defined?(rules.graph, start)
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
      if not seen.include?(callee) and Effects.defined?(rules.graph, callee)
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
