## The control flow graph of a function body, as the path rules need it: the calls, with the locks they take and
## release, the conditions, the writes that change what a condition read, and the ends of the paths.
##
## A node holds one event and the nodes that can come after it. Node 0 is the entry. A path ends at an `Exit` (a
## `return`, or the end of the body) or at a call that never comes back. A call is a node once its arguments are; the
## variables with `__attribute__((cleanup(f)))` call `f` on every way out of their block.

import Ast from "ast"
import Known from "known"

## The start of the key of the lock that stands for a CC_PAIR(set, restore): `pair:set:restore`, which the calls of
## `set` take and the calls of `restore` release: no lock expression of the code looks like it.
export PAIR_PREFIX = "pair:"

# The nodes that do not change the value of the expression inside them.
SEE_THROUGH = Set.new(["ImplicitCastExpr", "CStyleCastExpr", "ParenExpr", "ConstantExpr", "ExprWithCleanups"])

ASSIGNMENTS = Set.new(["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="])

# The operators a condition or a lock may be written with. Anything else (a call, an assignment) has no text: its
# value can change between two reads.
UNARY_TEXT = Set.new(["&", "*", "!", "-", "~"])
BINARY_TEXT = Set.new(["==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"])

# How clang writes the type of a function that does not return.
NORETURN_TYPE = "__attribute__((noreturn))"

# How deep a local variable is followed to the value it was set to (`m = &q->mu`, `n = m`).
ALIAS_DEPTH = 4

## A lock: `key` is what tells two locks apart (`q.mu` for `&q->mu`, `q->mu` and `(&q->mu)`), `shown` how the code
## wrote it, and `class` the field it is (`queue.mu`, by struct and field name) or the global, which the marks of
## CC_NO_SYSCALL_UNDER() and CC_LOCK_LEVEL name; "" when the rules cannot tell. `pair` is the restore of the lock of
## a CC_PAIR, "" for a lock of the code.
export struct Lock
  key: String
  shown: String
  class: String = ""
  pair: String = ""
end

## A call of a function, by name and key (`name@file` for a static one), and what it does to the locks: those it takes,
## releases, and waits on (a condition wait gives its lock back while it waits). A call through a function pointer
## (`pointer`) has the text of the pointer as its name and no key. `tried` is a trylock, which never waits for its lock.
export struct Site
  name: String
  key: String
  line: Int
  column: Int
  takes: List[Lock]
  drops: List[Lock]
  stops: Bool
  waits: List[Lock] = []
  pointer: Bool = false
  tried: Bool = false
end

## The value a condition has on an edge. `text` is "" for a condition that may change between two reads (a call).
## `roots` are the variables it reads, so a write to one forgets it.
export struct Fact
  text: String
  value: Bool
  roots: List[String]
  line: Int
  column: Int
end

## A point of a path worth naming in a finding: `returns`, `ends`, `case`, `default`, `no case`.
export struct Mark
  word: String
  line: Int
  column: Int
end

## What happens at a node.
export enum Event
  Join
  Call(Site)
  Branch(Fact)
  Writes(List[String])
  Note(Mark)
  Exit(Mark)
end

export struct Node
  event: Event
  next: List[Int]
end

## The graph of one function, at the place of its definition.
export struct Body
  key: String
  name: String
  file: String
  line: Int
  column: Int
  nodes: List[Node]
end

## A lock of a CC_ACQUIRES (`takes`) or a CC_RELEASES, as written, with the names of the parameters of the
## declaration that carries it; or the lock of a CC_PAIR that a set takes and its restore (`pair`) releases.
export struct Annotated
  text: String
  params: List[String]
  takes: Bool
  class: String = ""
  pair: String = ""
end

## What a function of the translation unit says about locks, from all its declarations, and whether it never returns.
export struct Callee
  locks: List[Annotated]
  stops: Bool
end

## What the graphs of one translation unit need: the functions that say something about locks, by key, the keys of
## its static functions by name, the class of each field by id (`queue.mu`), and the class of each global variable by
## the id of its declaration (its name, `name@file` for a static one), so a local of the same name is not it.
export struct Context
  callees: Map[String, Callee]
  statics: Map[String, String]
  fields: Map[String, String]
  globals: Map[String, String]
end

# An argument of a call: its text, and its class when it is a lock.
struct Arg
  text: String
  class: String
end

# A block: its id, and the cleanup calls of its variables so far, in the order they were declared.
struct Scope
  id: String
  cleanups: List[Site]
end

# A loop or a switch, for its `break`, `continue` and `case`. `depth` is the number of blocks open around it.
struct Jump
  switch: Bool
  head: Int
  depth: Int
  breaks: List[Int]
  continues: List[Int]
  defaulted: Bool
end

struct Goto
  from: Int
  label: String
end

struct Builder
  ctx: Context
  aliases: Map[String, Json]
  label_blocks: Map[String, List[String]]
  nodes: List[Node]
  scopes: List[Scope]
  jumps: List[Jump]
  labels: Map[String, Int]
  gotos: List[Goto]
end

# A part of the graph: the nodes that fall through out of it.
struct Built
  b: Builder
  exits: List[Int]
