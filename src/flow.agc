## The control flow graph of a function body, as the path rules need it: the calls, with the locks they take and
## release, the conditions, the writes that change what a condition read, and the ends of the paths.
##
## A node holds one event and the nodes that can come after it. Node 0 is the entry. A path ends at an `Exit` (a
## `return`, or the end of the body) or at a call that never comes back. A call is a node once its arguments are; the
## variables with `__attribute__((cleanup(f)))` call `f` on every way out of their block.
##
## For the ownership rules, the graph also holds what happens to the pointers that own (`Owning`): the reads of them,
## the values they get, the calls that free them or take them, and the returns and stores that hand them on.

import Ast from "ast"
import Known from "known"

## The start of the key of the lock that stands for a CC_PAIR(set, restore): `pair:set:restore`, which the calls of
## `set` take and the calls of `restore` release: no lock expression of the code looks like it.
export PAIR_PREFIX = "pair:"

## The nodes that do not change the value of the expression inside them: casts and parentheses.
export SEE_THROUGH = Set.new(["ImplicitCastExpr", "CStyleCastExpr", "ParenExpr", "ConstantExpr", "ExprWithCleanups"])

# The expressions whose value is one of several (`values_of`).
CHOICES = Set.new(["ConditionalOperator", "BinaryConditionalOperator", "StmtExpr"])

ASSIGNMENTS = Set.new(["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="])

# The operators a condition or a lock may be written with. Anything else (a call, an assignment) has no text: its
# value can change between two reads.
UNARY_TEXT = Set.new(["&", "*", "!", "-", "~"])
BINARY_TEXT = Set.new(["==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"])

# How deep a local variable is followed to the value it was set to (`m = &q->mu`, `n = m`).
ALIAS_DEPTH = 4

# The annotation of a local variable that owns, as the AST keeps it.
OWNS_MARK = "cchecker:owns"

# The kinds of declarations a pointer that owns can be: a local variable or a parameter.
VARIABLES = Set.new(["VarDecl", "ParmVarDecl"])

# What the key of a variable that shares its name with an earlier declaration of the function, or with a variable that
# the function reads and does not declare (a global), has between the name and its number (`p#2`). A C name has no
# such character, so a key is its name when nothing else of the function has that name.
KEY_MARK = "#"

# The digits of the number in a key.
DIGITS = Set.new(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])

## A lock: `key` is what tells two locks apart (`q.mu` for `&q->mu`, `q->mu` and `(&q->mu)`), `shown` how the code
## wrote it, and `class` the field it is (`queue.mu`, by struct and field name) or the global, which the marks of
## CC_NO_SYSCALL_UNDER() and CC_LOCK_LEVEL name; "" when the rules cannot tell. `pair` is the restore of the lock of
## a CC_PAIR, "" for a lock of the code. `through` says that the field or global of the class is a pointer to the
## mutex, not the mutex: two classes may then be one mutex (`c->lk` pointing at `s->lock`).
export struct Lock
  key: String
  shown: String
  class: String = ""
  pair: String = ""
  through: Bool = false
end

## A call of a function, by name and key (`name@file` for a static one), and what it does to the locks: those it takes,
## releases, and waits on (a condition wait gives its lock back while it waits). A call through a function pointer
## (`pointer`) has the text of the pointer as its name and no key. `tried` is a trylock, which never waits for its lock.
## For ownership: the pointers that own which it frees and which it takes (`hands`), whether it returns an owned
## value that nothing keeps (`lost`), those it frees through their address (`clears`, `free_and_null(&p)`), which
## are freed or null after it, and those whose address it gets at a CC_OWNS_OUT parameter (`fills`), which own what
## it left in them.
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
  frees: List[String] = []
  hands: List[String] = []
  lost: Bool = false
  clears: List[String] = []
  fills: List[String] = []
  # Whether the call takes a lock that no text names (`&current()->mu`, `&locks[hash(k)]`): no walk sees it.
  unnamed: Bool = false
end

## The value a condition has on an edge. `text` is the condition with the key of each variable (`variable_key`), ""
## for a condition that may change between two reads (a call). `roots` are the variables it reads, by key, so a write
## to one forgets it. `nulls` are the pointers that own which are null on this edge (`if (!p)`,
## `if ((p = malloc(n)) == NULL)`), and `set` those that are not.
export struct Fact
  text: String
  value: Bool
  roots: List[String]
  line: Int
  column: Int
  nulls: List[String] = []
  set: List[String] = []
end

## A read of a pointer that owns.
export struct Use
  name: String
  line: Int
  column: Int
end

## A new value of a pointer that owns, or that may stand for one, and how it got it (`value`): "null"; "owned" (from a
## call that returns owned memory, or any value for a CC_OWNS local); "moved" (from `from`, which owns no more);
## "alias" (an unmarked local that points where `from` does, which still owns); "resized" (from a realloc of `from`,
## which owns again where the new value is null); or "other" (it owns nothing). `shown` names the source, and
## `through` says that the value was written through a CC_FREES parameter (`*p = v`) and goes back to the caller.
export struct Assign
  name: String
  value: String
  from: String
  shown: String
  line: Int
  column: Int
  through: Bool = false
end

## A pointer that owns, handed on outside a call: returned (`word` is "returns"), or stored in a CC_OWNS field or
## global (`word` is "stores p in x->f").
export struct Give
  name: String
  word: String
  line: Int
  column: Int
end

## A point of a path worth naming in a finding: `returns`, `ends`, `case`, `default`, `no case`. `failed` is true for a
## return of an error value (see `error_value?`).
export struct Mark
  word: String
  line: Int
  column: Int
  failed: Bool = false
end

## What happens at a node. `Writes` names the variables a node writes, by key (see `variable_key`), and `Closes` the
## pointers of the blocks that a path leaves (`Closing`).
export enum Event
  Join
  Call(Site)
  Branch(Fact)
  Writes(List[String])
  Note(Mark)
  Exit(Mark)
  Uses(Use)
  Assigns(Assign)
  Gives(Give)
  Lends(List[String])
  Closes(Closing)
end

## The pointers that own, or may stand for one, of the blocks that a path leaves (`names`, by key), and where it leaves
## them (`mark`): the end of a block, or the statement that jumps out. Nothing names them after.
export struct Closing
  names: List[String]
  mark: Mark
end

export struct Node
  event: Event
  next: List[Int]
end

## The graph of one function, at the place of its definition. `owned` are its parameters that own what the caller
## passes, and `owns` says whether the ownership rules read the function: it has a pointer that owns, or calls a
## function that returns one. `releases` are the keys of the locks of its CC_RELEASES in the names of its parameters,
## in the order of its marks ("" for the restore of a pair), and `acquires` those of its CC_ACQUIRES ("" for the set
## of a pair).
export struct Body
  key: String
  name: String
  file: String
  line: Int
  column: Int
  nodes: List[Node]
  owned: List[String] = []
  owns: Bool = false
  releases: List[String] = []
  acquires: List[String] = []
end

## A lock of a CC_ACQUIRES (`takes`) or a CC_RELEASES, as written, with the names of the parameters of the
## declaration that carries it; or the lock of a CC_PAIR that a set takes and its restore (`pair`) releases.
export struct Annotated
  text: String
  params: List[String]
  takes: Bool
  class: String = ""
  pair: String = ""
  through: Bool = false
end

## What a function of the translation unit says about locks, from all its declarations, and whether it never returns.
export struct Callee
  locks: List[Annotated]
  stops: Bool
end

## What the functions of a translation unit say about ownership: the keys of those that return an owned pointer
## (CC_OWNS on the function), their parameters that take (CC_OWNS) or free (CC_FREES) what a call passes, by index,
## those that hand an owned pointer out to the caller (`outs`, CC_OWNS_OUT), and the fields (by id) and the globals
## (by the ids of their declarations) that own what is stored in them. `unions` are those of the fields that belong
## to a union.
export struct Owning
  returns: Set[String]
  takes: Map[String, List[Int]]
  frees: Map[String, List[Int]]
  outs: Map[String, List[Int]]
  fields: Set[String]
  globals: Set[String]
  unions: Set[String]
end

## What the graphs of one translation unit need: the functions that say something about locks, by key, the keys of
## its static functions by name, the class of each field by id (`queue.mu`), the class of each global variable by
## the id of its declaration (its name, `name@file` for a static one), so a local of the same name is not it, and
## what its functions say about ownership.
export struct Context
  callees: Map[String, Callee]
  statics: Map[String, String]
  fields: Map[String, String]
  globals: Map[String, String]
  owning: Owning
end

# An argument of a call: its text, its class when it is a lock, and the pointer that owns it names (`p`, `&p`, `*p`).
struct Arg
  text: String
  class: String
  owner: String = ""
  address: Bool = false
  through: Bool = false
