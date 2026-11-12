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
  # What `with_idle` settles for each flagged helper: its calls on the side of its flags where it does nothing to a
  # lock, the system calls they reach, and the classes they take.
  idle: Map[String, List[Site]] = {}
  idle_reach: Map[String, List[Reach]] = {}
  idle_classes: Map[String, Set[String]] = {}
end

## A system call that a call on the idle side of a flagged helper reaches: its call path, and the lock it waits on when
## it is a wait ("" for any other call). The lock is its class, or its key when it has none. Under that very lock a
## wait is no finding, since it gives the lock back while it waits.
export struct Reach
  path: List[String]
  waited: String
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

  with_idle(Rules(graph: graph, quiet: quiet, levels: levels, takes: takes, bodies: bodies))
end

## Returns the rules that a call of `body` breaks while the path holds `held`; `at` is the step of the call
## (`LINE:COL`).
export def at_call(rules: Rules, body: Body, held: List[Held], site: Site, at: String) -> List[Breach]
  under_quiet(rules, body, held, site, at).concat(out_of_order(rules, body, held, site, at))
end

# A call under a quiet lock that is, or reaches, a system call. The release of the lock and a wait on it are how the
# lock works, and so is the release of a lock taken under it, whose take is the finding. A function of the project
# that releases (CC_RELEASES) the quiet lock is held to the system calls it may make before that release, and one that
# releases a lock taken under it to all of them.
def under_quiet(rules: Rules, body: Body, held: List[Held], site: Site, at: String) -> List[Breach]
  quiet = held.select do |h| h.quiet or rules.quiet.include?(h.lock.class) end
  return [] if quiet.empty?

  reached: List[String] = []
  if not site.idle
    reached = system_call(rules, body, site)
  end

  found: List[Breach] = []
  for h in quiet
    path = reached
    if site.idle
      path = idle_path(rules, body, site, h)
    elsif site.drops.concat(site.waits).any? do |lock| lock.key == h.lock.key end
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

  found
end

# Whether a call releases a lock taken while `h` was held: the path of a held lock starts at its last take, so a lock
# taken later has a shorter one.
def nested_release?(rules: Rules, body: Body, held: List[Held], h: Held, site: Site) -> Bool
  site.drops.any? do |lock|
    held.any? do |other|
      other.lock.key == lock.key and other.path.size < h.path.size and system_take?(rules, body, other)
    end
  end
end

# Whether the take of a held lock was a system call, and so a finding of its own under the quiet lock: not a trylock,
# nor a helper whose body makes none. The first step of its path is its take (`LINE:COL takes LOCK`).
def system_take?(rules: Rules, body: Body, h: Held) -> Bool
  return false if h.path.empty?

  at = h.path.first.split(" ").first
  for node in body.nodes
    case node.event
      Event.Call(call) ->
        taken = call.takes.any? do |lock| lock.key == h.lock.key end
        return not system_call(rules, body, call).empty? if taken and "#{call.line}:#{call.column}" == at

      _ -> next
    end
  end

  false
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
      quiet_stops = quiet.map do |h| stop_keys(rules, helper, site, h) end
      stops_at = quiet_stops.unwrap_or(Set.new([]))
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
            return [site.name].concat(path) if call.drops.concat(call.waits).empty? and not path.empty?

          _ -> stops = false
        end

        for after in node.next
          if not stops and not seen.include?(after)
            seen = seen.add(after)
            queue = queue.push(after)
          end
        end
      end

      []
    none ->
      return [] if quiet.some? or Known.DROPS.include?(site.name)

      system_call(rules, body, site)
  end
end

# The keys of the helper's own locks that the call releases as `h`. The locks of a call of the helper are those of its
# CC_RELEASES in order, one each; when the call has fewer (one it cannot name), any of them is. When the unit of the
# definition did not see the marked prototype (`releases` is empty), they are the marks merged from all declarations,
# in the names of the prototype that wrote them.
def stop_keys(rules: Rules, helper: Body, site: Site, h: Held) -> Set[String]
  return Set.new(marked_releases(rules, helper.key)) if helper.releases.empty?

  return Set.new(helper.releases) if helper.releases.size != site.drops.size

  same_lock = (0...site.drops.size).to_a.select do |i| site.drops[i].key == h.lock.key end
  Set.new(same_lock.map do |i| helper.releases[i] end)