end

# A condition: the nodes after it when it is true, and when it is false.
struct Split
  b: Builder
  yes: List[Int]
  no: List[Int]
end

# A call of `Known.TRIES` in a condition, and whether the condition is true when the call gave 0 (`call == 0`) or
# false (`call`, `call != 0`).
struct Tried
  call: Json
  zero_is_true: Bool
end

## Returns whether a function body calls something that takes or releases a lock, the only bodies the path rules read.
export def locks?(ctx: Context, node: Json) -> Bool
  name = ""
  if Ast.kind(node) == "CallExpr"
    name = callee_name(node)
  elsif Ast.kind(node) == "CleanupAttr"
    name = Ast.text(JSON.get(node, "cleanup_function").unwrap_or(JSON.from("")), "name")
  end

  if Known.TAKES.include?(name) or Known.TRIES.include?(name) or Known.DROPS.include?(name)
    return true
  end

  if name != "" and ctx.callees.key?(key_of_function(ctx, name))
    return true
  end

  return Ast.children(node).any? do |child| locks?(ctx, child) end
end

## Returns the graph of a function definition, whose key is `key`.
export def body_of(ctx: Context, key: String, node: Json) -> Body
  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  place = Ast.place_of(node)
  start = Builder(
    ctx: ctx,
    aliases: aliases_of(bodies),
    label_blocks: label_blocks(bodies, []),
    nodes: [Node(event: Event.Join, next: [])],
    scopes: [],
    jumps: [],
    labels: {},
    gotos: [],
  )

  built = Built(b: start, exits: [0])
  for body in bodies
    built = statement(built.b, body, built.exits)
    end_place = Ast.end_of(body)
    built = add(built.b, Event.Exit(Mark(word: "ends", line: end_place.line, column: end_place.column)), built.exits)
    built = Built(b: built.b, exits: [])
  end

  linked = with_gotos(built.b)
  return Body(
    key: key,
    name: Ast.text(node, "name"),
    file: place.file,
    line: place.line,
    column: place.column,
    nodes: linked.nodes,
  )
end

## Returns the lock text of an annotation (`q->mu`) for a call that passes `args`, the texts of its arguments, to a
## function whose parameters are `params`; "" when the lock names a parameter that the call passes no text for.
export def substituted(lock: String, params: List[String], args: List[String]) -> String
  written = lock.replace(" ", "")
  prefix = ""
  while written.start_with?("&") or written.start_with?("*")
    prefix = prefix + written.slice(0, 1)
    written = written.slice(1, written.length - 1)
  end

  root = written.length
  for i in 0...written.length
    if not identifier_char?(written.slice(i, 1))
      root = i
      break
    end
  end

  name = written.slice(0, root)
  for i in 0...params.size
    if params[i] == name
      if i >= args.size or args[i] == ""
        return ""
      end

      return prefix + args[i] + written.slice(root, written.length - root)
    end
  end

  return prefix + written
end

## Returns the key of a lock text: the object, without the `&` or `*&` in front, and `->` read as `.`.
export def key_of(lock: String) -> String
  return shown_of(lock).replace("->", ".")
end

## Returns a lock text as a finding shows it: without the `&` or `*&` in front.
export def shown_of(lock: String) -> String
  written = lock.replace(" ", "").replace("(", "").replace(")", "")
  while written.start_with?("*&") or written.start_with?("&")
    if written.start_with?("*&")
      written = written.slice(2, written.length - 2)
    else
      written = written.slice(1, written.length - 1)
    end
  end

  return written
end

def identifier_char?(c: String) -> Bool
  code = c.code
  return c == "_" or (code >= 97 and code <= 122) or (code >= 65 and code <= 90) or (code >= 48 and code <= 57)
end

# The local variables that are set once, where they are declared, and never written or lent (`&x`) after: a lock
# named through one of them is the lock of its value.
def aliases_of(bodies: List[Json]) -> Map[String, Json]
  values: Map[String, Json] = {}
  written: Set[String] = Set.new([])
  for node in descendants(bodies)
    kind = Ast.kind(node)
    if kind == "VarDecl"
      inits = Ast.children(node).select do |child| not Ast.kind(child).end_with?("Attr") end
      name = Ast.text(node, "name")
      if inits.size == 1 and not values.key?(name)
        values = values.put(name, inits.first)
      else
        written = written.add(name)
      end
    elsif writes?(node)
      written = written.add(target_root(Ast.children(node).first))
    end
  end

  return values.select do |name, _value| not written.include?(name) end
end

# Whether a node writes the variable of its first child: an assignment, `++`, `--`, or `&`, which lends it.
def writes?(node: Json) -> Bool
  opcode = Ast.text(node, "opcode")
  case Ast.kind(node)
    "BinaryOperator" -> return ASSIGNMENTS.include?(opcode)
    "CompoundAssignOperator" -> return true
    "UnaryOperator" -> return opcode == "++" or opcode == "--" or opcode == "&"
    _ -> return false
  end
end

