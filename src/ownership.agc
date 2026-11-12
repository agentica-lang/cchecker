## The ownership rules on the paths of each function: a pointer that owns is freed or handed on on every path that
## returns or jumps out (at a call marked CC_MAY_JUMP or CC_JUMPS), it is not freed twice, and it is not used after it
## was freed or handed on.
##
## A pointer owns when it is a parameter marked CC_OWNS or CC_FREES (from the entry), a local marked CC_OWNS that got a
## value that is not null, or a local that got the value of a call that returns owned memory (a function marked
## CC_OWNS). `free` and a parameter marked CC_FREES free it; a parameter marked CC_OWNS, a return, and a store in a
## CC_OWNS field or global hand it on. A local that is not marked and gets a pointer that owns is an alias of it: it
## stands for that pointer, as does a followed CC_OWNS field of a local struct that gets a local (`p.left = b`); an
## alias of a pointer already freed or handed on is a use after free. A condition that tells that a pointer is null
## (`if (!p)`) leaves it owning nothing on that side, and a pointer lent to a call (`fill(&p)`) owns what the call left
## in it, which the rules do not know. A CC_OWNS_OUT parameter hands an owned pointer out to the caller (`*out = p`),
## and the pointer whose address a call passes there owns what the call left in it once the path reads it. A store into
## an item of a pointer that owns an array (`argv[i] = p`) hands the pointer on to the array.
##
## The walk follows the graph of `Flow` in breadth, as the lock rules do, with the state of each pointer on the path
## and the conditions that the function tests twice.

import Effects from "effects"
import {Finding, IncompleteFunction} from "findings"
import {Assign, Body, Closing, Event, Fact, Give, Mark, Site, Use, plain} from "flow"
import Locking from "locking"
import {Function, Unit} from "unit"

## The code of a path that returns, or gives a pointer a new value, while the pointer still owns.
export LEAK = "CC-OWN-LEAK"

## The code of a path that frees a pointer that it already freed or handed on.
export DOUBLE_FREE = "CC-OWN-DOUBLE-FREE"

## The code of a path that uses a pointer after it freed it or handed it on.
export USE_AFTER_FREE = "CC-OWN-USE-AFTER-FREE"

# The states of a pointer on a path; one that owns nothing is not in the state at all. A pointer is `unknown` after it
# was lent to a call, which may have set it: it may be freed and handed on, and a path may end with it. A pointer is
# `cleared` after a call freed it through its address (`free_and_null(&p)`): it is freed or null, so it may be read and
# freed again, and a condition that says it is not null makes it freed. A pointer is `filled` after a call handed an
# owned pointer out to it through a CC_OWNS_OUT parameter (`take(&p)`). Unlike `unknown`, the rules know it may own:
# it is freed and handed on as one that owns, and reading it (lending it, testing it) makes it `owned`. Until then no
# exit leaks it, nor a new value: a call that failed may have left nothing there. A CC_OWNS field of a local struct is
# `escaped` after the struct escaped (`&p`, a copy, a by-value argument, a return): what it holds belongs to whoever
# got the struct, so it is never a leak, and it stays so on the path: a free of it is no finding, and a pointer stored
# in it is handed on, as a store into the field of a struct that is not followed. A clear of the whole struct
# (`memset(&p, 0, sizeof p)`, `p = (struct pair){0}`) makes the field the function's again.
OWNED = "owned"
FREED = "freed"
MOVED = "moved"
UNKNOWN = "unknown"
CLEARED = "cleared"
FILLED = "filled"
ESCAPED = "escaped"

# The states the walk of one function may visit, with the conditions and then without them.
MAX_STATES = 200_000

# The state of a path: what each pointer owns, the aliases (a local that stands for a pointer that owns), the result
# of a realloc and the pointer it moved (which owns again when the result is null), the known conditions, and the
# pointers whose block closed while a pointer still in the state stood for them (`kept`, see `closed`).
struct State
  owns: Map[String, String]
  aliases: Map[String, String]
  links: Map[String, String]
  facts: Map[String, Bool]
  kept: Set[String]