end

# The keys of the locks of a function's CC_RELEASES and CC_RELEASES_IF marks, merged from all its declarations, as
# written.
def marked_releases(rules: Rules, key: String) -> List[String]
  found = rules.graph.functions.get(key).map do |f| f.marks end
  marks = found.unwrap_or([])
  releases = marks.select do |mark| mark.start_with?("releases(") and mark.end_with?(")") end
  locks = releases.flat_map do |mark| mark.slice(9, mark.length - 10).split(",") end
  # `releases_if(lock, flag)` releases its first text.
  flagged = marks.select do |mark| mark.start_with?("releases_if(") and mark.end_with?(")") end
  locks = locks.concat(flagged.map do |mark| mark.slice(12, mark.length - 13).split(",").first end)
  locks.map do |lock| Flow.key_of(lock.strip) end
end

# The call path from the call to a system call: [the call] for a system or blocking call (a CC_BLOCKING function
# included), [the call, ..., the system call] for a function of the project that reaches one, [] for neither. A call
# through a pointer goes to the functions stored in it, and the path starts at the first of them that reaches one.
def system_call(rules: Rules, body: Body, site: Site) -> List[String]
  return Effects.system_path(rules.graph, site.key).unwrap_or([]) if not site.pointer

  for target in Effects.pointer_targets(rules.graph, body.key, site.line, site.column)
    case Effects.system_path(rules.graph, target)
      some(path) -> return path
      none -> next
    end
  end

  []
end

# A lock with a level taken while a lock of the same or a higher level is held: by the call itself, or by a function
# of the project that the call reaches.
def out_of_order(rules: Rules, body: Body, held: List[Held], site: Site, at: String) -> List[Breach]
  leveled = held.select do |h| rules.levels.key?(h.lock.class) end
  return [] if leveled.empty?

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

  return found if not site.takes.empty? or not site.drops.empty?

  # A function that takes the class of a lock held may take that very lock again, which a lock that counts its nested
  # takes allows: only another class is out of order.
  classes = reached_by(rules, body, site)
  if site.idle and rules.idle_classes.key?(site.key)
    classes = rules.idle_classes[site.key].to_a
  end

  for class in classes
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

  found
end

def higher_or_same?(rules: Rules, held: String, taken: String) -> Bool
  case rules.levels.get(taken)
    some(level) -> rules.levels[held] >= level
    none -> false
  end
end

# The locks a call waits for: a trylock waits for none, so it never takes part in a cycle of waits.
def waited(site: Site) -> List[Lock]
  return [] if site.tried

  site.takes
end

# The classes that a call takes through the functions it reaches: those of the callee, or of every function stored in
# the pointer it calls.
def reached_by(rules: Rules, body: Body, site: Site) -> List[String]
  return reached_takes(rules, site.key) if not site.pointer

  targets = Effects.pointer_targets(rules.graph, body.key, site.line, site.column)
  reached = targets.flat_map do |target| reached_takes(rules, target) end
  reached.uniq
end

# The classes that a function of the project takes, in its body or in the functions it reaches.
def reached_takes(rules: Rules, start: String) -> List[String]
  return [] if not Effects.defined?(rules.graph, start) or Effects.stopped?(rules.graph, start)

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

  classes.to_a
end

# The level of a mark `lock_level(N)`, or none for another mark.
def level_of(mark: String) -> Optional[Int]
  return none if not mark.start_with?(LEVEL_PREFIX) or not mark.end_with?(")")

  inside = mark.slice(LEVEL_PREFIX.length, mark.length - LEVEL_PREFIX.length - 1).strip
  case inside.to_i
    ok(level) -> some(level)
    error(_) -> none
  end
end