# The blocks around each label, by the id of the label's declaration, from the outermost.
def label_blocks(nodes: List[Json], around: List[String]) -> Map[String, List[String]]
  found: Map[String, List[String]] = {}
  for node in nodes
    inner = around
    if Ast.kind(node) == "CompoundStmt"
      inner = around.push(Ast.text(node, "id"))
    end

    if Ast.kind(node) == "LabelStmt"
      found = found.put(Ast.text(node, "declId"), inner)
    end

    nested = label_blocks(Ast.children(node), inner)
    for label in nested.keys
      found = found.put(label, nested[label])
    end
  end

  return found
end

# Every node under the given ones.
def descendants(nodes: List[Json]) -> List[Json]
  found: List[Json] = []
  pending = nodes.reverse
  while not pending.empty?
    node = pending.last
    pending = pending.take(pending.size - 1)
    found = found.push(node)
    pending = pending.concat(Ast.children(node).reverse)
  end

  return found
end

def statement(b: Builder, node: Json, preds: List[Int]) -> Built
  case Ast.kind(node)
    "" -> return Built(b: b, exits: preds)
    "CompoundStmt" -> return block(b, node, preds)
    "IfStmt" -> return if_statement(b, node, preds)
    "WhileStmt" -> return while_loop(b, node, preds)
    "DoStmt" -> return do_loop(b, node, preds)
    "ForStmt" -> return for_loop(b, node, preds)
    "SwitchStmt" -> return switch_statement(b, node, preds)
    "CaseStmt" -> return case_label(b, node, preds, "case")
    "DefaultStmt" -> return case_label(b, node, preds, "default")
    "BreakStmt" -> return break_statement(b, preds)
    "ContinueStmt" -> return continue_statement(b, preds)
    "ReturnStmt" -> return return_statement(b, node, preds)
    "GotoStmt" -> return goto_statement(b, Ast.text(node, "targetLabelDeclId"), preds)
    "IndirectGotoStmt" -> return goto_statement(b, "", preds)
    "LabelStmt" ->
      label = add(b, Event.Join, preds)
      labelled = label.b.with(labels: label.b.labels.put(Ast.text(node, "declId"), label.exits.first))
      return statement(labelled, last_child(node), label.exits)
    "AttributedStmt" -> return statement(b, last_child(node), preds)
    "DeclStmt" -> return declarations(b, node, preds)
    "NullStmt" -> return Built(b: b, exits: preds)
    "GCCAsmStmt" -> return Built(b: b, exits: preds)
    _ -> return expression(b, node, preds)
  end
end

def block(b: Builder, node: Json, preds: List[Int]) -> Built
  opened = b.with(scopes: b.scopes.push(Scope(id: Ast.text(node, "id"), cleanups: [])))
  built = Built(b: opened, exits: preds)
  for child in Ast.children(node)
    built = statement(built.b, child, built.exits)
  end

  scope = built.b.scopes.last
  cleaned = calls(built.b, scope.cleanups.reverse, built.exits)
  closed = cleaned.b.with(scopes: cleaned.b.scopes.take(cleaned.b.scopes.size - 1))
  return Built(b: closed, exits: cleaned.exits)
end

# An `if` and the `else if` chain after it, in a loop: a recursion would keep every builder of the chain alive.
def if_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  current = node
  built = b
  pending = preds
  exits: List[Int] = []
  while true
    parts = Ast.children(current)
    split = condition(built, parts[0], pending)
    then_part = statement(split.b, parts[1], split.yes)
    exits = exits.concat(then_part.exits)
    if not Ast.flag?(current, "hasElse")
      return Built(b: then_part.b, exits: exits.concat(split.no))
    end

    if Ast.kind(parts[2]) != "IfStmt"
      else_part = statement(then_part.b, parts[2], split.no)
      return Built(b: else_part.b, exits: exits.concat(else_part.exits))
    end

    current = parts[2]
    built = then_part.b
    pending = split.no
  end

  return Built(b: built, exits: exits)
end