end

# One step of a path, as the finding shows it, the pointer it is about, and whether it gave the pointer its value
# (`origin`) or ended its ownership (`ended`).
struct Step
  text: String
  name: String = ""
  origin: Bool = false
  ended: Bool = false
end

struct Item
  node: Int
  state: State
  path: List[Step]
end

# What a node does to a path: it goes on, it ends (a return), or it stops (a call that does not come back, or a
# condition that the path already knows is the other way). A move may find rule breaks on the way.
enum Moved
  Went(Item)
  Ended(List[Step])
  Stopped
end

# A rule that a path breaks: the code, the pointer (the id of the finding, with the code), the message and the path.
struct Breach
  code: String
  name: String
  message: String
  path: List[Step]
  source: String = ""
end

# The state after a node, and the rules broken there.
struct Outcome
  moved: Moved
  breaches: List[Breach]
end

struct Walker
  body: Body
  functions: Map[String, Function]
  tracked: Set[String]
  roots: Map[String, List[String]]
  # The tracked conditions that each node can still read (`Locking.live_facts`); the state keeps no other.
  live: Map[Int, Set[String]]
end

struct Walk
  findings: Map[String, Finding]
  complete: Bool
end

## What the rules found, and the number of functions with more paths than the walk follows, checked on those it went
## through only.
export struct Checked
  findings: List[Finding]
  incomplete: List[IncompleteFunction]
end

## Returns the findings of the ownership rules on the functions of the units. A function defined in several units (a
## static inline function of a header) is checked once.
export def check(units: List[Unit]) -> Checked
  functions: Map[String, Function] = {}
  for function in Effects.functions(units)
    functions = functions.put(function.key, function)
  end

  done: Set[String] = Set.new([])
  findings: List[Finding] = []
  incomplete: List[IncompleteFunction] = []
  for unit in units
    for body in unit.bodies
      if body.owns and not done.include?(body.key)
        walk = checked(body, functions)
        findings = findings.concat(walk.findings.values)
        if not walk.complete
          incomplete = incomplete.push(IncompleteFunction(file: body.file, line: body.line, function: body.name))
        end
      end

      done = done.add(body.key)
    end
  end

  Checked(findings: findings, incomplete: incomplete)
end

# The findings of one function: with the conditions it tests twice, or without them when there are too many paths.
def checked(body: Body, functions: Map[String, Function]) -> Walk
  tracked = Locking.tracked_of(body)
  roots = Locking.roots_of(body)
  walker = Walker(
    body: body,
    functions: functions,
    tracked: tracked,
    roots: roots,
    live: Locking.live_facts(body, tracked, roots),
  )

  walk = walked(walker)
  if not walk.complete
    walk = walked(walker.with(tracked: Set.new([]), live: {}))
  end

  walk
end

def walked(walker: Walker) -> Walk
  body = walker.body
  owns: Map[String, String] = {}
  for name in body.owned
    owns = owns.put(name, OWNED)
  end

  queue = [Item(node: 0, state: State(owns: owns, aliases: {}, links: {}, facts: {}, kept: Set.new([])), path: [])]
  visited: Set[String] = Set.new([])
  unread: Set[String] = Set.new([])
  found: Map[String, Finding] = {}
  i = 0
  while i < queue.size
    return Walk(findings: found, complete: false) if i >= MAX_STATES

    item = queue[i]
    i += 1
    node = body.nodes[item.node]
    outcome = stepped(walker, node.event, item)
    for breach in outcome.breaches
      found = with_breach(found, body, breach)
    end

    case outcome.moved
      Moved.Ended(path) ->
        for breach in leaks(body, item.state, path)
          found = with_breach(found, body, breach)
        end

      Moved.Stopped -> next
      Moved.Went(went_on) ->
        # A `goto` into a block reaches its pointers again past their declarations: none of them is dropped.
        moved = went_on
        if not body.enters
          moved = went_on.with(state: released(went_on.state))
        end

        for after in node.next
          next_state = moved.state.with(facts: Locking.kept(moved.state.facts, walker.live.get(after, unread)))
          seen = "#{after}|#{encoded(next_state)}"
          if not visited.include?(seen)
            visited = visited.add(seen)
            queue = queue.push(moved.with(node: after, state: next_state))
          end
        end
    end
  end

  Walk(findings: found, complete: true)