# The calls of a helper's body that the side of its flags where it does nothing to a lock (`Site.idle`) makes: all of
# them but those of its own lock that the other side makes: its takes when it takes by a flag, and its releases. A
# release of the lock by a function of the project is followed all the same (`own_call?`), and so are a wait on it and
# a take by a helper that does not take by a flag (a transient one). A branch that tests the flag of a CC_RELEASES_IF
# is not
# followed on its true side, where the flag is 0, unless the body writes the flag anywhere (it may be anything there).
def idle_calls(rules: Rules, helper: Body) -> List[Site]
  acquired = own_keys(rules, helper, true)
  own = acquired.union(own_keys(rules, helper, false))
  flags = Set.new(helper.flags)
  for node in helper.nodes
    case node.event
      Event.Writes(keys) -> flags = flags.difference(Set.new(keys))
      _ -> next
    end
  end

  found: List[Site] = []
  seen = Set.new([0])
  queue = [0]
  i = 0
  while i < queue.size
    node = helper.nodes[queue[i]]
    i += 1
    follow = true
    case node.event
      Event.Call(call) ->
        if not own_call?(rules, call, acquired, own)
          found = found.push(call)
        end

      Event.Branch(fact) -> follow = not (fact.value and flags.include?(fact.text))
      _ -> follow = true
    end

    if follow
      for after in node.next
        if not seen.include?(after)
          seen = seen.add(after)
          queue = queue.push(after)
        end
      end
    end
  end

  found
end

# Whether a call of a flagged helper's body is one of the other side of its flags: a call of a flagged helper that
# takes or releases its lock (the side of it that does nothing is an `idle` call of its own, and its body is not read
# here: what its own flag guards would be reported), a take of a lock that the helper takes by a flag, or a release of
# its lock by a function of the library. A wait on the lock is not, since it runs on both sides, and neither is a
# release by a function of the project, since what it runs before the release is run on both sides.
def own_call?(rules: Rules, call: Site, acquired: Set[String], own: Set[String]) -> Bool
  taken = call.takes.any? do |lock| own.include?(lock.key) end
  dropped = call.drops.any? do |lock| own.include?(lock.key) end
  return taken or dropped if flagged?(rules, call.key)

  return true if call.takes.any? do |lock| acquired.include?(lock.key) end

  dropped and not rules.bodies.key?(call.key)
end

# Whether a function has a CC_ACQUIRES_IF or a CC_RELEASES_IF.
def flagged?(rules: Rules, key: String) -> Bool
  marks_of(rules, key).any? do |mark| mark.start_with?("acquires_if(") or mark.start_with?("releases_if(") end
end

# The keys of the locks that a helper's marks take (`takes`) or release, in the names of its parameters
# (`Body.acquires` and `releases`) or, when the unit of the definition did not see the marked prototype, as the marks
# write them.
def own_keys(rules: Rules, helper: Body, takes: Bool) -> Set[String]
  words = ["releases", "releases_if"]
  keys = helper.releases
  if takes
    words = ["acquires", "acquires_if"]
    keys = helper.acquires
  end

  keys = keys.select do |key| key != "" end
  return Set.new(keys) if not keys.empty?

  texts: List[String] = []
  for mark in marks_of(rules, helper.key)
    for word in words
      if mark.start_with?("#{word}(") and mark.end_with?(")")
        locks = mark.slice(word.length + 1, mark.length - word.length - 2).split(",")
        # The second text of a mark by a flag is the flag.
        if word.end_with?("_if")
          locks = locks.take(1)
        end

        texts = texts.concat(locks)
      end
    end
  end

  Set.new(texts.map do |lock| Flow.key_of(lock.strip) end)
end

# The marks of a function, merged from all its declarations.
def marks_of(rules: Rules, key: String) -> List[String]
  found = rules.graph.functions.get(key).map do |f| f.marks end
  found.unwrap_or([])
end

# Reads the body of each flagged helper once for all the calls of it (`idle_calls`), and settles for each what a
# call on
# its idle side reaches: the system calls it makes (`idle_reach`) and the classes it takes (`idle_classes`, which only
# the lock order reads). Each helper's own calls are read once, and the helpers that call each other are a fixed point
# over what they reach, so a helper that calls an idle helper twice is not read once for each path down to it.
def with_idle(rules: Rules) -> Rules
  idle: Map[String, List[Site]] = {}
  for key in rules.bodies.keys
    if flagged?(rules, key)
      idle = idle.put(key, idle_calls(rules, rules.bodies[key]))
    end
  end

  read = rules.with(idle: idle)
  classes: Map[String, Set[String]] = {}
  if not read.levels.empty?
    classes = settled_classes(read)
  end

  read.with(idle_reach: settled_reach(read), idle_classes: classes)
end

# Whether a call of an idle helper's body is of a helper that is idle in its turn, and has a body.
def nested?(rules: Rules, call: Site) -> Bool = call.idle and rules.idle.key?(call.key)