def while_loop(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  head = add(b, Event.Join, preds)
  split = condition(head.b, parts[0], head.exits)
  return looped(split.b, parts[1], split, head.exits.first, JSON.from(""))
end

def do_loop(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  head = add(b, Event.Join, preds)
  opened = head.b.with(jumps: head.b.jumps.push(loop_jump(head.b, head.exits.first)))
  body = statement(opened, parts[0], head.exits)
  jump = body.b.jumps.last
  closed = body.b.with(jumps: body.b.jumps.take(body.b.jumps.size - 1))
  test = add(closed, Event.Join, body.exits.concat(jump.continues))
  split = condition(test.b, parts[1], test.exits)
  return Built(b: link(split.b, split.yes, head.exits.first), exits: split.no.concat(jump.breaks))
end

def for_loop(b: Builder, node: Json, preds: List[Int]) -> Built
  # The parts are the init, a C++ condition variable, the condition, the increment and the body; a missing one is an
  # empty node.
  parts = Ast.children(node)
  init = statement(b, parts[0], preds)
  head = add(init.b, Event.Join, init.exits)
  split = Split(b: head.b, yes: head.exits, no: [])
  if Ast.kind(parts[2]) != ""
    split = condition(head.b, parts[2], head.exits)
  end

  return looped(split.b, parts[4], split, head.exits.first, parts[3])
end

# The body of a `while` or a `for` from the true side of its condition, then the increment (an empty node for a
# `while`), back to the head.
def looped(b: Builder, body: Json, split: Split, head: Int, increment: Json) -> Built
  opened = b.with(jumps: b.jumps.push(loop_jump(b, head)))
  ran = statement(opened, body, split.yes)
  jump = ran.b.jumps.last
  closed = ran.b.with(jumps: ran.b.jumps.take(ran.b.jumps.size - 1))
  stepped = expression(closed, increment, ran.exits.concat(jump.continues))
  return Built(b: link(stepped.b, stepped.exits, head), exits: split.no.concat(jump.breaks))
end

def loop_jump(b: Builder, head: Int) -> Jump
  return Jump(switch: false, head: head, depth: b.scopes.size, breaks: [], continues: [], defaulted: false)
end

# A switch jumps from its head to each `case` and `default` of its body; without a `default`, a value that no case
# names goes past the body.
def switch_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  value = expression(b, parts[0], preds)
  head = add(value.b, Event.Join, value.exits)
  jump = Jump(
    switch: true,
    head: head.exits.first,
    depth: head.b.scopes.size,
    breaks: [],
    continues: [],
    defaulted: false,
  )

  body = statement(head.b.with(jumps: head.b.jumps.push(jump)), parts[1], [])
  done = body.b.jumps.last
  closed = body.b.with(jumps: body.b.jumps.take(body.b.jumps.size - 1))
  exits = body.exits.concat(done.breaks)
  if done.defaulted
    return Built(b: closed, exits: exits)
  end

  place = Ast.start_of(node)
  missed = add(closed, Event.Note(Mark(word: "no case", line: place.line, column: place.column)), head.exits)
  return Built(b: missed.b, exits: exits.concat(missed.exits))
end

def case_label(b: Builder, node: Json, preds: List[Int], word: String) -> Built
  at = innermost(b.jumps, true)
  if at < 0
    return statement(b, last_child(node), preds)
  end

  jump = b.jumps[at]
  place = Ast.start_of(node)
  marked = add(b, Event.Note(Mark(word: word, line: place.line, column: place.column)), [jump.head])
  entry = add(marked.b, Event.Join, preds.concat(marked.exits))
  updated = entry.b.with(jumps: entry.b.jumps.set(at, jump.with(defaulted: jump.defaulted or word == "default")))
  return statement(updated, last_child(node), entry.exits)
end

def break_statement(b: Builder, preds: List[Int]) -> Built
  at = innermost(b.jumps, false)
  if at < 0
    return Built(b: b, exits: [])
  end

  left = leaving(b, b.jumps[at].depth, preds)
  jump = left.b.jumps[at]
  return Built(
    b: left.b.with(jumps: left.b.jumps.set(at, jump.with(breaks: jump.breaks.concat(left.exits)))),
    exits: [],
  )
end

def continue_statement(b: Builder, preds: List[Int]) -> Built
  at = innermost_loop(b.jumps)
  if at < 0
    return Built(b: b, exits: [])
  end

  left = leaving(b, b.jumps[at].depth, preds)
  jump = left.b.jumps[at]
  updated = left.b.jumps.set(at, jump.with(continues: jump.continues.concat(left.exits)))
  return Built(b: left.b.with(jumps: updated), exits: [])
end

# The index of the innermost jump a `break` leaves (a loop or a switch), or a `case` belongs to (a switch); -1
# for none.
def innermost(jumps: List[Jump], switch_only: Bool) -> Int
  i = jumps.size - 1
  while i >= 0
    if jumps[i].switch or not switch_only
      return i
    end

    i -= 1
  end

  return -1
end

def innermost_loop(jumps: List[Jump]) -> Int
  i = jumps.size - 1
  while i >= 0
    if not jumps[i].switch
      return i
    end

    i -= 1
  end

  return -1
end

def return_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  value = Built(b: b, exits: preds)
  for child in Ast.children(node)
    value = expression(value.b, child, value.exits)
  end

  left = leaving(value.b, 0, value.exits)
  place = Ast.start_of(node)
  ended = add(left.b, Event.Exit(Mark(word: "returns", line: place.line, column: place.column)), left.exits)
  return Built(b: ended.b, exits: [])
end

# A `goto` leaves the blocks that are not around its label. The label is linked at the end, when every label is known;
# an indirect `goto` ("") may go to any label.
def goto_statement(b: Builder, label: String, preds: List[Int]) -> Built
  around = Set.new(b.label_blocks.get(label).unwrap_or([]))
  depth = 0
  while depth < b.scopes.size and around.include?(b.scopes[depth].id)
    depth += 1
  end

  left = leaving(b, depth, preds)
  jumped = add(left.b, Event.Join, left.exits)
  return Built(b: jumped.b.with(gotos: jumped.b.gotos.push(Goto(from: jumped.exits.first, label: label))), exits: [])
end

def with_gotos(b: Builder) -> Builder
  linked = b
  for jump in b.gotos
    if jump.label == ""
      for target in b.labels.values
        linked = link(linked, [jump.from], target)
      end
    else
      case b.labels.get(jump.label)
        some(target) -> linked = link(linked, [jump.from], target)
        none -> next
      end
    end
  end

  return linked
end

# The cleanup calls of the blocks from `depth` in, the innermost first, on the way out of them.
def leaving(b: Builder, depth: Int, preds: List[Int]) -> Built
  sites: List[Site] = []
  i = b.scopes.size - 1
  while i >= depth
    sites = sites.concat(b.scopes[i].cleanups.reverse)
    i -= 1
  end

  return calls(b, sites, preds)
end

def calls(b: Builder, sites: List[Site], preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for site in sites
    built = add(built.b, Event.Call(site), built.exits)
  end

  return built
end

def declarations(b: Builder, node: Json, preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for child in Ast.children(node)
    if Ast.kind(child) == "VarDecl"
      built = declaration(built.b, child, built.exits)
    end
  end

  return built
end

# A variable: its value, then the write of it, and its cleanup call for the way out of its block.
def declaration(b: Builder, node: Json, preds: List[Int]) -> Built
  name = Ast.text(node, "name")
  built = Built(b: b, exits: preds)
  for child in Ast.children(node)
    if not Ast.kind(child).end_with?("Attr")
      built = expression(built.b, child, built.exits)
    end
  end

  written = add(built.b, Event.Writes([name]), built.exits)
  cleanup = Ast.children(node).select do |child| Ast.kind(child) == "CleanupAttr" end
  if cleanup.empty? or written.b.scopes.empty?
    return written
  end

  function = Ast.text(JSON.get(cleanup.first, "cleanup_function").unwrap_or(JSON.from("")), "name")
  place = Ast.place_of(node)
  var = Arg(
    text: "&#{local_text(written.b, name)}",
    class: written.b.aliases.get(name).map do |value| class_of(written.b, value) end.unwrap_or(""),
  )

  site = site_of(written.b, function, [var], place, "")
  scope = written.b.scopes.last
  scopes = written.b.scopes.set(written.b.scopes.size - 1, scope.with(cleanups: scope.cleanups.push(site)))
  return Built(b: written.b.with(scopes: scopes), exits: written.exits)
end

def expression(b: Builder, node: Json, preds: List[Int]) -> Built
  case Ast.kind(node)
    "" -> return Built(b: b, exits: preds)
    "CallExpr" -> return call(b, node, preds, false)
    "BinaryOperator" ->
      opcode = Ast.text(node, "opcode")
      if opcode == "&&" or opcode == "||"
        split = condition(b, node, preds)
        return Built(b: split.b, exits: split.yes.concat(split.no))
      end

      if ASSIGNMENTS.include?(opcode)
        return assignment(b, node, preds)
      end

      return in_order(b, Ast.children(node), preds)
    "CompoundAssignOperator" -> return assignment(b, node, preds)
    "UnaryOperator" ->
      opcode = Ast.text(node, "opcode")
      operand = Ast.children(node).first
      inner = expression(b, operand, preds)
      if opcode == "++" or opcode == "--"
        return add(inner.b, Event.Writes([target_root(operand)]), inner.exits)
      end

      # The address of a variable lets a callee change it; the address of `q->mu` does not change `q`.
      root = storage_root(operand)
      if opcode == "&" and root != ""
        return add(inner.b, Event.Writes([root]), inner.exits)
      end

      return inner
    "ConditionalOperator" ->
      parts = Ast.children(node)
      split = condition(b, parts[0], preds)
      chosen = expression(split.b, parts[1], split.yes)
      other = expression(chosen.b, parts[2], split.no)
      return Built(b: other.b, exits: chosen.exits.concat(other.exits))
    "BinaryConditionalOperator" ->
      # `x ?: y`: the value of `x` when it is true, else `y`.
      parts = Ast.children(node)
      split = condition(b, parts[0], preds)
      other = expression(split.b, parts.last, split.no)
      return Built(b: other.b, exits: split.yes.concat(other.exits))
    "StmtExpr" -> return in_order_statements(b, Ast.children(node), preds)
    "UnaryExprOrTypeTraitExpr" -> return Built(b: b, exits: preds)
    _ -> return in_order(b, Ast.children(node), preds)
  end
end

def in_order(b: Builder, nodes: List[Json], preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for node in nodes
    built = expression(built.b, node, built.exits)
  end

  return built
end

def in_order_statements(b: Builder, nodes: List[Json], preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for node in nodes
    built = statement(built.b, node, built.exits)
  end

  return built
end

def assignment(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  value = in_order(b, parts.drop(1).concat(parts.take(1)), preds)
  return add(value.b, Event.Writes([target_root(parts.first)]), value.exits)
end

# A call: its arguments in order, then the call. A call that never comes back ends the path. `tried` leaves out the
# lock that a call of `Known.TRIES` takes: the condition around it takes it on the branch where it worked.
def call(b: Builder, node: Json, preds: List[Int], tried: Bool) -> Built
  parts = Ast.children(node)
  if parts.empty?
    return Built(b: b, exits: preds)
  end

  callee = see_through(parts.first)
  args = parts.drop(1)
  built = in_order(b, args, preds)
  if Ast.kind(callee) != "DeclRefExpr" or Ast.referenced_kind(callee) != "FunctionDecl"
    # A call through a pointer: the rules on held locks follow the functions stored in it. One whose type does not
    # return ends the path too.
    pointer = expression(built.b, parts.first, built.exits)
    place = Ast.start_of(node)
    site = Site(
      name: text_of(pointer.b, parts.first, false),
      key: "",
      line: place.line,
      column: place.column,
      takes: [],
      drops: [],
      stops: type_text(parts.first).include?(NORETURN_TYPE),
      pointer: true,
    )

    through = add(pointer.b, Event.Call(site), pointer.exits)
    if site.stops
      return Built(b: through.b, exits: [])
    end

    return through
  end

  # The type of the declaration: the reference to a builtin such as `__builtin_abort` has no type of its own.
  type = type_text(JSON.get(callee, "referencedDecl").unwrap_or(JSON.from("")))
  site = site_of(
    built.b,
    Ast.referenced_name(callee),
    args.map do |arg| arg_of(built.b, arg) end,
    Ast.start_of(node),
    type,
  )

  if tried
    site = site.with(takes: [])
  end

  called = add(built.b, Event.Call(site), built.exits)
  if site.stops
    return Built(b: called.b, exits: [])
  end

  return called
end

# What a call does to the locks: a known call takes or drops the lock of its first argument, and a function with
# CC_ACQUIRES or CC_RELEASES the locks it names, in the texts of the arguments of the call.
def site_of(b: Builder, name: String, args: List[Arg], place: Ast.Place, type: String) -> Site
  key = key_of_function(b.ctx, name)
  takes: List[Lock] = []
  drops: List[Lock] = []
  waits: List[Lock] = []
  stops = Known.NORETURN.include?(name) or type.include?(NORETURN_TYPE)
  if Known.TAKES.include?(name)
    takes = lock_of(args, 0)
  end

  if Known.DROPS.include?(name)
    drops = lock_of(args, 0)
  end

  if Known.WAITS.include?(name)
    waits = lock_of(args, 1)
  end

  site = Site(
    name: name,
    key: key,
    line: place.line,
    column: place.column,
    takes: takes,
    drops: drops,
    stops: stops,
    waits: waits,
  )

  case b.ctx.callees.get(key)
    some(callee) ->
      texts = args.map do |arg| arg.text end
      taken = callee.locks.select do |lock| lock.takes end
      dropped = callee.locks.select do |lock| not lock.takes end
      return site.with(
        takes: takes.concat(taken.flat_map do |lock| annotated_lock(lock, texts) end),
        drops: drops.concat(dropped.flat_map do |lock| annotated_lock(lock, texts) end),
        stops: stops or callee.stops,
      )
    none -> return site
  end
end

# The lock of the argument at `index`, if the call has it and it names an object.
def lock_of(args: List[Arg], index: Int) -> List[Lock]
  if index >= args.size
    return []
  end

  return locks_of([args[index].text]).map do |lock| lock.with(class: args[index].class) end
end

# The lock of an annotation, in the texts of the arguments of the call.
def annotated_lock(lock: Annotated, texts: List[String]) -> List[Lock]
  return locks_of([substituted(lock.text, lock.params, texts)]).map do |found|
    found.with(class: lock.class, pair: lock.pair)
  end
end

def arg_of(b: Builder, node: Json) -> Arg
  return Arg(text: text_of(b, node, true), class: class_of(b, node))
end

# The class of a lock expression: the field it ends in, or a global variable, through `&`, `*` and the local variables
# set once.
def class_of(b: Builder, node: Json) -> String
  return aliased_class(b, node, 0)
end

def aliased_class(b: Builder, node: Json, depth: Int) -> String
  bare = see_through(node)
  while Ast.kind(bare) == "UnaryOperator" and UNARY_TEXT.include?(Ast.text(bare, "opcode"))
    bare = see_through(Ast.children(bare).first)
  end

  case Ast.kind(bare)
    "MemberExpr" -> return b.ctx.fields.get(Ast.text(bare, "referencedMemberDecl")).unwrap_or("")
    "ArraySubscriptExpr" -> return aliased_class(b, Ast.children(bare).first, depth)
    "DeclRefExpr" ->
      name = Ast.referenced_name(bare)
      case b.aliases.get(name)
        some(value) if depth < ALIAS_DEPTH -> return aliased_class(b, value, depth + 1)
        _ ->
          declared = JSON.get(bare, "referencedDecl").unwrap_or(JSON.from(""))
          return b.ctx.globals.get(Ast.text(declared, "id")).unwrap_or("")
      end

    _ -> return ""
  end
end

# The locks of lock texts; a text that is "" (an expression that names no object, such as a call) is no lock.
def locks_of(texts: List[String]) -> List[Lock]
  return texts.select do |text| text != "" end.map do |text| Lock(key: key_of(text), shown: shown_of(text)) end
end

# A condition: the nodes after it when it is true and when it is false. `!`, `&&` and `||` split it, a constant
# goes one way, and a call of `Known.TRIES` that is compared with 0 takes its lock on the side where it gave 0.
def condition(b: Builder, node: Json, preds: List[Int]) -> Split
  bare = see_through(node)
  kind = Ast.kind(bare)
  opcode = Ast.text(bare, "opcode")
  parts = Ast.children(bare)
  if kind == "UnaryOperator" and opcode == "!"
    inner = condition(b, parts.first, preds)
    return Split(b: inner.b, yes: inner.no, no: inner.yes)
  end

  if kind == "BinaryOperator" and (opcode == "&&" or opcode == "||")
    return chain(b, operands_of(bare, opcode), opcode == "&&", preds)
  end

  if kind == "IntegerLiteral"
    if Ast.text(bare, "value") == "0"
      return Split(b: b, yes: [], no: preds)
    end

    return Split(b: b, yes: preds, no: [])
  end

  case tried_call(bare)
    some(tried) -> return trial(b, tried, preds)
    none -> return branch(b, bare, preds)
  end
end

# The operands of `a && b && c` (or of `||`) from left to right. clang nests such a chain to the left, so the walk
# goes down it in a loop.
def operands_of(node: Json, opcode: String) -> List[Json]
  rights: List[Json] = []
  current = node
  while Ast.kind(current) == "BinaryOperator" and Ast.text(current, "opcode") == opcode
    parts = Ast.children(current)
    rights = rights.push(parts[1])
    current = see_through(parts[0])
  end

  return [current].concat(rights.reverse)
end

# The operands of `&&` (`all`) or `||` in order: each one after the previous one gave the value that goes on.
def chain(b: Builder, operands: List[Json], all: Bool, preds: List[Int]) -> Split
  built = b
  pending = preds
  out: List[Int] = []
  for operand in operands
    split = condition(built, operand, pending)
    built = split.b
    if all
      out = out.concat(split.no)
      pending = split.yes
    else
      out = out.concat(split.yes)
      pending = split.no
    end
  end

  if all
    return Split(b: built, yes: pending, no: out)
  end

  return Split(b: built, yes: out, no: pending)
end

# A condition of any other form: its calls, then a node for each of its values.
def branch(b: Builder, bare: Json, preds: List[Int]) -> Split
  value = expression(b, bare, preds)
  text = text_of(value.b, bare, false)
  roots = roots_of(bare)
  place = Ast.start_of(bare)
  yes = add(
    value.b,
    Event.Branch(Fact(text: text, value: true, roots: roots, line: place.line, column: place.column)),
    value.exits,
  )

  no = add(
    yes.b,
    Event.Branch(Fact(text: text, value: false, roots: roots, line: place.line, column: place.column)),
    value.exits,
  )

  return Split(b: no.b, yes: yes.exits, no: no.exits)
end

def tried_call(node: Json) -> Optional[Tried]
  if try_call?(node)
    return some(Tried(call: see_through(node), zero_is_true: false))
  end

  opcode = Ast.text(node, "opcode")
  parts = Ast.children(node)
  if Ast.kind(node) != "BinaryOperator" or (opcode != "==" and opcode != "!=") or parts.size != 2
    return none
  end

  for pair in [[parts[0], parts[1]], [parts[1], parts[0]]]
    if try_call?(pair[0]) and zero?(pair[1])
      return some(Tried(call: see_through(pair[0]), zero_is_true: opcode == "=="))
    end
  end

  return none
end

def try_call?(node: Json) -> Bool
  bare = see_through(node)
  return Ast.kind(bare) == "CallExpr" and Known.TRIES.include?(callee_name(bare))
end

def zero?(node: Json) -> Bool
  bare = see_through(node)
  return Ast.kind(bare) == "IntegerLiteral" and Ast.text(bare, "value") == "0"
end

# The call, then on the branch where it gave 0 a node that takes its lock.
def trial(b: Builder, tried: Tried, preds: List[Int]) -> Split
  called = call(b, tried.call, preds, true)
  args = Ast.children(tried.call).drop(1)
  name = callee_name(tried.call)
  passed = args.map do |arg| arg_of(called.b, arg) end
  site = site_of(called.b, name, passed, Ast.start_of(tried.call), "")
  taken = add(
    called.b,
    Event.Call(site.with(takes: lock_of(passed, 0), tried: Known.NO_WAIT.include?(name))),
    called.exits,
  )

  if tried.zero_is_true
    return Split(b: taken.b, yes: taken.exits, no: called.exits)
  end

  return Split(b: taken.b, yes: called.exits, no: taken.exits)
end

# The text of an expression, from the names, fields, constants and operators of `UNARY_TEXT` and `BINARY_TEXT`; ""
# for anything else. With `aliases`, a local variable set once reads as its value.
def text_of(b: Builder, node: Json, aliases: Bool) -> String
  return written_text(b, node, aliases, 0)
end

def written_text(b: Builder, node: Json, aliases: Bool, depth: Int) -> String
  bare = see_through(node)
  parts = Ast.children(bare)
  case Ast.kind(bare)
    "DeclRefExpr" ->
      name = Ast.referenced_name(bare)
      aliased = ""
      if aliases and depth < ALIAS_DEPTH
        aliased = b.aliases.get(name).map do |value| written_text(b, value, aliases, depth + 1) end.unwrap_or("")
      end

      if aliased != ""
        return aliased
      end

      return name
    "MemberExpr" ->
      base = written_text(b, parts.first, aliases, depth)
      if base == ""
        return ""
      end

      if Ast.flag?(bare, "isArrow")
        return "#{base}->#{Ast.text(bare, "name")}"
      end

      return "#{base}.#{Ast.text(bare, "name")}"
    "ArraySubscriptExpr" ->
      array = written_text(b, parts[0], aliases, depth)
      index = written_text(b, parts[1], aliases, depth)
      if array == "" or index == ""
        return ""
      end

      return "#{array}[#{index}]"
    "UnaryOperator" ->
      operand = written_text(b, parts.first, aliases, depth)
      if operand == "" or Ast.flag?(bare, "isPostfix") or not UNARY_TEXT.include?(Ast.text(bare, "opcode"))
        return ""
      end

      return "#{Ast.text(bare, "opcode")}#{operand}"
    "BinaryOperator" ->
      left = written_text(b, parts[0], aliases, depth)
      right = written_text(b, parts[1], aliases, depth)
      if left == "" or right == "" or not BINARY_TEXT.include?(Ast.text(bare, "opcode"))
        return ""
      end

      return "#{left} #{Ast.text(bare, "opcode")} #{right}"
    "IntegerLiteral" -> return Ast.text(bare, "value")
    "CharacterLiteral" -> return "#{Ast.number(bare, "value")}"
    _ -> return ""
  end
end

# The text of a local variable, through its alias when it has one.
def local_text(b: Builder, name: String) -> String
  case b.aliases.get(name)
    some(value) ->
      aliased = text_of(b, value, true)
      if aliased != ""
        return aliased
      end

      return name
    none -> return name
  end
end

# The variables an expression reads.
def roots_of(node: Json) -> List[String]
  if Ast.kind(node) == "DeclRefExpr"
    return [Ast.referenced_name(node)]
  end

  return Ast.children(node).flat_map(&roots_of).uniq
end

# The variable an assignment writes: the root of `x`, `x->a.b` or `x[i]`.
def target_root(node: Json) -> String
  bare = see_through(node)
  case Ast.kind(bare)
    "DeclRefExpr" -> return Ast.referenced_name(bare)
    "MemberExpr" -> return target_root(Ast.children(bare).first)
    "ArraySubscriptExpr" -> return target_root(Ast.children(bare).first)
    "UnaryOperator" -> return target_root(Ast.children(bare).first)
    _ -> return ""
  end
end

# The variable whose own storage an expression is: `x`, `x.a`, `x[i]` of an array `x`; "" through a pointer (`q->mu`,
# `*p`, `p[i]`), whose variable a write through the address does not change.
def storage_root(node: Json) -> String
  bare = see_through(node)
  case Ast.kind(bare)
    "DeclRefExpr" -> return Ast.referenced_name(bare)
    "MemberExpr" ->
      if Ast.flag?(bare, "isArrow")
        return ""
      end

      return storage_root(Ast.children(bare).first)
    "ArraySubscriptExpr" ->
      base = Ast.children(bare).first
      if Ast.text(base, "castKind") != "ArrayToPointerDecay"
        return ""
      end

      return storage_root(Ast.children(base).first)
    _ -> return ""
  end
end

# The type of a node as clang writes it and without its typedefs, so a `noreturn` behind a typedef shows.
def type_text(node: Json) -> String
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  return "#{Ast.text(type, "qualType")} #{Ast.text(type, "desugaredQualType")}"
end

def see_through(node: Json) -> Json
  bare = node
  while SEE_THROUGH.include?(Ast.kind(bare)) and not Ast.children(bare).empty?
    bare = Ast.children(bare).first
  end

  return bare
end

def callee_name(node: Json) -> String
  parts = Ast.children(node)
  if parts.empty?
    return ""
  end

  callee = see_through(parts.first)
  if Ast.kind(callee) != "DeclRefExpr" or Ast.referenced_kind(callee) != "FunctionDecl"
    return ""
  end

  return Ast.referenced_name(callee)
end

def key_of_function(ctx: Context, name: String) -> String
  return ctx.statics.get(name).unwrap_or(name)
end

def last_child(node: Json) -> Json
  parts = Ast.children(node)
  if parts.empty?
    return JSON.from("")
  end

  return parts.last
end

# A new node after `preds`.
def add(b: Builder, event: Event, preds: List[Int]) -> Built
  index = b.nodes.size
  grown = b.with(nodes: b.nodes.push(Node(event: event, next: [])))
  return Built(b: link(grown, preds, index), exits: [index])
end

def link(b: Builder, froms: List[Int], to: Int) -> Builder
  nodes = b.nodes
  for from in froms
    node = nodes[from]
    if not node.next.include?(to)
      nodes = nodes.set(from, node.with(next: node.next.push(to)))
    end
  end

  return b.with(nodes: nodes)
end