end

# One finding for each code and pointer: the first path, which is a shortest one.
def with_breach(found: Map[String, Finding], body: Body, breach: Breach) -> Map[String, Finding]
  id = "#{breach.code} #{breach.name}"
  return found if found.key?(id)

  texts = breach.path.map do |step| step.text end
  found.put(id, Locking.located(body, breach.code, breach.message, texts).with(source: breach.source))
end

def stepped(walker: Walker, event: Event, item: Item) -> Outcome
  case event
    Event.Join -> went(item)
    Event.Call(site) ->
      stops = Locking.stops?(site, walker.functions)
      jumps = Locking.jumps?(site, walker.functions)
      return Outcome(moved: Moved.Stopped, breaches: []) if stops and not jumps

      outcome = after_call(walker.body, item, site)
      return outcome if not jumps

      # A call that never comes back but jumps (CC_JUMPS) is a way out of the function, and the path ends there.
      out = jumped(walker, outcome, site, stops)
      return out.with(moved: Moved.Stopped) if stops

      out
    Event.Branch(fact) -> after_branch(walker, item, fact)
    Event.Writes(names) ->
      facts = Locking.forgotten(item.state.facts, walker.roots, names)
      went(item.with(state: item.state.with(facts: facts)))
    Event.Uses(use) -> after_use(walker.body, item, use)
    Event.Assigns(assign) -> after_assign(walker.body, item, assign)
    Event.Gives(give) -> after_give(walker.body, item, give)
    Event.Lends(names) ->
      state = item.state
      for name in names
        state = state.with(owns: state.owns.put(name, UNKNOWN), aliases: state.aliases.delete(name))
      end

      went(item.with(state: state))
    Event.Escapes(names) ->
      # A field that stands for a local (`p.left = b`) lends the local with the struct: whoever got the struct may
      # have freed or kept it, as after `lend(&b)`.
      state = item.state
      for name in names
        case state.aliases.get(name)
          some(root) if not names.include?(root) and state.owns.key?(root) ->
            state = state.with(owns: state.owns.put(root, UNKNOWN))
          _ -> state = state
        end

        state = state.with(owns: state.owns.put(name, ESCAPED), aliases: state.aliases.delete(name))
      end

      went(item.with(state: state))
    Event.Resets(names) ->
      # A clear of the whole struct: the fields are its own again, null until the clear's own values come.
      state = item.state
      for name in names
        if state.owns.get(name).map do |own| own == ESCAPED end.unwrap_or(false)
          state = state.with(owns: state.owns.delete(name))
        end
      end

      went(item.with(state: state))
    Event.Closes(closing) -> closed(walker.body, item, closing)
    Event.Note(mark) -> went(item.with(path: item.path.push(marked(mark))))
    Event.Exit(mark) -> Outcome(moved: Moved.Ended(item.path.push(marked(mark))), breaches: [])
  end
end