end

# A block (or a `for` with its declarations): its id, the cleanup calls of its variables so far, in the order they were
# declared, and the keys of its pointers that own or may stand for one (`declared`). The block of a statement
# expression keeps the pending pointers of the statement around it (`outer`), which its own statements do not close.
struct Scope
  id: String
  cleanups: List[Site]
  declared: List[String] = []
  outer: List[String] = []
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
  owners: Owners
  # The pointers of the statement expressions of the statement being built: they close at its end (`flushed`).
  pending: List[String] = []
end

# The places of a function that keep an owned pointer stored in them: its parameters and local variables (`locals`),
# `*p` of a parameter that frees it only (`freed`, CC_FREES) or that hands an owned pointer out to the caller (`outs`,
# CC_OWNS_OUT; `out[i]` too), and an item of a pointer whose items own what is stored in them (`arrays`: the pointers
# that own or stand for one, and the locals that get the value of an allocation). The sets hold the keys of the
# variables (`variable_key`), and `keys` gives the key of each variable the function declares, by the id of its
# declaration, and of each `p.f` of a CC_OWNS field of a local struct it follows, by the id of the expression
# (`owned_fields`). `fields` are the keys of those fields of each such struct, by the key of the struct.
struct Places
  locals: Set[String]
  freed: Set[String]
  outs: Set[String]
  arrays: Set[String]
  keys: Map[String, String]
  fields: Map[String, List[String]] = {}
end

# The pointers of a function that own or may stand for one that does, by name (`names`): its parameters that own
# (`params`), its locals marked CC_OWNS (`marked`), and the locals that get an owned value, a pointer of one of them,
# or what a call hands out through their address. `places` are where a store hands a pointer on, `kept` the ids of
# the calls of a function that returns an owned pointer whose value is kept (in a local, a CC_OWNS place, a return or
# a parameter that takes it), and `calls` whether it calls such a function at all.
struct Owners
  params: List[String]
  places: Places
  names: Set[String]
  marked: Set[String]
  kept: Set[String]
  calls: Bool
end

## A local variable or a parameter that gets a value: at its declaration or in an assignment.
export struct Written
  name: String
  value: Json
end

# A condition that says whether a pointer that owns is null: it is when the condition is `null_if`.
struct NullTest
  name: String
  null_if: Bool
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

## Returns whether the ownership rules read a function definition, whose key is `key`: it has a pointer that owns or
## a parameter that hands one out, or calls a function that returns one or hands one out.
export def owns?(ctx: Context, key: String, node: Json) -> Bool
  if ctx.owning.takes.key?(key) or ctx.owning.frees.key?(key) or ctx.owning.outs.key?(key)
    return true
  end

  return Ast.children(node).any? do |child| owning_node?(ctx, child) end
end

## Returns the graph of a function definition, whose key is `key`.
export def body_of(ctx: Context, key: String, node: Json) -> Body
  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  place = Ast.place_of(node)
  owners = owners_of(ctx, key, node)
  start = Builder(
    ctx: ctx,
    aliases: aliases_of(bodies),
    label_blocks: label_blocks(bodies, []),
    nodes: [Node(event: Event.Join, next: [])],
    scopes: [],
    jumps: [],
    labels: {},
    gotos: [],
    owners: owners,
  )

  built = Built(b: start, exits: [0])
  for body in bodies
    built = statement(built.b, body, built.exits)
    end_place = Ast.end_of(body)
    built = add(built.b, Event.Exit(Mark(word: "ends", line: end_place.line, column: end_place.column)), built.exits)
    built = Built(b: built.b, exits: [])
  end

  linked = with_gotos(built.b)
  names = params_named(node)
  dropped = ctx.callees.get(key).map do |callee| callee.locks.select do |lock| not lock.takes end end.unwrap_or([])
  taken = ctx.callees.get(key).map do |callee| callee.locks.select do |lock| lock.takes end end.unwrap_or([])
  return Body(
    key: key,
    name: Ast.text(node, "name"),
    file: place.file,
    line: place.line,
    column: place.column,
    nodes: linked.nodes,
    owned: owners.params,
    owns: owners.calls or not owners.names.empty?,
    releases: dropped.map do |lock| released_key(lock, names) end,
    acquires: taken.map do |lock| released_key(lock, names) end,
  )
end

## Returns the lock text of an annotation (`q->mu`) for a call that passes `args`, the texts of its arguments, to a
## function whose parameters are `params`; "" when the lock names a parameter that the call passes no text for.
export def substituted(lock: String, params: List[String], args: List[String]) -> String
  whole = lock.replace(" ", "")
  marks = 0
  while marks < whole.length and ["&", "*"].include?(whole.slice(marks, 1))
    marks += 1
  end

  prefix = whole.slice(0, marks)
  written = whole.slice(marks, whole.length - marks)

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

## Returns whether a declaration is marked CC_OWNS.
export def marked_owner?(node: Json) -> Bool
  return Ast.children(node).any? do |child|
    Ast.kind(child) == "DeprecatedAttr" and Ast.text(child, "message") == OWNS_MARK
  end
end

## Returns the values that the local variables and the parameters (`locals`, by key) get among the nodes `all`: at
## their declaration and in a plain assignment.
export def writes_of(all: List[Json], locals: Set[String], keys: Map[String, String]) -> List[Written]
  found: List[Written] = []
  for n in all
    if Ast.kind(n) == "VarDecl"
      values = Ast.children(n).select do |child| not Ast.kind(child).end_with?("Attr") end
      if values.size == 1
        found = found.push(Written(name: declared_key(keys, n), value: values.first))
      end
    elsif Ast.kind(n) == "BinaryOperator" and Ast.text(n, "opcode") == "="
      parts = Ast.children(n)
      name = variable_key(keys, parts.first)
      if locals.include?(name)
        found = found.push(Written(name: name, value: parts[1]))
      end
    end
  end

  return found
end

## Returns whether an expression is a call of a function that returns an owned pointer (CC_OWNS on the function).
export def owning_call?(ctx: Context, node: Json) -> Bool
  bare = see_through(node)
  if Ast.kind(bare) != "CallExpr"
    return false
  end

  name = callee_name(bare)
  return name != "" and ctx.owning.returns.include?(key_of_function(ctx, name))
end

## Returns the name of the local variable or the parameter that an expression is, through casts and parentheses; ""
## for any other.
export def variable_name(node: Json) -> String
  bare = see_through(node)
  if Ast.kind(bare) == "DeclRefExpr" and VARIABLES.include?(Ast.referenced_kind(bare))
    return Ast.referenced_name(bare)
  end

  return ""
end

## Returns the key of the local variable or parameter that an expression is, through casts and parentheses: the key
## that `keys` gives its declaration; "" for any other expression, and for a variable the function does not declare (a
## global). Two variables of one function never share a key, so a local that shadows another has a state of its own.
## A CC_OWNS field of a local struct that the rules follow (`p.left`) has the key that `keys` gives the expression.
export def variable_key(keys: Map[String, String], node: Json) -> String
  bare = see_through(node)
  if Ast.kind(bare) == "DeclRefExpr" and VARIABLES.include?(Ast.referenced_kind(bare))
    return keys.get(Ast.referenced_id(bare), "")
  end

  if Ast.kind(bare) == "MemberExpr"
    return keys.get(Ast.text(bare, "id"), "")
  end

  return ""
end

## Returns the key of a variable at its declaration (see `variable_key`).
export def declared_key(keys: Map[String, String], decl: Json) -> String
  return keys.get(Ast.text(decl, "id"), Ast.text(decl, "name"))
end

## Returns the name that a key stands for: what the code calls the variable (`p` for `p#2`, `p.left` for `p#2.left`).
export def plain(key: String) -> String
  parts = key.split(KEY_MARK)
  if parts.size < 2
    return key
  end

  rest = parts[1]
  digits = 0
  while digits < rest.length and DIGITS.include?(rest.slice(digits, 1))
    digits += 1
  end

  return parts[0] + rest.slice(digits, rest.length - digits)
end

## Returns every node under the given ones, each before the nodes inside it.
export def descendants(nodes: List[Json]) -> List[Json]
  found: List[Json] = []
  for node in nodes
    found = with_descendants(found, node)
  end

  return found
end

## Returns an expression without the casts and parentheses around it.
export def see_through(node: Json) -> Json
  bare = node
  while SEE_THROUGH.include?(Ast.kind(bare)) and not Ast.children(bare).empty?
    bare = Ast.children(bare).first
  end

  return bare
end

## Returns the name of the function that a call names, or "" for a call through a pointer.
export def callee_name(node: Json) -> String
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

## Returns the key of a function of the unit by name: `name@file` for a static one.
export def key_of_function(ctx: Context, name: String) -> String
  return ctx.statics.get(name).unwrap_or(name)