# The helpers in the order of one pass of a fixed point: forwards and backwards, so that a chain of helpers settles in
# a pass or two whether its callers are defined before their callees or after.
def passes(rules: Rules) -> List[String]
  keys = rules.idle.keys
  keys.concat(keys.reverse)
end

def settled_reach(rules: Rules) -> Map[String, List[Reach]]
  reach: Map[String, List[Reach]] = {}
  for key in rules.idle.keys
    reach = reach.put(key, direct_reach(rules, key))
  end

  changed = true
  while changed
    changed = false
    for key in passes(rules)
      grown = reach[key]
      for call in rules.idle[key]
        if nested?(rules, call)
          grown = merged(grown, call.name, reach[call.key])
        end
      end

      if grown.size > reach[key].size
        reach = reach.put(key, grown)
        changed = true
      end
    end
  end

  reach
end

# What the calls of the helper `key` that are no idle helper reach: a call that is, or reaches, a system call; a wait
# of the library, with the lock it waits on; a release of its lock by a function of the project, all that function
# runs before the release. A release of another lock by the library is no system call. A call of a flagged helper on
# the side where it takes or releases its lock is not followed: its body, read through `before_release`, would
# report what its own flag guards, and its other side is a call of its own.
def direct_reach(rules: Rules, key: String) -> List[Reach]
  helper = rules.bodies[key]
  found: List[Reach] = []
  for call in rules.idle[key]
    path: List[String] = []
    waited = ""
    if nested?(rules, call)
      path = []
    elsif call.idle or (call.drops.empty? and call.waits.empty?)
      path = system_call(rules, helper, call)
    elsif rules.bodies.key?(call.key)
      path = before_release(rules, helper, call, none)
    elsif not call.waits.empty?
      path = system_call(rules, helper, call)
      waited = lock_name(call.waits.first)
    end

    if not path.empty?
      found = merged(found, "", [Reach(path: path, waited: waited)])
    end
  end

  found
end

# The reaches of `found` and those of `below`, a call of `name` down: one for each lock that a wait is on, and one for
# the rest. `name` "" keeps the path.
def merged(found: List[Reach], name: String, below: List[Reach]) -> List[Reach]
  grown = found
  for r in below
    if not grown.any? do |known| known.waited == r.waited end
      path = r.path
      if name != ""
        path = [name].concat(path)
      end

      grown = grown.push(Reach(path: path, waited: r.waited))
    end
  end

  grown
end

# The name of a lock that a wait is on, as `Reach.waited` has it: its class, or its key when it has none.
def lock_name(lock: Lock) -> String
  return lock.class if lock.class != ""

  lock.key
end

def settled_classes(rules: Rules) -> Map[String, Set[String]]
  classes: Map[String, Set[String]] = {}
  for key in rules.idle.keys
    classes = classes.put(key, direct_classes(rules, key))
  end

  changed = true
  while changed
    changed = false
    for key in passes(rules)
      grown = classes[key]
      for call in rules.idle[key]
        if nested?(rules, call)
          grown = grown.union(classes[call.key])
        end
      end

      if grown.size > classes[key].size
        classes = classes.put(key, grown)
        changed = true
      end
    end
  end

  classes
end

# The classes that the calls of the helper `key` that are no idle helper take: those of the locks they take other than
# its own, and of the functions they reach.
def direct_classes(rules: Rules, key: String) -> Set[String]
  helper = rules.bodies[key]
  found: Set[String] = Set.new([])
  for call in rules.idle[key]
    if not nested?(rules, call)
      for lock in waited(call)
        if lock.class != ""
          found = found.add(lock.class)
        end
      end

      found = found.union(Set.new(reached_by(rules, helper, call)))
    end
  end

  found
end

# The call path to a system call of a call on the idle side of a flagged helper, from the call itself, while `h` is
# held: none for a helper that makes none, and a wait on `h` is not one, since it gives the lock back while it waits.
def idle_path(rules: Rules, body: Body, site: Site, h: Held) -> List[String]
  return system_call(rules, body, site) if not rules.idle.key?(site.key)

  for r in rules.idle_reach.get(site.key).unwrap_or([])
    on_h = r.waited != "" and (r.waited == h.lock.key or r.waited == h.lock.class)
    return [site.name].concat(r.path) if not on_h
  end

  []
end