# A path leaves the blocks of the pointers of `closing`: nothing names them after. One that a pointer still in the
# state stands for (an alias, or the result of a realloc of it, from outside the blocks or itself kept) stays; every
# other one leaves the state, so two paths that differ only in them are one, and one that still owns leaks there.
def closed(body: Body, item: Item, closing: Closing) -> Outcome
  state = item.state
  names = Set.new(closing.names)
  held: Set[String] = Set.new([])
  grew = true
  while grew
    grew = false
    for pointers in [state.aliases, state.links]
      for from in pointers.keys
        to = pointers[from]
        if names.include?(to) and not held.include?(to) and (not names.include?(from) or held.include?(from))
          held = held.add(to)
          grew = true
        end
      end
    end
  end

  step = marked(closing.mark)
  breaches: List[Breach] = []
  for name in closing.names
    if held.include?(name)
      if not state.kept.include?(name)
        state = state.with(kept: state.kept.add(name))
      end

      next
    end

    if state.owns.get(name).map do |own| own == OWNED end.unwrap_or(false)
      message = "#{body.name} does not free or hand on #{plain(name)} on every path"
      breaches = breaches.push(
        Breach(code: LEAK, name: name, message: message, path: from_last(item.path, name, true).push(step)),
      )
    end

    state = state.with(
      owns: state.owns.delete(name),
      aliases: state.aliases.delete(name),
      links: state.links.delete(name),
    )
  end

  Outcome(moved: Moved.Went(item.with(state: state)), breaches: breaches)
end

# The state without the kept pointers that nothing stands for any more (the alias got a new value, was lent, or
# closed too) and that own nothing: nothing names them after, so two paths that differ only in them are one (a macro
# that returns an owned pointer, used many times into one variable, leaves no dead pointer per use). One that may still
# own stays, to leak where the path ends.
def released(state: State) -> State
  return state if state.kept.empty?

  named = Set.new(state.aliases.values.concat(state.links.values))
  for name in state.kept.to_a.sort
    owns = state.owns.get(name).map do |own| own == OWNED or own == FILLED end.unwrap_or(false)
    if not named.include?(name) and not owns
      state = state.with(
        owns: state.owns.delete(name),
        aliases: state.aliases.delete(name),
        links: state.links.delete(name),
        kept: state.kept.delete(name),
      )
    end
  end

  state
end

def went(item: Item) -> Outcome = Outcome(moved: Moved.Went(item), breaches: [])

def marked(mark: Mark) -> Step = Step(text: "#{mark.line}:#{mark.column} #{mark.word}")

# A call frees the pointers it frees, takes those it takes, fills those it hands an owned pointer out to (a value that
# one still owned is lost), and may return an owned value that nothing keeps.
def after_call(body: Body, item: Item, site: Site) -> Outcome
  at = "#{site.line}:#{site.column}"
  current = item
  breaches: List[Breach] = []
  for name in site.frees
    root = owner(current.state, name)
    step = Step(text: "#{at} frees #{plain(root)}", name: root, ended: true)
    case current.state.owns.get(root)
      some(state) if state == FREED or state == MOVED ->
        message = "#{body.name} frees #{plain(root)}, which it already freed or handed on"
        breaches = breaches.push(
          Breach(code: DOUBLE_FREE, name: root, message: message, path: ended_path(current, root, step)),
        )
      some(state) if state == CLEARED or state == ESCAPED -> next
      some(_) if site.clears.include?(name) and root == name ->
        current = aliases_freed(ended(current, root, CLEARED, step), root, step)
      some(_) if site.clears.include?(name) ->
        # The call set only the alias to null (`zap(&p.left)`, `pair_free(&p)`): the pointer it stood for is freed.
        freed = ended(current, root, FREED, step)
        state = freed.state.with(owns: freed.state.owns.put(name, CLEARED), aliases: freed.state.aliases.delete(name))
        current = freed.with(state: state)
      some(_) -> current = ended(current, root, FREED, step)
      none -> next
    end
  end

  for name in site.hands
    root = owner(current.state, name)
    step = Step(text: "#{at} hands #{plain(root)} to #{site.name}", name: root, ended: true)
    case current.state.owns.get(root)
      some(state) if state == FREED or state == MOVED ->
        breaches = breaches.push(used_after(body, current, root, step))
      some(state) if state == CLEARED or state == ESCAPED -> next
      some(_) -> current = ended(current, root, MOVED, step)
      none -> next
    end
  end

  for name in site.fills
    step = Step(text: "#{at} #{site.name} sets #{plain(name)}", name: name, origin: true)
    state = current.state
    if kept_by_alias?(state, name)
      state = handed_over(state, name)
    elsif state.owns.get(name).map do |own| own == OWNED end.unwrap_or(false)
      breaches = breaches.push(overwritten(body, current, name, step))
    end

    # A kept pointer that a call fills is declared again (the next round of a loop): it is live again.
    if state.kept.include?(name)
      state = state.with(kept: state.kept.delete(name))
    end

    current = current.with(
      state: state.with(
        owns: state.owns.put(name, FILLED),
        aliases: state.aliases.delete(name),
        links: state.links.delete(name),
      ),
      path: current.path.push(step),
    )
  end

  if site.lost
    message = "#{body.name} does not free or hand on the value of #{site.name}"
    step = Step(text: "#{at} calls #{site.name}")
    breaches = breaches.push(Breach(code: LEAK, name: "#{site.name}()", message: message, path: [step]))
  end

  Outcome(moved: Moved.Went(current), breaches: breaches)