end

## Returns whether a returned value is an error by the usual C convention: a negative integer constant (or a negated
## enum constant), a null pointer constant, or a false bool, by the type after typedefs. Any other value, 0 of an int
## and a variable included, may be a success.
export def error_value?(node: Json) -> Bool
  type_node = JSON.get(node, "type").unwrap_or(JSON.from(""))
  type = Ast.text(type_node, "desugaredQualType")
  if type == ""
    type = Ast.text(type_node, "qualType")
  end

  type = unqualified(type)
  bare = see_through(node)
  if type.end_with?("*") or type == "_Bool" or type == "bool"
    return (
      zero?(node) or
      Ast.kind(bare) == "CXXNullPtrLiteralExpr" or
      (Ast.kind(bare) == "CXXBoolLiteralExpr" and not Ast.flag?(bare, "value"))
    )
  end

  if Ast.kind(bare) != "UnaryOperator" or Ast.text(bare, "opcode") != "-" or Ast.children(bare).empty?
    return false
  end

  value = see_through(Ast.children(bare).first)
  constant = Ast.kind(value) == "DeclRefExpr" and Ast.referenced_kind(value) == "EnumConstantDecl"
  return constant or (Ast.kind(value) == "IntegerLiteral" and Ast.text(value, "value") != "0")
end

## Returns whether an expression is the constant 0, through casts and parentheses.
export def zero?(node: Json) -> Bool
  bare = see_through(node)
  return Ast.kind(bare) == "IntegerLiteral" and Ast.text(bare, "value") == "0"
end

## Returns a type without the qualifiers at its end, and out of `_Atomic(...)`: `char *` for `char *const volatile`.
## clang writes no space between the star and the qualifier.
export def unqualified(type: String) -> String
  text = type.strip
  if text.start_with?("_Atomic(") and text.end_with?(")")
    return unqualified(text.slice(8, text.length - 9))
  end

  for word in ["const", "volatile", "restrict", "__restrict"]
    if text.end_with?(" #{word}") or text.end_with?("*#{word}")
      return unqualified(text.slice(0, text.length - word.length))
    end
  end

  return text
end

## Returns the names of the parameters of a function definition, whose key is `key`, that own what the caller passes
## (CC_OWNS or CC_FREES), in the order of the parameters.
export def owned_params(ctx: Context, key: String, node: Json) -> List[String]
  names = params_named(node)
  indices = ctx.owning.takes.get(key, []).concat(ctx.owning.frees.get(key, [])).uniq.sort
  return indices.select do |i| i < names.size end.map do |i| names[i] end
end

## Returns the names of the parameters of a function, in order.
export def params_named(node: Json) -> List[String]
  return Ast.children(node)
    .select do |child| Ast.kind(child) == "ParmVarDecl" end
    .map do |child| Ast.text(child, "name") end
end

# The pointers of a function that own, or may stand for one that does. A local is one when it gets an owned value (a
# call of a function that returns one, or a realloc of a pointer that owns) or a pointer that owns; the walk tells at
# each point whether it owns.
def owners_of(ctx: Context, key: String, node: Json) -> Owners
  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  all = descendants(bodies)
  names_of_params = params_named(node)
  params = owned_params(ctx, key, node)
  takes = ctx.owning.takes.get(key, [])
  freed = Set.new(
    ctx.owning
      .frees
      .get(key, [])
      .select do |i| i < names_of_params.size and not takes.include?(i) end
      .map do |i| names_of_params[i] end,
  )

  declared = keys_of(node, all)
  fields = owned_fields(ctx, all, declared)
  keys = declared
  places_of: Map[String, List[String]] = {}
  for id in fields.keys
    keys = keys.put(id, fields[id])
    owner = fields[id].split(".").first
    if not places_of.get(owner, []).include?(fields[id])
      places_of = places_of.put(owner, places_of.get(owner, []).push(fields[id]))
    end
  end

  decls = all.select do |n| Ast.kind(n) == "VarDecl" end
  locals = Set.new(
    names_of_params.concat(
      decls.select do |n| Ast.text(n, "storageClass") != "static" end.map do |n| declared_key(keys, n) end,
    ),
  )

  marked = Set.new(
    decls.select do |n| marked_owner?(n) and Ast.text(n, "storageClass") != "static" end
      .map do |n| declared_key(keys, n) end,
  ).union(Set.new(fields.values))

  outs = Set.new(
    ctx.owning.outs.get(key, []).select do |i| i < names_of_params.size end.map do |i| names_of_params[i] end,
  )

  written = writes_of(all, locals, keys)
  names = Set.new(params).union(marked).union(filled_locals(ctx, all, locals, keys))
  grew = true
  while grew
    grew = false
    for w in written
      if not names.include?(w.name) and gets_owner?(ctx, keys, names, freed, w.value)
        names = names.add(w.name)
        grew = true
      end
    end
  end

  allocated = written.select do |w| allocation?(w.value) end.map do |w| w.name end
  places = Places(
    locals: locals,
    freed: freed,
    outs: outs,
    arrays: names.union(outs).union(Set.new(allocated)),
    keys: keys,
    fields: places_of,
  )

  return Owners(
    params: params,
    places: places,
    names: names,
    marked: marked,
    kept: kept_calls(ctx, all, places),
    calls: all.any? do |n| owning_call?(ctx, n) end,
  )
end

# Whether an expression is a call of an allocator (`malloc`, `calloc`, ...), through casts and parentheses.
def allocation?(node: Json) -> Bool
  bare = see_through(node)
  return Ast.kind(bare) == "CallExpr" and Known.OWNED.include?(callee_name(bare))
end

# The locals whose address a call passes to a parameter that hands an owned pointer out (`fill(&p)`).
def filled_locals(ctx: Context, all: List[Json], locals: Set[String], keys: Map[String, String]) -> Set[String]
  found: Set[String] = Set.new([])
  for n in all
    if Ast.kind(n) == "CallExpr"
      args = Ast.children(n).drop(1)
      for i in out_params(ctx, callee_name(n))
        if i < args.size and address?(args[i])
          name = variable_key(keys, Ast.children(see_through(args[i])).first)
          if locals.include?(name)
            found = found.add(name)
          end
        end
      end
    end
  end

  return found
end

# The indices of the parameters of a function, by name, that hand an owned pointer out to the caller.
def out_params(ctx: Context, name: String) -> List[Int]
  if name == ""
    return []
  end

  return ctx.owning.outs.get(key_of_function(ctx, name), [])
end

# Whether a node is or holds a local marked CC_OWNS, a call of a function that returns an owned pointer, or a call of
# one that hands an owned pointer out through a parameter.
def owning_node?(ctx: Context, node: Json) -> Bool
  if (Ast.kind(node) == "VarDecl" and marked_owner?(node)) or owning_call?(ctx, node)
    return true
  end

  if struct_of(node) != "" and ctx.owning.fields.include?(Ast.text(node, "referencedMemberDecl"))
    return true
  end

  if Ast.kind(node) == "CallExpr" and not out_params(ctx, callee_name(node)).empty?
    return true
  end

  return Ast.children(node).any? do |child| owning_node?(ctx, child) end
end

# Whether a value makes the variable that gets it stand for an owned pointer: a call that returns one, a realloc of a
# pointer in `names`, or a pointer in `names` (`*p` of a CC_FREES parameter in `freed` is `p`).
def gets_owner?(ctx: Context, keys: Map[String, String], names: Set[String], freed: Set[String], value: Json) -> Bool
  if CHOICES.include?(Ast.kind(see_through(value)))
    return values_of(value).any? do |branch| gets_owner?(ctx, keys, names, freed, branch) end
  end

  if names.include?(variable_key(keys, value)) or pointee_param(keys, value, freed) != "" or owning_call?(ctx, value)
    return true
  end

  bare = see_through(value)
  parts = Ast.children(bare)
  return (
    Ast.kind(bare) == "CallExpr" and
    Known.RESIZES.include?(callee_name(bare)) and
    parts.size > 1 and
    names.include?(variable_key(keys, parts[1]))
  )
end

# The calls of a function that returns an owned pointer whose value is kept: in a local or a parameter, in a CC_OWNS
# field or global, in a return, in a place of `places` (`*out`, `argv[i]`), or in an argument that the called
# function takes or frees. Any other is lost.
def kept_calls(ctx: Context, all: List[Json], places: Places) -> Set[String]
  kept: Set[String] = Set.new([])
  for n in all
    parts = Ast.children(n)
    values: List[Json] = []
    case Ast.kind(n)
      "VarDecl" -> values = parts.select do |child| not Ast.kind(child).end_with?("Attr") end
      "ReturnStmt" -> values = parts
      "BinaryOperator" ->
        target = parts[0]
        keeps = (
          places.locals.include?(variable_key(places.keys, target)) or
          place_owns?(ctx, target) or
          pointee_param(places.keys, target, places.freed) != "" or
          handed_place?(places, target)
        )

        if Ast.text(n, "opcode") == "=" and keeps
          values = parts.drop(1)
        end

      "CallExpr" ->
        name = callee_name(n)
        taking = taken(ctx, name, key_of_function(ctx, name))
        for i in 1...parts.size
          if taking.include?(i - 1)
            values = values.push(parts[i])
          end
        end

      _ -> next
    end

    for value in values.flat_map(&values_of)
      if owning_call?(ctx, value)
        kept = kept.add(Ast.text(see_through(value), "id"))
      end
    end
  end

  return kept
end

# The values an expression may have: each side of `?:` (`x ?: y` is `x` or `y`), the last expression of a statement
# expression, or itself.
def values_of(node: Json) -> List[Json]
  bare = see_through(node)
  if Ast.kind(bare) == "ConditionalOperator"
    return Ast.children(bare).drop(1).flat_map(&values_of)
  end

  if Ast.kind(bare) == "BinaryConditionalOperator"
    parts = Ast.children(bare)
    return values_of(parts.first).concat(values_of(parts.last))
  end

  if Ast.kind(bare) == "StmtExpr"
    return values_of(last_child(last_child(bare)))
  end

  return [node]
end

# The key of each variable that a function declares (its parameters, then its locals in the order of the source), by
# the id of its declaration: its name, or `name#2`, `name#3` for a variable whose name an earlier one has, or a name
# that the function reads and does not declare (a global: it keeps its name).
def keys_of(node: Json, all: List[Json]) -> Map[String, String]
  params = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
  decls = params.concat(all.select do |n| VARIABLES.include?(Ast.kind(n)) end)
  ids = Set.new(decls.map do |decl| Ast.text(decl, "id") end)
  seen: Map[String, Int] = {}
  for n in all
    if Ast.kind(n) == "DeclRefExpr" and not ids.include?(Ast.referenced_id(n))
      seen = seen.put(Ast.referenced_name(n), 1)
    end
  end

  keys: Map[String, String] = {}
  for decl in decls
    name = Ast.text(decl, "name")
    count = seen.get(name, 0) + 1
    seen = seen.put(name, count)
    key = name
    if count > 1
      key = "#{name}#{KEY_MARK}#{count}"
    end

    keys = keys.put(Ast.text(decl, "id"), key)
  end

  return keys
end

# The CC_OWNS fields of the local structs that a function reads and writes only field by field (`p.left`), by the id
# of each such expression: the key of the struct (`keys`), a dot and the name of the field. A struct that the function
# copies, passes, returns or names in any other way, whose address or the address of a field it takes, a static one
# and a union are not followed: a store into their CC_OWNS fields hands the pointer on.
def owned_fields(ctx: Context, all: List[Json], keys: Map[String, String]) -> Map[String, String]
  found: Map[String, String] = {}
  if ctx.owning.fields.empty?
    return found
  end

  structs: Set[String] = Set.new([])
  refs: Map[String, Int] = {}
  members: Map[String, Int] = {}
  escaped: Set[String] = Set.new([])
  for n in all
    kind = Ast.kind(n)
    if kind == "VarDecl"
      if Ast.text(n, "storageClass") == ""
        structs = structs.add(Ast.text(n, "id"))
      end
    elsif kind == "DeclRefExpr"
      refs = refs.put(Ast.referenced_id(n), refs.get(Ast.referenced_id(n), 0) + 1)
    elsif kind == "MemberExpr"
      base = struct_of(n)
      members = members.put(base, members.get(base, 0) + 1)
    elsif kind == "UnaryOperator" and Ast.text(n, "opcode") == "&"
      escaped = escaped.add(struct_of(see_through(Ast.children(n).first)))
    end
  end

  for n in all
    base = struct_of(n)
    followed = (
      base != "" and
      structs.include?(base) and
      not escaped.include?(base) and
      refs.get(base, 0) == members.get(base, 0) and
      ctx.owning.fields.include?(Ast.text(n, "referencedMemberDecl")) and
      not ctx.owning.unions.include?(Ast.text(n, "referencedMemberDecl"))
    )

    if followed
      found = found.put(Ast.text(n, "id"), "#{keys.get(base, "")}.#{Ast.text(n, "name")}")
    end
  end

  return found
end

# The id of the local variable whose field an expression is (`p.left`, not `p->left`); "" for any other.
def struct_of(node: Json) -> String
  if Ast.kind(node) != "MemberExpr" or Ast.flag?(node, "isArrow")
    return ""
  end

  base = see_through(Ast.children(node).first)
  if Ast.kind(base) != "DeclRefExpr" or Ast.referenced_kind(base) != "VarDecl"
    return ""
  end

  return Ast.referenced_id(base)
end

# The key of what a reference names: the key of a variable of the function, else the name (a global, a function, an
# enum constant), which no key of the function has. Conditions and writes name variables so.
def referenced_key(keys: Map[String, String], ref: Json) -> String
  return keys.get(Ast.referenced_id(ref), Ast.referenced_name(ref))
end

# The indices of the parameters of a function that take or free what a call passes: CC_OWNS and CC_FREES, the first
# of `free`, and the first of a realloc, which moves it.
def taken(ctx: Context, name: String, key: String) -> List[Int]
  return freed(ctx, name, key).concat(handed(ctx, name, key))
end

def freed(ctx: Context, name: String, key: String) -> List[Int]
  indices = ctx.owning.frees.get(key, [])
  if Known.FREES.include?(name)
    indices = indices.push(0)
  end

  return indices
end

def handed(ctx: Context, name: String, key: String) -> List[Int]
  indices = ctx.owning.takes.get(key, [])
  if Known.RESIZES.include?(name)
    indices = indices.push(0)
  end

  return indices
end

# Whether a store into an expression hands a pointer on: a CC_OWNS field (`x->held`), an item of one
# (`x->items[i]`), or a CC_OWNS global.
def place_owns?(ctx: Context, node: Json) -> Bool
  bare = see_through(node)
  case Ast.kind(bare)
    "MemberExpr" -> return ctx.owning.fields.include?(Ast.text(bare, "referencedMemberDecl"))
    "ArraySubscriptExpr" -> return place_owns?(ctx, Ast.children(bare).first)
    "DeclRefExpr" -> return ctx.owning.globals.include?(Ast.referenced_id(bare))
    _ -> return false
  end
end

# Whether a store into an expression of a function hands a pointer on to a place that `places` names: `*out` of a
# parameter that hands an owned pointer out, or an item of a pointer whose items own (`argv[i]`).
def handed_place?(places: Places, node: Json) -> Bool
  if pointee_param(places.keys, node, places.outs) != ""
    return true
  end

  bare = see_through(node)
  return (
    Ast.kind(bare) == "ArraySubscriptExpr" and
    places.arrays.include?(variable_key(places.keys, Ast.children(bare).first))
  )
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
      written = written.add(target_root({}, Ast.children(node).first))
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

# The blocks (and the `for` loops, a scope of their own) around each label, by the id of the label's declaration, from
# the outermost.
def label_blocks(nodes: List[Json], around: List[String]) -> Map[String, List[String]]
  found: Map[String, List[String]] = {}
  for node in nodes
    inner = around
    if Ast.kind(node) == "CompoundStmt" or Ast.kind(node) == "ForStmt"
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
    "BreakStmt" -> return break_statement(b, node, preds)
    "ContinueStmt" -> return continue_statement(b, node, preds)
    "ReturnStmt" -> return return_statement(b, node, preds)
    "GotoStmt" -> return goto_statement(b, node, Ast.text(node, "targetLabelDeclId"), preds)
    "IndirectGotoStmt" -> return goto_statement(b, node, "", preds)
    "LabelStmt" ->
      label = add(b, Event.Join, preds)
      labelled = label.b.with(labels: label.b.labels.put(Ast.text(node, "declId"), label.exits.first))
      return statement(labelled, last_child(node), label.exits)
    "AttributedStmt" -> return statement(b, last_child(node), preds)
    "DeclStmt" ->
      declared = declarations(b, node, preds)
      return flushed(declared.b, node, declared.exits)
    "NullStmt" -> return Built(b: b, exits: preds)
    "GCCAsmStmt" -> return Built(b: b, exits: preds)
    _ ->
      done = expression(b, node, preds)
      return flushed(done.b, node, done.exits)
  end
end