end

# A call that may jump out is a way out of the function too: each pointer that still owns after the call took its
# arguments leaks on the jump. What the call frees or takes is its own from the call on, jump or not.
def jumped(walker: Walker, outcome: Outcome, site: Site, stops: Bool) -> Outcome
  case outcome.moved
    Moved.Went(after) ->
      path = after.path.push(Step(text: Locking.jump_text(site, stops, walker.functions)))
      source = Locking.jump_source(site, walker.functions)
      found = leaks(walker.body, after.state, path).map do |breach| breach.with(source: source) end
      outcome.with(breaches: outcome.breaches.concat(found))
    _ -> outcome
  end
end

# A condition: the known conditions as the lock rules keep them, and the pointers that are null on this side.
def after_branch(walker: Walker, item: Item, fact: Fact) -> Outcome
  path = item.path
  if not fact.quiet
    path = path.push(Step(text: "#{fact.line}:#{fact.column} #{Locking.truth(fact)}"))
  end

  state = item.state
  if walker.tracked.include?(fact.text)
    if state.facts.get(fact.text).map do |known| known != fact.value end.unwrap_or(false)
      return Outcome(moved: Moved.Stopped, breaches: [])
    end

    state = state.with(facts: state.facts.put(fact.text, fact.value))
  elsif fact.if_tested
    return Outcome(moved: Moved.Stopped, breaches: [])
  end

  for name in fact.nulls
    state = nulled(state, owner(state, name))
  end

  for name in fact.set
    root = owner(state, name)
    if state.owns.get(root).map do |own| own == CLEARED end.unwrap_or(false)
      state = state.with(owns: state.owns.put(root, FREED))
    end
  end

  went(item.with(state: state, path: path))
end

# A pointer that is null owns nothing; when it is the result of a realloc, the pointer it moved owns again. A field
# of a struct that escaped stays so: a value stored in it after the test is handed on too.
def nulled(state: State, name: String) -> State
  return state if state.owns.get(name).map do |own| own == ESCAPED end.unwrap_or(false)

  cleared = state.with(owns: state.owns.delete(name))
  case state.links.get(name)
    some(source) ->
      restored = cleared.with(links: cleared.links.delete(name))
      if restored.owns.get(source).map do |own| own == MOVED end.unwrap_or(false)
        return restored.with(owns: restored.owns.put(source, OWNED))
      end

      restored
    none -> cleared
  end
end

def after_use(body: Body, item: Item, use: Use) -> Outcome
  root = owner(item.state, use.name)
  case item.state.owns.get(root)
    some(state) if state == FREED or state == MOVED ->
      step = Step(text: "#{use.line}:#{use.column} uses #{plain(root)}", name: root)
      Outcome(moved: Moved.Went(item), breaches: [used_after(body, item, root, step)])
    some(state) if state == FILLED -> went(item.with(state: item.state.with(owns: item.state.owns.put(root, OWNED))))
    _ -> went(item)
  end