# The end of a full statement (`node`): the pointers of its statement expressions close there (`pending`). One that a
# variable still stands for stays, so they close again with the block around the statement, where that variable may
# close with them.
def flushed(b: Builder, node: Json, preds: List[Int]) -> Built
  if b.pending.empty?
    return Built(b: b, exits: preds)
  end

  scopes = b.scopes
  if not scopes.empty?
    scope = scopes.last
    added = b.pending.select do |name| not scope.declared.include?(name) end
    scopes = scopes.set(scopes.size - 1, scope.with(declared: scope.declared.concat(added)))
  end

  place = Ast.end_of(node)
  mark = Mark(word: "ends", line: place.line, column: place.column)
  return closes_at(b.with(pending: [], scopes: scopes), b.pending, mark, preds)
end

# `flushed` on both sides of a condition (`node`) of a statement.
def flushed_split(split: Split, node: Json) -> Split
  yes = flushed(split.b, node, split.yes)
  no = flushed(yes.b.with(pending: split.b.pending), node, split.no)
  return Split(b: no.b, yes: yes.exits, no: no.exits)
end

# A close of the pointers `names` at `mark` after `preds`; nothing for no names, or no node before it.
def closes_at(b: Builder, names: List[String], mark: Mark, preds: List[Int]) -> Built
  if names.empty? or preds.empty?
    return Built(b: b, exits: preds)
  end

  return add(b, Event.Closes(Closing(names: names, mark: mark)), preds)
end

# The block of a statement expression `({ ...; v; })` opens as a scope for the cleanups of its variables.
def opened_expression(b: Builder, node: Json) -> Builder
  scope = Scope(id: Ast.text(last_child(see_through(node)), "id"), cleanups: [], outer: b.pending)
  return b.with(scopes: b.scopes.push(scope), pending: [])
end

# The end of the block of a statement expression: the cleanups of its variables run, and its pointers close at the end
# of the statement around it (`pending`), as its value outlives the block.
def closed_expression(b: Builder, preds: List[Int]) -> Built
  scope = b.scopes.last
  called = calls(b, scope.cleanups.reverse, preds)
  return Built(
    b: called.b.with(
      scopes: called.b.scopes.take(called.b.scopes.size - 1),
      pending: scope.outer.concat(called.b.pending).concat(scope.declared),
    ),
    exits: called.exits,
  )
end

def block(b: Builder, node: Json, preds: List[Int]) -> Built
  opened = b.with(scopes: b.scopes.push(Scope(id: Ast.text(node, "id"), cleanups: [])))
  built = Built(b: opened, exits: preds)
  for child in Ast.children(node)
    built = statement(built.b, child, built.exits)
  end

  return closed(built.b, node, built.exits)
end

# The way out of the innermost scope (`node`) at its end: its cleanup calls, the close of its pointers, and the scope
# gone.
def closed(b: Builder, node: Json, preds: List[Int]) -> Built
  place = Ast.end_of(node)
  left = leaving(b, b.scopes.size - 1, preds, some(Mark(word: "ends", line: place.line, column: place.column)))
  return Built(b: left.b.with(scopes: left.b.scopes.take(left.b.scopes.size - 1)), exits: left.exits)
end

# An `if` and the `else if` chain after it, in a loop: a recursion would keep every builder of the chain alive.
def if_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  current = node
  built = b
  pending = preds
  exits: List[Int] = []
  while true
    parts = Ast.children(current)
    split = flushed_split(condition(built, parts[0], pending), parts[0])
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
  split = flushed_split(condition(head.b, parts[0], head.exits), parts[0])
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
  split = flushed_split(condition(test.b, parts[1], test.exits), parts[1])
  return Built(b: link(split.b, split.yes, head.exits.first), exits: split.no.concat(jump.breaks))
end

def for_loop(b: Builder, node: Json, preds: List[Int]) -> Built
  # The parts are the init, a C++ condition variable, the condition, the increment and the body; a missing one is an
  # empty node. The variables of the init live until the loop ends, as in a block.
  parts = Ast.children(node)
  opened = b.with(scopes: b.scopes.push(Scope(id: Ast.text(node, "id"), cleanups: [])))
  init = statement(opened, parts[0], preds)
  head = add(init.b, Event.Join, init.exits)
  split = Split(b: head.b, yes: head.exits, no: [])
  if Ast.kind(parts[2]) != ""
    split = flushed_split(condition(head.b, parts[2], head.exits), parts[2])
  end

  ran = looped(split.b, parts[4], split, head.exits.first, parts[3])
  return closed(ran.b, node, ran.exits)
end

# The body of a `while` or a `for` from the true side of its condition, then the increment (an empty node for a
# `while`), back to the head.
def looped(b: Builder, body: Json, split: Split, head: Int, increment: Json) -> Built
  opened = b.with(jumps: b.jumps.push(loop_jump(b, head)))
  ran = statement(opened, body, split.yes)
  jump = ran.b.jumps.last
  closed = ran.b.with(jumps: ran.b.jumps.take(ran.b.jumps.size - 1))
  ran_increment = expression(closed, increment, ran.exits.concat(jump.continues))
  stepped = flushed(ran_increment.b, increment, ran_increment.exits)
  return Built(b: link(stepped.b, stepped.exits, head), exits: split.no.concat(jump.breaks))
end

def loop_jump(b: Builder, head: Int) -> Jump
  return Jump(switch: false, head: head, depth: b.scopes.size, breaks: [], continues: [], defaulted: false)
end

# A switch jumps from its head to each `case` and `default` of its body; without a `default`, a value that no case
# names goes past the body.
def switch_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  evaluated = expression(b, parts[0], preds)
  value = flushed(evaluated.b, parts[0], evaluated.exits)
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

def break_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  at = innermost(b.jumps, false)
  if at < 0
    return Built(b: b, exits: [])
  end

  left = leaving(b, b.jumps[at].depth, preds, some(mark_at(node, "break")))
  jump = left.b.jumps[at]
  return Built(
    b: left.b.with(jumps: left.b.jumps.set(at, jump.with(breaks: jump.breaks.concat(left.exits)))),
    exits: [],
  )
end

def continue_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  at = innermost_loop(b.jumps)
  if at < 0
    return Built(b: b, exits: [])
  end

  left = leaving(b, b.jumps[at].depth, preds, some(mark_at(node, "continue")))
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
    value = returned(value.b, child, value.exits)
  end

  failed = Ast.children(node).any?(&error_value?)
  mark = mark_at(node, "returns").with(failed: failed)
  left = leaving(value.b, 0, value.exits, some(mark))
  ended = add(left.b, Event.Exit(mark), left.exits)
  return Built(b: ended.b.with(pending: []), exits: [])
end

# The value of a return: a pointer that owns is handed on, also as the value of a statement expression.
def returned(b: Builder, value: Json, preds: List[Int]) -> Built
  bare = see_through(value)
  statements = Ast.children(last_child(bare))
  if Ast.kind(bare) == "StmtExpr" and not statements.empty?
    opened = opened_expression(b, bare)
    built = in_order_statements(opened, statements.take(statements.size - 1), preds)
    last = returned(built.b, statements.last, built.exits)
    return closed_expression(last.b, last.exits)
  end

  given = owner_named(b, value)
  if given == ""
    return expression(b, value, preds)
  end

  place = Ast.start_of(value)
  return add(b, Event.Gives(Give(name: given, word: "returns", line: place.line, column: place.column)), preds)
end

# A `goto` leaves the blocks that are not around its label. The label is linked at the end, when every label is known;
# an indirect `goto` ("") may go to any label, so it closes no block: the pointers of each may still be read there.
def goto_statement(b: Builder, node: Json, label: String, preds: List[Int]) -> Built
  around = Set.new(b.label_blocks.get(label).unwrap_or([]))
  depth = 0
  while depth < b.scopes.size and around.include?(b.scopes[depth].id)
    depth += 1
  end

  mark: Optional[Mark] = none
  if label != ""
    mark = some(mark_at(node, "goto"))
  end

  left = leaving(b, depth, preds, mark)
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

# The way out of the blocks from `depth` in: their cleanup calls, the innermost first, then one close of their pointers
# and of the pending ones of the statements left (`pending`, and `outer` of a statement expression) at `at` (none
# closes nothing), which lets the walks drop what they knew of them. The pending ones stay for the path that does not
# jump. The block of the function never closes: the exit of the path reads its pointers.
def leaving(b: Builder, depth: Int, preds: List[Int], at: Optional[Mark]) -> Built
  sites: List[Site] = []
  names: List[String] = []
  i = b.scopes.size - 1
  while i >= depth
    sites = sites.concat(b.scopes[i].cleanups.reverse)
    if i > 0
      names = names.concat(b.scopes[i].declared)
    end

    # A jump out of a statement expression leaves the statement around it too: its pending pointers close here.
    names = names.concat(b.scopes[i].outer)

    i -= 1
  end

  called = calls(b, sites, preds)
  case at
    some(mark) -> return closes_at(called.b, b.pending.concat(names), mark, called.exits)
    none -> return called
  end
end

# A mark at the start of a statement.
def mark_at(node: Json, word: String) -> Mark
  place = Ast.start_of(node)
  return Mark(word: word, line: place.line, column: place.column)
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
  key = declared_key(b.owners.places.keys, node)
  values = Ast.children(node).select do |child| not Ast.kind(child).end_with?("Attr") end
  written = Built(b: b, exits: preds)
  if b.owners.names.include?(key) and values.size == 1
    written = owner_assigned(b, key, values.first, preds)
  else
    built = in_order(b, values, preds)
    written = add(built.b, Event.Writes([key]), built.exits)
  end

  # The pointers of the block: the variable, or the followed CC_OWNS fields of a struct.
  closing = written.b.owners.places.fields.get(key, [])
  if written.b.owners.names.include?(key)
    closing = [key]
  end

  if not closing.empty? and not written.b.scopes.empty?
    scope = written.b.scopes.last
    scopes = written.b.scopes.set(written.b.scopes.size - 1, scope.with(declared: scope.declared.concat(closing)))
    written = Built(b: written.b.with(scopes: scopes), exits: written.exits)
  end

  cleanup = Ast.children(node).select do |child| Ast.kind(child) == "CleanupAttr" end
  if cleanup.empty? or written.b.scopes.empty?
    return written
  end

  function = Ast.text(JSON.get(cleanup.first, "cleanup_function").unwrap_or(JSON.from("")), "name")
  place = Ast.place_of(node)
  owner = ""
  if written.b.owners.names.include?(key)
    owner = key
  end

  var = Arg(
    text: "&#{local_text(written.b, name)}",
    class: written.b.aliases.get(name).map do |value| class_of(written.b, value) end.unwrap_or(""),
    owner: owner,
    address: true,
  )

  site = site_of(written.b, function, [var], place, false)
  scope = written.b.scopes.last
  scopes = written.b.scopes.set(written.b.scopes.size - 1, scope.with(cleanups: scope.cleanups.push(site)))
  return Built(b: written.b.with(scopes: scopes), exits: written.exits)
end

def expression(b: Builder, node: Json, preds: List[Int]) -> Built
  case Ast.kind(node)
    "" -> return Built(b: b, exits: preds)
    "CallExpr" -> return call(b, node, preds, false)
    "DeclRefExpr" -> return used(b, node, preds)
    "MemberExpr" ->
      if owner_named(b, node) != ""
        return used(b, node, preds)
      end

      return in_order(b, Ast.children(node), preds)
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
      lent = owner_named(b, operand)
      if opcode == "&" and lent != ""
        # `&p` lends the pointer itself, to be set: what it owns after that is not known.
        written = add(b, Event.Writes([lent]), preds)
        return add(written.b, Event.Lends([lent]), written.exits)
      end

      inner = expression(b, operand, preds)
      if opcode == "++" or opcode == "--"
        return add(inner.b, Event.Writes([target_root(b.owners.places.keys, operand)]), inner.exits)
      end

      # The address of a variable lets a callee change it; the address of `q->mu` does not change `q`.
      root = storage_root(b.owners.places.keys, operand)
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
    "StmtExpr" ->
      opened = opened_expression(b, node)
      built = in_order_statements(opened, Ast.children(last_child(node)), preds)
      return closed_expression(built.b, built.exits)
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