end

def after_give(body: Body, item: Item, give: Give) -> Outcome
  root = owner(item.state, give.name)
  word = give.word
  if word == "returns"
    word = "returns #{plain(root)}"
  end

  step = Step(text: "#{give.line}:#{give.column} #{word}", name: root, ended: true)
  case item.state.owns.get(root)
    some(state) if state == FREED or state == MOVED ->
      Outcome(moved: Moved.Went(item), breaches: [used_after(body, item, root, step)])
    some(state) if state == CLEARED or state == ESCAPED -> went(item)
    some(_) -> went(ended(item, root, MOVED, step))
    none -> went(item)
  end
end

# A new value of a pointer: one that still owns loses what it owned. (A realloc of it moved it first.)
def after_assign(body: Body, item: Item, assign: Assign) -> Outcome
  # A pointer that gets the value it already holds (`p.right = p.right`, or `b = c` where `c` stands for `b`) loses
  # nothing and stays as it was.
  copies = assign.value == "moved" or assign.value == "alias"
  return went(item) if copies and owner(item.state, assign.from) == owner(item.state, assign.name)

  at = "#{assign.line}:#{assign.column}"
  step = Step(text: "#{at} #{plain(assign.name)} = #{assign.shown}", name: assign.name, origin: true)
  breaches: List[Breach] = []
  state = item.state
  owned = state.owns.get(assign.name).map do |own| own == OWNED end.unwrap_or(false)
  # A realloc moves the old value itself (`resized`).
  if assign.value != "resized" and kept_by_alias?(state, assign.name)
    state = handed_over(state, assign.name)
    owned = false
  end

  if owned
    breaches = breaches.push(overwritten(body, item, assign.name, step))
  end

  state = state.with(aliases: state.aliases.delete(assign.name), links: state.links.delete(assign.name))
  # A new value of a kept pointer is a new declaration of its name (the next round of a loop): it is live again.
  if state.kept.include?(assign.name)
    state = state.with(kept: state.kept.delete(assign.name))
  end

  was_escaped = state.owns.get(assign.name).map do |own| own == ESCAPED end.unwrap_or(false)
  state = state.with(owns: state.owns.delete(assign.name))
  case assign.value
    "owned" -> state = state.with(owns: state.owns.put(assign.name, OWNED))
    "resized" -> state = resized(state, assign)
    "moved" ->
      source = owner(state, assign.from)
      case state.owns.get(source)
        some(from) if from == FREED or from == MOVED -> breaches = breaches.push(used_after(body, item, source, step))
        some(from) -> state = state.with(owns: state.owns.put(source, MOVED).put(assign.name, from))
        none -> state = state
      end

    "alias" ->
      source = owner(state, assign.from)
      case state.owns.get(source)
        some(from) if from == FREED or from == MOVED -> breaches = breaches.push(used_after(body, item, source, step))
        _ ->
          if source != assign.name
            state = state.with(aliases: state.aliases.put(assign.name, source))
          end
      end

    _ -> state = state
  end

  # A field of a struct that escaped hands on what it gets: the struct is someone else's now.
  if was_escaped
    state = state.with(owns: state.owns.put(assign.name, ESCAPED), aliases: state.aliases.delete(assign.name))
  end

  Outcome(moved: Moved.Went(item.with(state: state, path: item.path.push(step))), breaches: breaches)
end

# Whether a local stands for the pointer `name`.
def kept_by_alias?(state: State, name: String) -> Bool = state.aliases.values.include?(name)

# `old = *p; *p = v;` in a CC_FREES parameter, `old = p; p = q;` or `old = p; take(&p);`: the locals that stood for the
# pointer keep its old value, in the state it had; the first one holds it and the others stand for it.
def handed_over(state: State, name: String) -> State
  keepers = keepers_of(state, name)
  holder = keepers.first
  aliases = state.aliases.delete(holder)
  for other in keepers.drop(1)
    aliases = aliases.put(other, holder)
  end

  case state.owns.get(name)
    some(own) -> state.with(aliases: aliases, owns: state.owns.put(holder, own))
    none -> state.with(aliases: aliases)
  end