# An assignment: the value, then the target. A plain write of a variable does not read it; a pointer that owns gets
# its new value, and one stored in a CC_OWNS place is handed on.
def assignment(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  if Ast.kind(node) == "BinaryOperator" and Ast.text(node, "opcode") == "=" and parts.size == 2
    name = variable_key(b.owners.places.keys, parts[0])
    if b.owners.names.include?(name)
      return owner_assigned(b, name, parts[1], preds)
    end

    # `*p = v` in a CC_FREES parameter that points to the pointer gives the pointer a new value without reading it:
    # null, or a value that goes back to the caller, which the function does not own. A pointer that owns is handed
    # on to the caller there.
    given = owner_named(b, parts[1])
    pointed = pointee_owner(b, parts[0])
    if pointed != ""
      place = Ast.start_of(parts[1])
      assign = Assign(
        name: pointed,
        value: "other",
        from: "",
        shown: text_of(b, parts[1], false),
        line: place.line,
        column: place.column,
        through: true,
      )

      if zero?(parts[1])
        assign = assign.with(value: "null", shown: "NULL")
      end

      value = Built(b: b, exits: preds)
      if given != ""
        give = Give(
          name: given,
          word: "stores #{plain(given)} in *#{plain(pointed)}",
          line: place.line,
          column: place.column,
        )

        value = add(b, Event.Gives(give), preds)
      else
        value = expression(b, parts[1], preds)
      end

      written = add(value.b, Event.Writes([pointed]), value.exits)
      return add(written.b, Event.Assigns(assign), written.exits)
    end

    handing = place_owns?(b.ctx, parts[0]) or handed_place?(b.owners.places, parts[0])
    if handing and values_of(parts[1]).any? do |value| owner_named(b, value) != "" end
      target = expression(b, parts[0], preds)
      gave = stored(target.b, text_of(b, parts[0], false), parts[1], target.exits)
      return add(gave.b, Event.Writes([target_root(b.owners.places.keys, parts[0])]), gave.exits)
    end

    if name != ""
      value = expression(b, parts[1], preds)
      return add(value.b, Event.Writes([name]), value.exits)
    end
  end

  value = in_order(b, parts.drop(1).concat(parts.take(1)), preds)
  return add(value.b, Event.Writes([target_root(b.owners.places.keys, parts.first)]), value.exits)
end

# A value stored in a place that hands it on (`shown`): a pointer that owns is handed on there, on its side of a `?:`
# (`x->held = n ? p : NULL`, `x->held = p ?: q`) or as the last expression of a statement expression, the same values
# as `values_of`.
def stored(b: Builder, shown: String, value: Json, preds: List[Int]) -> Built
  bare = see_through(value)
  if Ast.kind(bare) == "ConditionalOperator"
    parts = Ast.children(bare)
    split = condition(b, parts[0], preds)
    chosen = stored(split.b, shown, parts[1], split.yes)
    other = stored(chosen.b, shown, parts[2], split.no)
    return Built(b: other.b, exits: chosen.exits.concat(other.exits))
  end

  if Ast.kind(bare) == "BinaryConditionalOperator"
    # `x ?: y`: `x`, read once by the condition, where it is true, else `y`.
    parts = Ast.children(bare)
    split = condition(b, parts.first, preds)
    chosen = Built(b: split.b, exits: split.yes)
    if owner_named(b, parts.first) != ""
      chosen = handed_on(split.b, shown, parts.first, split.yes)
    end

    other = stored(chosen.b, shown, parts.last, split.no)
    return Built(b: other.b, exits: chosen.exits.concat(other.exits))
  end

  if Ast.kind(bare) == "StmtExpr"
    statements = Ast.children(last_child(bare))
    if not statements.empty?
      opened = opened_expression(b, bare)
      built = in_order_statements(opened, statements.take(statements.size - 1), preds)
      last = stored(built.b, shown, statements.last, built.exits)
      return closed_expression(last.b, last.exits)
    end
  end

  if owner_named(b, value) == ""
    return expression(b, value, preds)
  end

  return handed_on(b, shown, value, preds)
end

# A pointer that owns, `value`, handed on to the place `shown` by a store.
def handed_on(b: Builder, shown: String, value: Json, preds: List[Int]) -> Built
  given = owner_named(b, value)
  place = Ast.start_of(value)
  give = Give(name: given, word: "stores #{plain(given)} in #{shown}", line: place.line, column: place.column)
  return add(b, Event.Gives(give), preds)
end

# A pointer that owns, or may stand for one, gets a value. A pointer that it moves from is not read.
def owner_assigned(b: Builder, name: String, value: Json, preds: List[Int]) -> Built
  bare = see_through(value)
  if Ast.kind(bare) == "ConditionalOperator"
    # Each side gives its own value: `p = n ? make(n) : NULL` owns where `n` is true only.
    parts = Ast.children(bare)
    split = condition(b, parts[0], preds)
    chosen = owner_assigned(split.b, name, parts[1], split.yes)
    other = owner_assigned(chosen.b, name, parts[2], split.no)
    return Built(b: other.b, exits: chosen.exits.concat(other.exits))
  end

  if Ast.kind(bare) == "BinaryConditionalOperator"
    # `x ?: y`: `x`, read once by the condition, where it is true, else `y`.
    parts = Ast.children(bare)
    split = condition(b, parts.first, preds)
    kept = add(split.b, Event.Writes([name]), split.yes)
    chosen = add(kept.b, Event.Assigns(assigned(kept.b, name, parts.first)), kept.exits)
    other = owner_assigned(chosen.b, name, parts.last, split.no)
    return Built(b: other.b, exits: chosen.exits.concat(other.exits))
  end

  if Ast.kind(bare) == "StmtExpr"
    # `({ char *q = make(n); ...; q; })`: its statements, then the value of the last one.
    statements = Ast.children(last_child(bare))
    if not statements.empty?
      opened = opened_expression(b, bare)
      built = in_order_statements(opened, statements.take(statements.size - 1), preds)
      last = owner_assigned(built.b, name, statements.last, built.exits)
      return closed_expression(last.b, last.exits)
    end
  end

  assign = assigned(b, name, value)
  built = Built(b: b, exits: preds)
  if assign.value != "moved" and assign.value != "alias"
    built = expression(b, value, preds)
  end

  written = add(built.b, Event.Writes([name]), built.exits)
  return add(written.b, Event.Assigns(assign), written.exits)
end

# How a pointer that owns, or may stand for one, gets a value (`Assign`).
def assigned(b: Builder, name: String, value: Json) -> Assign
  place = Ast.start_of(value)
  start = Assign(name: name, value: "other", from: "", shown: "", line: place.line, column: place.column)
  bare = see_through(value)
  marked = b.owners.marked.include?(name)
  if zero?(bare)
    return start.with(value: "null", shown: "NULL")
  end

  source = owner_named(b, bare)
  if source == ""
    source = pointee_owner(b, bare)
  end

  if source != ""
    if marked
      return start.with(value: "moved", from: source, shown: plain(source))
    end

    return start.with(value: "alias", from: source, shown: plain(source))
  end

  if Ast.kind(bare) == "CallExpr"
    called = callee_name(bare)
    parts = Ast.children(bare)
    if Known.RESIZES.include?(called) and parts.size > 1 and owner_of(b, parts[1]) != ""
      return start.with(value: "resized", from: owner_of(b, parts[1]), shown: called)
    end

    # An allocation owns in a pointer marked CC_OWNS (a local or a parameter) only: a local that is not marked tracks
    # the calls of CC_OWNS functions and the pointers it stands for, not what it gets from `malloc`.
    allocates = Known.OWNED.include?(called) and b.owners.params.include?(name)
    if marked or allocates or b.ctx.owning.returns.include?(key_of_function(b.ctx, called))
      return start.with(value: "owned", shown: called)
    end
  end

  if marked
    shown = text_of(b, bare, false)
    if shown == ""
      shown = "a value"
    end

    return start.with(value: "owned", shown: shown)
  end

  return start.with(shown: text_of(b, bare, false))
end

# A read of a variable: an event when it is a pointer that owns, or may stand for one.
def used(b: Builder, node: Json, preds: List[Int]) -> Built
  name = owner_named(b, node)
  if name == ""
    return Built(b: b, exits: preds)
  end

  place = Ast.start_of(node)
  return add(b, Event.Uses(Use(name: name, line: place.line, column: place.column)), preds)
end

# The pointer that owns, or may stand for one, that an expression is, through casts and parentheses; "".
def owner_named(b: Builder, node: Json) -> String
  name = variable_key(b.owners.places.keys, node)
  if b.owners.names.include?(name)
    return name
  end

  return ""
end

# The pointer that owns an argument names: `p`, `&p` (a cleanup function, or a function that frees through a pointer
# to it) or `*p`; "" for none.
def owner_of(b: Builder, node: Json) -> String
  bare = see_through(node)
  if address?(bare)
    return owner_named(b, Ast.children(bare).first)
  end

  pointed = pointee_owner(b, bare)
  if pointed != ""
    return pointed
  end

  return owner_named(b, bare)
end

# Whether an expression takes the address of something: `&x`.
def address?(node: Json) -> Bool
  bare = see_through(node)
  return Ast.kind(bare) == "UnaryOperator" and Ast.text(bare, "opcode") == "&"
end

# The CC_FREES parameter that `*p` stands for when the parameter points to the pointer it frees (`T **p`, a cleanup
# function); "" for any other.
def pointee_owner(b: Builder, node: Json) -> String
  return pointee_param(b.owners.places.keys, node, b.owners.places.freed)
end

# The parameter in `freed` that `*p` is, when `*p` is itself a pointer; "" for any other expression.
def pointee_param(keys: Map[String, String], node: Json, freed: Set[String]) -> String
  bare = see_through(node)
  if Ast.kind(bare) != "UnaryOperator" or Ast.text(bare, "opcode") != "*" or not pointer_type?(bare)
    return ""
  end

  name = variable_key(keys, Ast.children(bare).first)
  if not freed.include?(name)
    return ""
  end

  return name
end

# Whether the type of an expression is a pointer, as written or behind a typedef, `const` or not (`char *const`).
def pointer_type?(node: Json) -> Bool
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  return [Ast.text(type, "qualType"), Ast.text(type, "desugaredQualType")].any? do |text|
    unqualified(text).end_with?("*")
  end
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
  if Ast.kind(callee) != "DeclRefExpr" or Ast.referenced_kind(callee) != "FunctionDecl"
    built = in_order(b, args, preds)
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
      stops: Ast.noreturn_type?(parts.first),
      pointer: true,
    )

    through = add(pointer.b, Event.Call(site), pointer.exits)
    if site.stops
      return Built(b: through.b, exits: [])
    end

    return through
  end

  # A pointer that the call frees or takes is not read by it, nor one whose address it gets to hand an owned pointer
  # out through.
  name = Ast.referenced_name(callee)
  taking = taken(b.ctx, name, key_of_function(b.ctx, name))
  filling = out_params(b.ctx, name)
  built = Built(b: b, exits: preds)
  for i in 0...args.size
    owner = owner_of(b, args[i])
    # `&p` at a CC_OWNS_OUT parameter emits no `Lends`: the call fills `p`, and `after_call` checks that a value it
    # still owned is not lost, which a `Lends` before it would hide.
    set = taking.include?(i) or (filling.include?(i) and address?(args[i]))
    if not (set and owner != "")
      built = expression(built.b, args[i], built.exits)
    elsif address?(args[i])
      # `free_and_null(&p)` may set `p`: a condition on it is forgotten.
      built = add(built.b, Event.Writes([owner]), built.exits)
    end
  end

  # The type of the declaration: the reference to a builtin such as `__builtin_abort` has no type of its own.
  noreturn = Ast.noreturn_type?(JSON.get(callee, "referencedDecl").unwrap_or(JSON.from("")))
  site = site_of(
    built.b,
    Ast.referenced_name(callee),
    args.map do |arg| arg_of(built.b, arg) end,
    Ast.start_of(node),
    noreturn,
  )

  if tried
    site = site.with(takes: [])
  end

  if b.ctx.owning.returns.include?(site.key) and not b.owners.kept.include?(Ast.text(node, "id"))
    site = site.with(lost: true)
  end

  called = add(built.b, Event.Call(site), built.exits)
  if site.stops
    return Built(b: called.b, exits: [])
  end

  return called
end

# What a call does to the locks: a known call takes or drops the lock of its first argument, and a function with
# CC_ACQUIRES or CC_RELEASES the locks it names, in the texts of the arguments of the call.
def site_of(b: Builder, name: String, args: List[Arg], place: Ast.Place, noreturn: Bool) -> Site
  key = key_of_function(b.ctx, name)
  takes: List[Lock] = []
  drops: List[Lock] = []
  waits: List[Lock] = []
  stops = Known.NORETURN.include?(name) or noreturn
  unnamed = false
  if Known.TAKES.include?(name)
    takes = lock_of(args, 0)
    unnamed = not args.empty? and takes.empty?
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
    frees: owners_at(args, freed(b.ctx, name, key)),
    hands: owners_at(args, handed(b.ctx, name, key)),
    clears: owners_at(args.map(&by_address), freed(b.ctx, name, key)),
    fills: owners_at(args.map(&by_address), out_params(b.ctx, name)),
    unnamed: unnamed,
  )

  case b.ctx.callees.get(key)
    some(callee) ->
      texts = args.map do |arg| arg.text end
      taken = callee.locks.select do |lock| lock.takes end
      dropped = callee.locks.select do |lock| not lock.takes end
      return site.with(
        unnamed: unnamed or taken.any? do |lock| annotated_lock(lock, texts).empty? end,
        takes: takes.concat(taken.flat_map do |lock| annotated_lock(lock, texts) end),
        drops: drops.concat(dropped.flat_map do |lock| annotated_lock(lock, texts) end),
        stops: stops or callee.stops,
      )
    none -> return site
  end
end

# An argument that passes the address of a pointer that owns (`&p`) as it is; any other with no owner.
def by_address(arg: Arg) -> Arg
  if arg.address
    return arg
  end

  return arg.with(owner: "")
end