end

# `c = b; zap(&b)`: the call freed `name` and set it alone to null, so the locals that stood for it still hold the
# pointer it freed (after `handed_over`, the first holds it and the others stand for that one).
def aliases_freed(item: Item, name: String, step: Step) -> Item
  return item if not kept_by_alias?(item.state, name)

  holder = keepers_of(item.state, name).first
  ended(item.with(state: handed_over(item.state, name)), holder, FREED, step.with(name: holder))
end

# The locals that stand for the pointer `name`, in the order of their names.
def keepers_of(state: State, name: String) -> List[String]
  state.aliases.keys.sort.select do |alias| state.aliases[alias] == name end
end

# The result of a realloc owns; the pointer it moved owns again where the result is null.
def resized(state: State, assign: Assign) -> State
  owned = state.with(owns: state.owns.put(assign.name, OWNED))
  owned.with(links: owned.links.put(assign.name, owner(state, assign.from)))
end

# A pointer that owns gets a new value at `step` (an assignment, or a call that fills it): what it owned leaks.
def overwritten(body: Body, item: Item, name: String, step: Step) -> Breach
  message = "#{body.name} does not free or hand on #{plain(name)} on every path"
  Breach(code: LEAK, name: name, message: message, path: from_last(item.path, name, true).push(step))
end

# Each pointer that still owns at the end of a path is a leak.
def leaks(body: Body, state: State, path: List[Step]) -> List[Breach]
  found: List[Breach] = []
  for name in state.owns.keys.sort
    if state.owns[name] == OWNED
      message = "#{body.name} does not free or hand on #{plain(name)} on every path"
      found = found.push(Breach(code: LEAK, name: name, message: message, path: from_last(path, name, true)))
    end
  end

  found
end

def used_after(body: Body, item: Item, name: String, step: Step) -> Breach
  message = "#{body.name} uses #{plain(name)} after it freed it or handed it on"
  Breach(code: USE_AFTER_FREE, name: name, message: message, path: ended_path(item, name, step))
end

# The path from the step that freed or handed on the pointer to `step`.
def ended_path(item: Item, name: String, step: Step) -> List[Step] = from_last(item.path, name, false).push(step)

# The item after a call or a store ended the ownership of a pointer, and the step on its path.
def ended(item: Item, name: String, state: String, step: Step) -> Item
  owns = item.state.owns.put(name, state)
  item.with(state: item.state.with(owns: owns, links: item.state.links.delete(name)), path: item.path.push(step))
end

# The pointer that a local stands for: itself, or the pointer it is an alias of.
def owner(state: State, name: String) -> String = state.aliases.get(name).unwrap_or(name)

# The steps of a path from the last one that gave the pointer its value (`origin`) or ended its ownership; the whole
# path when there is none (a parameter owns from the entry).
def from_last(path: List[Step], name: String, origin: Bool) -> List[Step]
  start = 0
  for i in 0...path.size
    step = path[i]
    if step.name == name and ((origin and step.origin) or (not origin and step.ended))
      start = i
    end
  end

  path.drop(start)
end

# The state as a text, the same for two states with the same pointers and conditions whatever their order.
def encoded(state: State) -> String
  owns = state.owns.keys.sort.map do |name| "#{name}=#{state.owns[name]}" end
  aliases = state.aliases.keys.sort.map do |name| "#{name}>#{state.aliases[name]}" end
  links = state.links.keys.sort.map do |name| "#{name}<#{state.links[name]}" end
  facts = state.facts.keys.sort.map do |text| "#{text}=#{state.facts[text]}" end
  kept = state.kept.to_a.sort
  "#{owns.join(";")}|#{aliases.join(";")}|#{links.join(";")}|#{facts.join(";")}|#{kept.join(";")}"
end