# The pointers that own among the arguments at `indices`.
def owners_at(args: List[Arg], indices: List[Int]) -> List[String]
  return indices.select do |i| i < args.size and args[i].owner != "" end.map do |i| args[i].owner end
end

# The lock of the argument at `index`, if the call has it and it names an object.
def lock_of(args: List[Arg], index: Int) -> List[Lock]
  if index >= args.size
    return []
  end

  return locks_of([args[index].text]).map do |lock|
    lock.with(class: args[index].class, through: args[index].through)
  end
end

# The key of a lock of CC_RELEASES in the names of the parameters of the definition, which may not be those of the
# prototype that wrote it; "" for the restore of a pair.
def released_key(lock: Annotated, names: List[String]) -> String
  if lock.pair != ""
    return ""
  end

  return key_of(substituted(lock.text, lock.params, names))
end

# The lock of an annotation, in the texts of the arguments of the call.
def annotated_lock(lock: Annotated, texts: List[String]) -> List[Lock]
  return locks_of([substituted(lock.text, lock.params, texts)]).map do |found|
    found.with(class: lock.class, pair: lock.pair, through: lock.through)
  end
end

def arg_of(b: Builder, node: Json) -> Arg
  return Arg(
    text: text_of(b, node, true),
    class: class_of(b, node),
    owner: owner_of(b, node),
    address: address?(node),
    through: aliased_through?(b, node, 0),
  )
end

# Whether the field or global that a lock expression ends in is a pointer (`c->lk` of `pthread_mutex_t *lk`), through
# `&`, `*`, subscripts and the local variables set once, as `aliased_class` reads them.
def aliased_through?(b: Builder, node: Json, depth: Int) -> Bool
  bare = see_through(node)
  while Ast.kind(bare) == "UnaryOperator" and UNARY_TEXT.include?(Ast.text(bare, "opcode"))
    bare = see_through(Ast.children(bare).first)
  end

  case Ast.kind(bare)
    "MemberExpr" -> return pointer_type?(bare)
    # An item of an array of pointers (`p->mus[i]` of `pthread_mutex_t *mus[2]`) is a pointer itself.
    "ArraySubscriptExpr" -> return pointer_type?(bare) or aliased_through?(b, Ast.children(bare).first, depth)
    "DeclRefExpr" ->
      case b.aliases.get(Ast.referenced_name(bare))
        some(value) if depth < ALIAS_DEPTH -> return aliased_through?(b, value, depth + 1)
        _ -> return pointer_type?(bare)
      end

    _ -> return false
  end
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
  keys = value.b.owners.places.keys
  text = written_text(value.b, bare, false, keys, 0)
  roots = roots_of(keys, bare)
  place = Ast.start_of(bare)
  fact = Fact(text: text, value: true, roots: roots, line: place.line, column: place.column)
  null_on_true: List[String] = []
  null_on_false: List[String] = []
  case null_test(value.b, bare)
    some(test) if test.null_if -> null_on_true = [test.name]
    some(test) -> null_on_false = [test.name]
    none -> null_on_false = []
  end

  yes = add(value.b, Event.Branch(fact.with(nulls: null_on_true, set: null_on_false)), value.exits)
  no = add(yes.b, Event.Branch(fact.with(value: false, nulls: null_on_false, set: null_on_true)), value.exits)
  return Split(b: no.b, yes: yes.exits, no: no.exits)
end

# Whether a condition tells that a pointer that owns is null: `p`, `p = malloc(n)`, and either compared with 0.
def null_test(b: Builder, node: Json) -> Optional[NullTest]
  bare = see_through(node)
  name = owner_named(b, bare)
  if name == ""
    name = pointee_owner(b, bare)
  end

  if name != ""
    return some(NullTest(name: name, null_if: false))
  end

  opcode = Ast.text(bare, "opcode")
  parts = Ast.children(bare)
  if Ast.kind(bare) != "BinaryOperator" or parts.size != 2
    return none
  end

  if opcode == "="
    target = owner_named(b, parts[0])
    if target == ""
      return none
    end

    return some(NullTest(name: target, null_if: false))
  end

  if opcode != "==" and opcode != "!="
    return none
  end

  for pair in [[parts[0], parts[1]], [parts[1], parts[0]]]
    if zero?(pair[1])
      return null_test(b, pair[0]).map do |test| test.with(null_if: test.null_if != (opcode == "==")) end
    end
  end

  return none
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

# The call, then on the branch where it gave 0 a node that takes its lock.
def trial(b: Builder, tried: Tried, preds: List[Int]) -> Split
  called = call(b, tried.call, preds, true)
  args = Ast.children(tried.call).drop(1)
  name = callee_name(tried.call)
  passed = args.map do |arg| arg_of(called.b, arg) end
  site = site_of(called.b, name, passed, Ast.start_of(tried.call), false)
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
  return written_text(b, node, aliases, {}, 0)
end

# `text_of`, with the key that `keys` gives a variable in place of its name: the text of a condition, so a condition on
# a local is not one on another variable of its name.
def written_text(b: Builder, node: Json, aliases: Bool, keys: Map[String, String], depth: Int) -> String
  bare = see_through(node)
  parts = Ast.children(bare)
  case Ast.kind(bare)
    "DeclRefExpr" ->
      name = Ast.referenced_name(bare)
      aliased = ""
      if aliases and depth < ALIAS_DEPTH
        aliased = b.aliases.get(name).map do |value| written_text(b, value, aliases, keys, depth + 1) end.unwrap_or("")
      end

      if aliased != ""
        return aliased
      end

      return referenced_key(keys, bare)
    "MemberExpr" ->
      base = written_text(b, parts.first, aliases, keys, depth)
      if base == ""
        return ""
      end

      if Ast.flag?(bare, "isArrow")
        return "#{base}->#{Ast.text(bare, "name")}"
      end

      return "#{base}.#{Ast.text(bare, "name")}"
    "ArraySubscriptExpr" ->
      array = written_text(b, parts[0], aliases, keys, depth)
      index = written_text(b, parts[1], aliases, keys, depth)
      if array == "" or index == ""
        return ""
      end

      return "#{array}[#{index}]"
    "UnaryOperator" ->
      operand = written_text(b, parts.first, aliases, keys, depth)
      if operand == "" or Ast.flag?(bare, "isPostfix") or not UNARY_TEXT.include?(Ast.text(bare, "opcode"))
        return ""
      end

      return "#{Ast.text(bare, "opcode")}#{operand}"
    "BinaryOperator" ->
      left = written_text(b, parts[0], aliases, keys, depth)
      right = written_text(b, parts[1], aliases, keys, depth)
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

# The variables an expression reads, by key (`referenced_key`).
def roots_of(keys: Map[String, String], node: Json) -> List[String]
  if Ast.kind(node) == "DeclRefExpr"
    return [referenced_key(keys, node)]
  end

  # A followed CC_OWNS field of a local struct is a variable of its own, besides the struct.
  if Ast.kind(node) == "MemberExpr" and keys.key?(Ast.text(node, "id"))
    return [keys[Ast.text(node, "id")]].concat(Ast.children(node).flat_map do |child| roots_of(keys, child) end).uniq
  end

  return Ast.children(node).flat_map do |child| roots_of(keys, child) end.uniq
end

# The variable an assignment writes, by key (`referenced_key`): the root of `x`, `x->a.b` or `x[i]`.
def target_root(keys: Map[String, String], node: Json) -> String
  bare = see_through(node)
  case Ast.kind(bare)
    "DeclRefExpr" -> return referenced_key(keys, bare)
    "MemberExpr" -> return target_root(keys, Ast.children(bare).first)
    "ArraySubscriptExpr" -> return target_root(keys, Ast.children(bare).first)
    "UnaryOperator" -> return target_root(keys, Ast.children(bare).first)
    _ -> return ""
  end
end

# The variable whose own storage an expression is, by key: `x`, `x.a`, `x[i]` of an array `x`; "" through a pointer
# (`q->mu`, `*p`, `p[i]`), whose variable a write through the address does not change.
def storage_root(keys: Map[String, String], node: Json) -> String
  bare = see_through(node)
  case Ast.kind(bare)
    "DeclRefExpr" -> return referenced_key(keys, bare)
    "MemberExpr" ->
      if Ast.flag?(bare, "isArrow")
        return ""
      end

      return storage_root(keys, Ast.children(bare).first)
    "ArraySubscriptExpr" ->
      base = Ast.children(bare).first
      if Ast.text(base, "castKind") != "ArrayToPointerDecay"
        return ""
      end

      return storage_root(keys, Ast.children(base).first)
    _ -> return ""
  end
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

# `found` with the node and every node inside it, in order. Only pushes, so the list is never copied.
def with_descendants(found: List[Json], node: Json) -> List[Json]
  all = found.push(node)
  for child in Ast.children(node)
    all = with_descendants(all, child)
  end

  return all
end
