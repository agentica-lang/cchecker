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

# The statements with a condition, and the place of the condition among their children (`guarded_of`).
GUARDS: Map[String, Int] = {"IfStmt": 0, "WhileStmt": 0, "DoStmt": 1, "ForStmt": 2, "SwitchStmt": 0}

# The statements that leave the statement around them.
WAYS_OUT = Set.new(["ReturnStmt", "GotoStmt", "IndirectGotoStmt", "BreakStmt", "ContinueStmt"])

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

# The structs in a local struct are followed only up to these bounds: the levels of structs in it, and its CC_OWNS
# fields in all; over them only its own fields are. Each field is a pointer of the walk, and a path that lends the
# structs in it one by one keeps a state for each choice (see `specs/limits.feature`). A local array of structs is
# followed only when its items times the CC_OWNS fields of each are at most `MAX_NESTED_FIELDS`.
MAX_NESTED_DEPTH = 8
MAX_NESTED_FIELDS = 16

# The largest index that `constant_of` folds: no array of structs over `MAX_NESTED_FIELDS` items is followed, and a
# larger value cannot pass the size of an Int when two of them are added or multiplied.
MAX_INDEX = 1048576

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
  # Whether the call is of a helper on the side of its flags where it takes and releases nothing (`flagged_call`): the
  # rules of Held do not follow its body, whose lock calls are on the other side.
  idle: Bool = false
end

## The value a condition has on an edge. `text` is the condition with the key of each variable (`variable_key`), ""
## for a condition that may change between two reads (a call). `roots` are the variables it reads, by key, so a write
## to one forgets it. `nulls` are the pointers that own which are null on this edge (`if (!p)`,
## `if ((p = malloc(n)) == NULL)`), and `set` those that are not.
##
## A test against 0 is a fact of what it compares (`r == 0` is `r` false), so all the ways C writes a test of one
## variable are one condition; `word` is then what a path shows ("true" where `r == 0` holds, "case" for a label of a
## switch on the variable), "" for the value. `quiet` facts show no step in a path. A fact can also come from a write,
## with no test in the code (`written`): the value of a constant written to a variable (`locked = 1`), and the result
## of a trylock kept in a variable, on the side where the call worked and the side where it failed
## (`r = pthread_mutex_trylock(&m)`), whose step reads `fails` and names the lock it did not take (`failed`).
## `if_tested` is the side where a call failed that fails only on an error (`r = pthread_mutex_lock(&m)`): a path goes
## there only when a test of the result can follow (`Locking.tested_after`). `single` is a fact with no node for its
## other value (a constant, a `case` label).
export struct Fact
  text: String
  value: Bool
  roots: List[String]
  line: Int
  column: Int
  nulls: List[String] = []
  set: List[String] = []
  word: String = ""
  quiet: Bool = false
  written: Bool = false
  if_tested: Bool = false
  single: Bool = false
  failed: List[Lock] = []
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

## What happens at a node. `Writes` names the variables a node writes, by key (see `variable_key`), `Escapes` the
## followed CC_OWNS fields of a local struct that escapes there (`&p`, a copy, a by-value argument, `return p`,
## `p = q`), `Resets` those that a clear of the whole struct follows again (`memset(&p, 0, sizeof p)`,
## `p = (struct pair){0}`), and `Closes` the pointers of the blocks that a path leaves (`Closing`).
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
  Escapes(List[String])
  Resets(List[String])
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
## passes (for a CC_OWNS struct passed by value, its CC_OWNS fields: `p.left`), and `owns` says whether the ownership
## rules read the function: it has a pointer that owns, or calls a function that returns one. `releases` are the keys
## of the locks of its CC_RELEASES in the names of its parameters, in the order of its marks ("" for the restore of a
## pair), and `acquires` those of its CC_ACQUIRES ("" for the set of a pair). `enters` says that a `goto`, or a `case`
## or `default` label, goes into a block from outside it.
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
  # A `goto` goes into a block from outside it (past the declarations before its label).
  enters: Bool = false
end

## A lock of a CC_ACQUIRES (`takes`) or a CC_RELEASES, as written, with the names of the parameters of the
## declaration that carries it; or the lock of a CC_PAIR that a set takes and its restore (`pair`) releases. A lock of a
## CC_ACQUIRES_IF or a CC_RELEASES_IF has the parameter of its flag (`flag`): the call takes the lock only where it set
## `*flag` to a value other than 0, and releases it only where `flag` is not 0. A lock of a CC_TRIES (`tries`) is taken
## where the call returns 0, as a trylock does.
export struct Annotated
  text: String
  params: List[String]
  takes: Bool
  class: String = ""
  pair: String = ""
  through: Bool = false
  flag: String = ""
  tries: Bool = false
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
## to a union, `records` the structs with a CC_OWNS field or a field of such a struct, by the id of their
## declaration, and `typed` the record of the type of each local variable, initializer and `sizeof` of a type of the
## function bodies, and of each field, that names one of them, by the id of the node. `lengths` are the number of
## items of each local array of such structs (`struct pair a[2]`, whose `typed` is the record of its items).
export struct Owning
  returns: Set[String]
  takes: Map[String, List[Int]]
  frees: Map[String, List[Int]]
  outs: Map[String, List[Int]]
  fields: Set[String]
  globals: Set[String]
  unions: Set[String]
  records: Map[String, OwnedRecord]
  typed: Map[String, String]
  lengths: Map[String, Int] = {}
end

## A struct with a CC_OWNS field, or with a field of such a struct: the ids and names of all its fields, in the order
## of the items of an initializer, and for each the id of such a struct that the field is by value ("" for any other).
export struct OwnedRecord
  ids: List[String]
  names: List[String]
  nested: List[String] = []
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

# A loop or a switch, for its `break`, `continue` and `case`. `depth` is the number of blocks open around it. The
# `subject` of a switch is the fact of the value it tests, none when the value has no text, and `zero` whether it has a
# `case 0` (`label_event`).
struct Jump
  switch: Bool
  head: Int
  depth: Int
  breaks: List[Int]
  continues: List[Int]
  subject: Optional[Fact] = none
  zero: Bool = false
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
  # A `goto` goes into a block that is not open around it (an indirect one into any block with a label).
  enters: Bool = false
  # The locals whose value the rules never know (`opaque_of`), and those that a test guarding a lock reads
  # (`guarded_of`): only those get a fact from a constant written to them.
  opaque: Set[String]
  guarded: Set[String]
end

# The places of a function that keep an owned pointer stored in them: its parameters and local variables (`locals`),
# `*p` of a parameter that frees it only (`freed`, CC_FREES) or that hands an owned pointer out to the caller (`outs`,
# CC_OWNS_OUT; `out[i]` too), and an item of a pointer whose items own what is stored in them (`arrays`: the pointers
# that own or stand for one, and the locals that get the value of an allocation). The sets hold the keys of the
# variables (`variable_key`), and `keys` gives the key of each variable the function declares, by the id of its
# declaration, and of each `p.f` of a CC_OWNS field of a local struct it follows, by the id of the expression
# (`owned_fields`). The other places are those of `Followed`.
struct Places
  locals: Set[String]
  freed: Set[String]
  outs: Set[String]
  arrays: Set[String]
  keys: Map[String, String]
  fields: Map[String, List[String]] = {}
  items: Map[String, Int] = {}
  parts: Map[String, List[String]] = {}
  wholes: Map[String, String] = {}
end

# The CC_OWNS fields of the local structs that a function follows (`owned_fields`), with those of the structs in them
# by value (`p.inner.left`): the key of each `p.f` by the id of the expression (`members`); the key of a struct in a
# struct (`p.inner`) by the id of each expression that names it whole (`wholes`); the keys of all the CC_OWNS fields
# in each struct, nested ones too, by the key of the struct or of the struct in it (`of`); the fields and the structs
# right in each (`parts`), and the place of each of those among the items of an initializer of its struct (`items`).
# `slots` gives the key of a part by the key of its struct, a bar and the id of the field. An unnamed member has a
# key of its own (`p.#a3`) but adds no name to the keys of its fields (`c.buf`), as C names them.
struct Followed
  members: Map[String, String]
  of: Map[String, List[String]]
  items: Map[String, Int]
  parts: Map[String, List[String]] = {}
  wholes: Map[String, String] = {}
  slots: Map[String, String] = {}
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

# A statement expression up to its value (`valued_expression`): the nodes after its other statements, and the
# expression of its last one, or "" for a last statement that is not an expression.
struct Valued
  b: Builder
  exits: List[Int]
  value: Json
end

# A condition: the nodes after it when it is true, and when it is false.
struct Split
  b: Builder
  yes: List[Int]
  no: List[Int]
end

# A side of the flags of a call (`flagged_call`): the nodes it goes on from, and the locks the call takes and releases
# there besides those of its site.
struct Flagged
  exits: List[Int]
  takes: List[Lock]
  drops: List[Lock]
  # Whether the helper takes or releases a lock on this side, even one that no text names.
  acts: Bool = false
end

# A call of `Known.TRIES` in a condition or a value, and whether that is true when the call gave 0 (`call == 0`,
# `!call`) or false (`call`, `call != 0`).
struct Tried
  call: Json
  zero_is_true: Bool
end

# What a comparison with 0 (`zero_compared`) or another whole number (`number`) compares, and whether it is `==`.
struct Compared
  operand: Json
  equal: Bool
  number: String = ""
end

## Returns whether a function body calls something that takes or releases a lock, the only bodies the path rules read.
export def locks?(ctx: Context, node: Json) -> Bool
  name = ""
  if Ast.kind(node) == "CallExpr"
    name = callee_name(node)
  elsif Ast.kind(node) == "CleanupAttr"
    name = Ast.text(JSON.get(node, "cleanup_function").unwrap_or(JSON.from("")), "name")
  end

  return true if Known.TAKES.include?(name) or Known.TRIES.include?(name) or Known.DROPS.include?(name)

  return true if name != "" and ctx.callees.key?(key_of_function(ctx, name))

  Ast.children(node).any? do |child| locks?(ctx, child) end
end

## Returns whether the ownership rules read a function definition, whose key is `key`: it has a pointer that owns or
## a parameter that hands one out, or calls a function that returns one or hands one out.
export def owns?(ctx: Context, key: String, node: Json) -> Bool
  return true if ctx.owning.takes.key?(key) or ctx.owning.frees.key?(key) or ctx.owning.outs.key?(key)

  return true if Ast.children(node).any? do |child| owning_node?(ctx, child) end

  # A local struct whose CC_OWNS fields the rules follow (`owned_fields`), which only the whole function tells.
  return false if not Ast.children(node).any? do |child| field_access?(ctx, child) end

  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  all = descendants(bodies)
  not owned_fields(ctx, all, keys_of(node, all)).of.empty?
end

## Returns the graph of a function definition, whose key is `key`.
export def body_of(ctx: Context, key: String, node: Json) -> Body
  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  place = Ast.place_of(node)
  owners = owners_of(ctx, key, node)
  all = descendants(bodies)
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
    opaque: opaque_of(owners.places.keys, all, flag_addresses(ctx, all)),
    guarded: guarded_of(ctx, owners.places.keys, all),
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
  # The locks a call drops on one side come after the others on its site (`flagged_call`), and so here.
  dropped_locks = ctx.callees.get(key).map do |callee| callee.locks.select do |lock| not lock.takes end end
  dropped = dropped_locks.unwrap_or([])
  flagged = dropped.select do |lock| lock.flag != "" end
  plain = dropped.select do |lock| lock.flag == "" end
  dropped = plain.concat(flagged)
  taken_locks = ctx.callees.get(key).map do |callee| callee.locks.select do |lock| lock.takes end end
  taken = taken_locks.unwrap_or([])
  Body(
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
    enters: linked.enters,
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
      return "" if i >= args.size or args[i] == ""

      return prefix + args[i] + written.slice(root, written.length - root)
    end
  end

  prefix + written
end

## Returns the key of a lock text: the object, without the `&` or `*&` in front, and `->` read as `.`.
export def key_of(lock: String) -> String = shown_of(lock).replace("->", ".")

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

  written
end

## Returns whether a declaration is marked CC_OWNS.
export def marked_owner?(node: Json) -> Bool
  Ast.children(node).any? do |child|
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

  found
end

## Returns whether an expression is a call of a function that returns an owned pointer (CC_OWNS on the function).
export def owning_call?(ctx: Context, node: Json) -> Bool
  bare = see_through(node)
  return false if Ast.kind(bare) != "CallExpr"

  name = callee_name(bare)
  name != "" and ctx.owning.returns.include?(key_of_function(ctx, name))
end

## Returns the name of the local variable or the parameter that an expression is, through casts and parentheses; ""
## for any other.
export def variable_name(node: Json) -> String
  bare = see_through(node)
  return Ast.referenced_name(bare) if Ast.kind(bare) == "DeclRefExpr" and VARIABLES.include?(Ast.referenced_kind(bare))

  ""
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

  return keys.get(Ast.text(bare, "id"), "") if Ast.kind(bare) == "MemberExpr"

  ""
end

## Returns the key of a variable at its declaration (see `variable_key`).
export def declared_key(keys: Map[String, String], decl: Json) -> String
  keys.get(Ast.text(decl, "id"), Ast.text(decl, "name"))
end

## Returns the name that a key stands for: what the code calls the variable (`p` for `p#2`, `p.left` for `p#2.left`).
export def plain(key: String) -> String
  parts = key.split(KEY_MARK)
  return key if parts.size < 2

  rest = parts[1]
  digits = 0
  while digits < rest.length and DIGITS.include?(rest.slice(digits, 1))
    digits += 1
  end

  parts[0] + rest.slice(digits, rest.length - digits)
end

## Returns every node under the given ones, each before the nodes inside it.
export def descendants(nodes: List[Json]) -> List[Json]
  found: List[Json] = []
  for node in nodes
    found = with_descendants(found, node)
  end

  found
end

## Returns an expression without the casts and parentheses around it.
export def see_through(node: Json) -> Json
  bare = node
  while SEE_THROUGH.include?(Ast.kind(bare)) and not Ast.children(bare).empty?
    bare = Ast.children(bare).first
  end

  bare
end

## Returns the name of the function that a call names, or "" for a call through a pointer.
export def callee_name(node: Json) -> String
  parts = Ast.children(node)
  return "" if parts.empty?

  callee = see_through(parts.first)
  return "" if Ast.kind(callee) != "DeclRefExpr" or Ast.referenced_kind(callee) != "FunctionDecl"

  Ast.referenced_name(callee)
end

## Returns the key of a function of the unit by name: `name@file` for a static one.
export def key_of_function(ctx: Context, name: String) -> String = ctx.statics.get(name).unwrap_or(name)

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

  return false if Ast.kind(bare) != "UnaryOperator" or Ast.text(bare, "opcode") != "-" or Ast.children(bare).empty?

  value = see_through(Ast.children(bare).first)
  constant = Ast.kind(value) == "DeclRefExpr" and Ast.referenced_kind(value) == "EnumConstantDecl"
  constant or (Ast.kind(value) == "IntegerLiteral" and Ast.text(value, "value") != "0")
end

## Returns whether an expression is the constant 0, through casts and parentheses.
export def zero?(node: Json) -> Bool
  bare = see_through(node)
  Ast.kind(bare) == "IntegerLiteral" and Ast.text(bare, "value") == "0"
end

## Returns a type without the qualifiers at its end, and out of `_Atomic(...)`: `char *` for `char *const volatile`.
## clang writes no space between the star and the qualifier.
export def unqualified(type: String) -> String
  text = type.strip
  return unqualified(text.slice(8, text.length - 9)) if text.start_with?("_Atomic(") and text.end_with?(")")

  for word in ["const", "volatile", "restrict", "__restrict"]
    if text.end_with?(" #{word}") or text.end_with?("*#{word}")
      return unqualified(text.slice(0, text.length - word.length))
    end
  end

  text
end

## Returns the names of the parameters of a function definition, whose key is `key`, that own what the caller passes
## (CC_OWNS or CC_FREES), in the order of the parameters.
export def owned_params(ctx: Context, key: String, node: Json) -> List[String]
  names = params_named(node)
  indices = ctx.owning.takes.get(key, []).concat(ctx.owning.frees.get(key, [])).uniq.sort
  in_range = indices.select do |i| i < names.size end
  in_range.map do |i| names[i] end
end

## Returns the names of the parameters of a function, in order.
export def params_named(node: Json) -> List[String]
  params = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
  params.map do |child| Ast.text(child, "name") end
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
  frees_kept = ctx.owning.frees.get(key, []).select do |i| i < names_of_params.size and not takes.include?(i) end
  freed = Set.new(frees_kept.map do |i| names_of_params[i] end)

  declared = keys_of(node, all)
  followed = owned_fields(ctx, all, declared, taken_structs(ctx, key, node))
  keys = declared
  for id in followed.members.keys
    keys = keys.put(id, followed.members[id])
  end

  # A struct passed by value to a CC_OWNS parameter is no pointer: its followed fields own from the entry instead, and
  # one that is not followed owns nothing.
  record_params = Ast.children(node).select do |child|
    Ast.kind(child) == "ParmVarDecl" and not pointer_type?(child) and record_type?(child)
  end

  structs = record_params.map do |child| declared_key(declared, child) end

  params = params.select do |name| not structs.include?(name) end
  for name in structs
    params = params.concat(followed.of.get(name, []))
  end

  decls = all.select do |n| Ast.kind(n) == "VarDecl" end
  public_decls = decls.select do |n| Ast.text(n, "storageClass") != "static" end
  locals = Set.new(names_of_params.concat(public_decls.map do |n| declared_key(keys, n) end))
  marked_decls = public_decls.select do |n| marked_owner?(n) end
  marked_keys = Set.new(marked_decls.map do |n| declared_key(keys, n) end)
  marked = marked_keys.union(Set.new(followed.of.values.flat_map do |places| places end))
  out_kept = ctx.owning.outs.get(key, []).select do |i| i < names_of_params.size end
  outs = Set.new(out_kept.map do |i| names_of_params[i] end)

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

  allocations = written.select do |w| allocation?(w.value) end
  allocated = allocations.map do |w| w.name end
  places = Places(
    locals: locals,
    freed: freed,
    outs: outs,
    arrays: names.union(outs).union(Set.new(allocated)),
    keys: keys,
    fields: followed.of,
    items: followed.items,
    parts: followed.parts,
    wholes: followed.wholes,
  )

  Owners(
    params: params,
    places: places,
    names: names,
    marked: marked,
    kept: kept_calls(ctx, all, places),
    calls: all.any? do |n| owning_call?(ctx, n) end,
  )
end

# The parameters of a function, whose key is `key`, that a caller passes a struct to by value and that take it
# (CC_OWNS): their fields own from the entry.
def taken_structs(ctx: Context, key: String, node: Json) -> List[Json]
  params = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
  takes = ctx.owning.takes.get(key, [])
  taken_params = (0...params.size).to_a.select do |i| takes.include?(i) end
  taken_params.map do |i| params[i] end
end

# Whether the type of a declaration or an expression is a struct or a union itself, as written or behind a typedef.
def record_type?(node: Json) -> Bool
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  [Ast.text(type, "qualType"), Ast.text(type, "desugaredQualType")].any? do |text|
    bare = unqualified(text)
    for word in ["const ", "volatile "]
      if bare.start_with?(word)
        bare = bare.slice(word.length, bare.length - word.length)
      end
    end

    (bare.start_with?("struct ") or bare.start_with?("union ")) and not bare.end_with?("*") and not bare.end_with?("]")
  end
end

# Whether an expression is a call of an allocator (`malloc`, `calloc`, ...), through casts and parentheses.
def allocation?(node: Json) -> Bool
  bare = see_through(node)
  Ast.kind(bare) == "CallExpr" and Known.OWNED.include?(callee_name(bare))
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

  found
end

# The indices of the parameters of a function, by name, that hand an owned pointer out to the caller.
def out_params(ctx: Context, name: String) -> List[Int]
  return [] if name == ""

  ctx.owning.outs.get(key_of_function(ctx, name), [])
end

# Whether a node is or holds a local marked CC_OWNS, a call of a function that returns an owned pointer, or a call of
# one that hands an owned pointer out through a parameter.
# Whether a node is or holds a CC_OWNS field of a local variable (`p.left`), or the declaration of a local struct with
# such a field.
def field_access?(ctx: Context, node: Json) -> Bool
  return true if struct_of(node) != "" and ctx.owning.fields.include?(Ast.text(node, "referencedMemberDecl"))

  return true if Ast.kind(node) == "VarDecl" and ctx.owning.typed.key?(Ast.text(node, "id"))

  Ast.children(node).any? do |child| field_access?(ctx, child) end
end

def owning_node?(ctx: Context, node: Json) -> Bool
  return true if (Ast.kind(node) == "VarDecl" and marked_owner?(node)) or owning_call?(ctx, node)

  return true if Ast.kind(node) == "CallExpr" and not out_params(ctx, callee_name(node)).empty?

  Ast.children(node).any? do |child| owning_node?(ctx, child) end
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
  (
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
      "InitListExpr" ->
        # An initializer or a compound literal keeps what it gives a CC_OWNS field.
        owning = owning_items(ctx, n)
        owning_at = (0...parts.size).to_a.select do |i| owning.include?(i) end
        values = owning_at.map do |i| parts[i] end
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

  kept
end

# The values an expression may have: each side of `?:` (`x ?: y` is `x` or `y`), the last expression of a statement
# expression, or itself.
def values_of(node: Json) -> List[Json]
  bare = see_through(node)
  return Ast.children(bare).drop(1).flat_map(&values_of) if Ast.kind(bare) == "ConditionalOperator"

  if Ast.kind(bare) == "BinaryConditionalOperator"
    parts = Ast.children(bare)
    return values_of(parts.first).concat(values_of(parts.last))
  end

  if Ast.kind(bare) == "StmtExpr"
    body = last_child(last_child(bare))
    return values_of(unlabelled(body))
  end

  [node]
end

# A statement under its labels and attributes (`done: p;` is `p;`).
def unlabelled(node: Json) -> Json
  bare = node
  while Ast.kind(bare) == "LabelStmt" or Ast.kind(bare) == "AttributedStmt"
    bare = last_child(bare)
  end

  bare
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

  keys
end

# The CC_OWNS fields of the local structs of a function (`p.left`): the key of each is the key of the struct (`keys`),
# a dot and the name of the field, through the structs in it by value (`p.inner.left`). The fields are followed up to
# where the struct, or the struct in it, escapes: its address, a copy, a by-value argument, a return, or a new value
# of the whole struct. `&p.left` of a CC_OWNS field is the address of that pointer, and `&p.inner` that of the struct
# in it. A struct whose other field has its address taken (`&p.n`, which may reach the whole struct), a static one, a
# union and one whose record is not known (`Owning.typed`) are not followed: a store into their CC_OWNS fields hands
# the pointer on. A struct passed by value to a CC_OWNS parameter (`params`) is followed as a local one. Each item of
# a local array of structs is a struct of its own (`a[0].left`), within the bound of `MAX_NESTED_FIELDS` in all.
def owned_fields(ctx: Context, all: List[Json], keys: Map[String, String], params: List[Json] = []) -> Followed
  found = Followed(members: {}, of: {}, items: {})
  return found if ctx.owning.fields.empty?

  structs: Map[String, Json] = {}
  for n in params.concat(all)
    local = Ast.kind(n) == "ParmVarDecl" or (Ast.kind(n) == "VarDecl" and Ast.text(n, "storageClass") == "")
    if local and ctx.owning.typed.key?(Ast.text(n, "id"))
      structs = structs.put(Ast.text(n, "id"), n)
    end
  end

  # The fields of the record of each struct, and of the structs in it, with their items, so an initializer gives
  # each its value.
  for id in structs.keys.sort
    case record_of(ctx, structs[id])
      some(record) ->
        # Over the bounds only the struct's own CC_OWNS fields are followed: a struct in it is then a field that does
        # not own (a store into its fields hands the pointer on, and `&p.inner` stops following the whole struct).
        nest = record.nested.all? do |inner| inner == "" end or nested_fields(ctx, record, 0) <= MAX_NESTED_FIELDS
        case ctx.owning.lengths.get(id)
          some(length) ->
            if length * nested_fields(ctx, record, 0) <= MAX_NESTED_FIELDS
              found = with_items(ctx, found, keys.get(id, ""), record, length)
            end

          none -> found = with_parts(ctx, found, keys.get(id, ""), keys.get(id, ""), record, 0, nest)
        end

      none -> next
    end
  end

  # The key of each `p.f` and `p.inner` of a struct, and the structs whose other fields have their address taken.
  unfollowed = unfollowed_arrays(ctx, found, all, keys)
  for n in all
    if Ast.kind(n) == "MemberExpr" or Ast.kind(n) == "ArraySubscriptExpr"
      place = part_of(found, keys, n)
      if found.of.key?(place)
        found = found.with(wholes: found.wholes.put(Ast.text(n, "id"), place))
      elsif place != ""
        found = found.with(members: found.members.put(Ast.text(n, "id"), place))
      end
    elsif Ast.kind(n) == "UnaryOperator" and Ast.text(n, "opcode") == "&"
      member = see_through(Ast.children(n).first)
      if Ast.kind(member) == "MemberExpr" and part_of(found, keys, member) == ""
        unfollowed = unfollowed.add(keys.get(struct_of(member), ""))
      end
    end
  end

  return found if unfollowed.empty?

  roots = Set.new(structs.keys.map do |id| keys.get(id, "") end)
  dropped = Set.new(found.of.keys.select do |place| unfollowed.include?(root_of(place, roots)) end)
  Followed(
    members: found.members.select do |_, place| not unfollowed.include?(root_of(place, roots)) end,
    of: found.of.select do |place, _| not dropped.include?(place) end,
    items: found.items.select do |place, _| not unfollowed.include?(root_of(place, roots)) end,
    parts: found.parts.select do |place, _| not dropped.include?(place) end,
    wholes: found.wholes.select do |_, place| not dropped.include?(place) end,
    slots: {},
  )
end

# The followed arrays of structs that a function reads other than item by item by a constant index (`a[0].left`), in
# any place but a `sizeof`: an index that is not a constant (`a[i]`), the array whole (`keep(a)`, `q = a`, `a + 1`) or
# the address of an item (`&a[0]`), but for the array that `memset` clears and an item that a CC_FREES parameter gets.
# Such a read may reach any item, and in a loop the walk also takes the path that does not run it (a loop that frees
# every item would leak them all there): such an array is not followed in the function.
def unfollowed_arrays(ctx: Context, found: Followed, all: List[Json], keys: Map[String, String]) -> Set[String]
  arrays = Set.new(found.parts.keys.select do |key| found.slots.key?("#{key}|[0]") end)
  unfollowed: Set[String] = Set.new([])
  return unfollowed if arrays.empty?

  measured: Set[String] = Set.new([])
  allowed: Set[String] = Set.new([])
  for n in all
    id = Ast.text(n, "id")
    parts = Ast.children(n)
    if measured.include?(id) or Ast.kind(n) == "UnaryExprOrTypeTraitExpr"
      measured = measured.union(Set.new(parts.map do |child| Ast.text(child, "id") end))
      next
    end

    case Ast.kind(n)
      "CallExpr" ->
        name = callee_name(n)
        given = ctx.owning.frees.get(key_of_function(ctx, name), []).map do |i| i + 1 end
        if Known.FILLS.include?(name)
          given = given.push(1)
        end

        for i in given
          if i < parts.size
            allowed = allowed.add(Ast.text(see_through(parts[i]), "id"))
          end
        end

      "UnaryOperator" ->
        item = see_through(parts.first)
        if Ast.text(n, "opcode") == "&" and allowed.include?(id)
          allowed = allowed.add(Ast.text(item, "id"))
        elsif Ast.text(n, "opcode") == "&" and Ast.kind(item) == "ArraySubscriptExpr"
          unfollowed = unfollowed.add(keys.get(Ast.referenced_id(see_through(Ast.children(item).first)), ""))
        end

      "ArraySubscriptExpr" ->
        if constant_of(parts.last) >= 0
          allowed = allowed.add(Ast.text(see_through(parts.first), "id"))
        end

      "DeclRefExpr" ->
        key = keys.get(Ast.referenced_id(n), "")
        if arrays.include?(key) and not allowed.include?(id)
          unfollowed = unfollowed.add(key)
        end

      _ -> next
    end
  end

  unfollowed
end

# The key of the struct of `roots` that a place is in (`p` for `p.inner.left`, `a` for `a[0].left`).
def root_of(place: String, roots: Set[String]) -> String
  name = place.split(".").first.split("[").first
  return name if roots.include?(name)

  ""
end

# The CC_OWNS fields of a struct, those of the structs in it too, up to the first count over `MAX_NESTED_FIELDS`; over
# it too for a struct with more than `MAX_NESTED_DEPTH` levels of structs in it.
def nested_fields(ctx: Context, record: OwnedRecord, depth: Int) -> Int
  count = 0
  for i in 0...record.ids.size
    if ctx.owning.fields.include?(record.ids[i]) and not ctx.owning.unions.include?(record.ids[i])
      count += 1
    elsif i < record.nested.size and record.nested[i] != ""
      case ctx.owning.records.get(record.nested[i])
        some(inner) ->
          return MAX_NESTED_FIELDS + 1 if depth >= MAX_NESTED_DEPTH

          count += nested_fields(ctx, inner, depth + 1)
        none -> next
      end
    end

    return count if count > MAX_NESTED_FIELDS
  end

  count
end

# `found` with the parts of the struct `key` of the record `record`: each CC_OWNS field outside a union, and each
# struct in it by value with its own parts. `prefix` is what the keys of its fields start with, the key of the struct
# but for an unnamed member, which adds no name. `nested_fields` bounds the depth and the size before: without
# `nest`, the structs in it are left out.
def with_parts(
  ctx: Context,
  found: Followed,
  key: String,
  prefix: String,
  record: OwnedRecord,
  depth: Int,
  nest: Bool,
) -> Followed
  grown = found.with(of: found.of.put(key, found.of.get(key, [])), parts: found.parts.put(key, []))
  return grown if depth > MAX_NESTED_DEPTH

  for i in 0...record.ids.size
    nested = ""
    if i < record.nested.size
      nested = record.nested[i]
    end

    field = record.ids[i]
    place = ""
    if ctx.owning.fields.include?(field) and not ctx.owning.unions.include?(field)
      place = "#{prefix}.#{record.names[i]}"
      grown = with_field(grown, key, place)
    elsif nested != "" and nest
      case ctx.owning.records.get(nested)
        some(inner) ->
          sub_prefix = "#{prefix}.#{record.names[i]}"
          place = sub_prefix
          if record.names[i] == ""
            sub_prefix = prefix
            place = "#{key}.#{KEY_MARK}a#{i}"
          end

          grown = with_parts(ctx, grown, place, sub_prefix, inner, depth + 1, true)
          for leaf in grown.of.get(place, [])
            grown = with_field(grown, key, leaf)
          end

        none -> next
      end
    end

    if place != ""
      grown = grown.with(
        parts: grown.parts.put(key, grown.parts.get(key, []).push(place)),
        items: grown.items.put(place, i),
        slots: grown.slots.put("#{key}|#{field}", place),
      )
    end
  end

  grown
end

# `found` with the items of the local array `key` of structs of the record `record`: each is a struct of its own
# (`a[0]`), with its parts.
def with_items(ctx: Context, found: Followed, key: String, record: OwnedRecord, length: Int) -> Followed
  grown = found.with(of: found.of.put(key, []), parts: found.parts.put(key, []))
  for i in 0...length
    place = "#{key}[#{i}]"
    grown = with_parts(ctx, grown, place, place, record, 0, true)
    for leaf in grown.of.get(place, [])
      grown = with_field(grown, key, leaf)
    end

    grown = grown.with(
      parts: grown.parts.put(key, grown.parts.get(key, []).push(place)),
      items: grown.items.put(place, i),
      slots: grown.slots.put("#{key}|[#{i}]", place),
    )
  end

  grown
end

# The key of the part that a member expression names (`p.left`, `p.inner`, `p.inner.left`, `c.buf` through an unnamed
# member, `a[0]` and `a[0].left` of an array by a constant index), when its struct is followed; "" for any other.
def part_of(found: Followed, keys: Map[String, String], node: Json) -> String
  bare = see_through(node)
  if Ast.kind(bare) == "DeclRefExpr" and VARIABLES.include?(Ast.referenced_kind(bare))
    key = keys.get(Ast.referenced_id(bare), "")
    return key if found.parts.key?(key)

    return ""
  end

  if Ast.kind(bare) == "ArraySubscriptExpr"
    parts = Ast.children(bare)
    base = part_of(found, keys, parts.first)
    index = constant_of(parts.last)
    return "" if base == "" or index < 0

    return found.slots.get("#{base}|[#{index}]", "")
  end

  return "" if Ast.kind(bare) != "MemberExpr" or Ast.flag?(bare, "isArrow")

  base = part_of(found, keys, Ast.children(bare).first)
  return "" if base == ""

  found.slots.get("#{base}|#{Ast.text(bare, "referencedMemberDecl")}", "")
end

# The value of an index that is an integer constant: a number, also through a cast, parentheses and the operators `+`,
# `-` and `*` of such numbers (`N - 1` of a macro); -1 for any other (a variable, an enum constant, a negative value).
def constant_of(node: Json) -> Int
  bare = see_through(node)
  if Ast.kind(bare) == "IntegerLiteral"
    value = Ast.text(bare, "value").to_i.unwrap_or(-1)
    return -1 if value > MAX_INDEX

    return value
  end

  parts = Ast.children(bare)
  return -1 if Ast.kind(bare) != "BinaryOperator" or parts.size != 2

  left = constant_of(parts.first)
  right = constant_of(parts.last)
  return -1 if left < 0 or right < 0

  case Ast.text(bare, "opcode")
    "+" ->
      return -1 if left + right > MAX_INDEX

      left + right
    "-" ->
      return -1 if left < right

      left - right
    "*" ->
      return -1 if left > 0 and right > MAX_INDEX / left

      left * right
    _ -> -1
  end
end

# `found` with the field `place` of the struct `key`.
def with_field(found: Followed, key: String, place: String) -> Followed
  places = found.of.get(key, [])
  return found if places.include?(place)

  found.with(of: found.of.put(key, places.push(place)))
end

# The items of an initializer that give a CC_OWNS field of its struct its value, by index. The item of a union is the
# field it names.
def owning_items(ctx: Context, init: Json) -> Set[Int]
  owning: Set[Int] = Set.new([])
  case JSON.get(init, "field")
    ok(field) ->
      if ctx.owning.fields.include?(Ast.text(field, "id")) and Ast.children(init).size == 1
        owning = owning.add(0)
      end

      return owning
    error(_) -> owning = owning
  end

  case record_of(ctx, init)
    some(record) ->
      for i in 0...record.ids.size
        if ctx.owning.fields.include?(record.ids[i]) and not ctx.owning.unions.include?(record.ids[i])
          owning = owning.add(i)
        end
      end

    none -> return owning
  end

  owning
end

# The record of a variable, an initializer or a `sizeof` with a CC_OWNS field, by the id of its node.
def record_of(ctx: Context, node: Json) -> Optional[OwnedRecord]
  case ctx.owning.typed.get(Ast.text(node, "id"))
    some(id) -> ctx.owning.records.get(id)
    none -> none
  end
end

# The id of the local variable whose field an expression is (`p.left`, `p.inner.left`, not `p->left`); "" for any
# other.
def struct_of(node: Json) -> String
  return "" if Ast.kind(node) != "MemberExpr" or Ast.flag?(node, "isArrow")

  base = see_through(Ast.children(node).first)
  return struct_of(base) if Ast.kind(base) == "MemberExpr"

  # An item of a local array (`a[i].left`), not of one through a pointer.
  if Ast.kind(base) == "ArraySubscriptExpr"
    decayed = Ast.children(base).first
    return "" if Ast.text(decayed, "castKind") != "ArrayToPointerDecay"

    base = see_through(decayed)
  end

  return "" if Ast.kind(base) != "DeclRefExpr" or not VARIABLES.include?(Ast.referenced_kind(base))

  Ast.referenced_id(base)
end

# The key of what a reference names: the key of a variable of the function, else the name (a global, a function, an
# enum constant), which no key of the function has. Conditions and writes name variables so.
def referenced_key(keys: Map[String, String], ref: Json) -> String
  keys.get(Ast.referenced_id(ref), Ast.referenced_name(ref))
end

# The indices of the parameters of a function that take or free what a call passes: CC_OWNS and CC_FREES, the first
# of `free`, and the first of a realloc, which moves it.
def taken(ctx: Context, name: String, key: String) -> List[Int] = freed(ctx, name, key).concat(handed(ctx, name, key))

def freed(ctx: Context, name: String, key: String) -> List[Int]
  indices = ctx.owning.frees.get(key, [])
  if Known.FREES.include?(name)
    indices = indices.push(0)
  end

  indices
end

def handed(ctx: Context, name: String, key: String) -> List[Int]
  indices = ctx.owning.takes.get(key, [])
  if Known.RESIZES.include?(name)
    indices = indices.push(0)
  end

  indices
end

# Whether a store into an expression hands a pointer on: a CC_OWNS field (`x->held`), an item of one
# (`x->items[i]`), or a CC_OWNS global.
def place_owns?(ctx: Context, node: Json) -> Bool
  bare = see_through(node)
  case Ast.kind(bare)
    "MemberExpr" -> ctx.owning.fields.include?(Ast.text(bare, "referencedMemberDecl"))
    "ArraySubscriptExpr" -> place_owns?(ctx, Ast.children(bare).first)
    "DeclRefExpr" -> ctx.owning.globals.include?(Ast.referenced_id(bare))
    _ -> false
  end
end

# Whether a store into an expression of a function hands a pointer on to a place that `places` names: `*out` of a
# parameter that hands an owned pointer out, or an item of a pointer whose items own (`argv[i]`).
def handed_place?(places: Places, node: Json) -> Bool
  return true if pointee_param(places.keys, node, places.outs) != ""

  bare = see_through(node)
  (
    Ast.kind(bare) == "ArraySubscriptExpr" and
    places.arrays.include?(variable_key(places.keys, Ast.children(bare).first))
  )
end

def identifier_char?(c: String) -> Bool
  code = c.code
  c == "_" or (code >= 97 and code <= 122) or (code >= 65 and code <= 90) or (code >= 48 and code <= 57)
end

# The keys of the locals whose value the rules never know: one whose address is taken (`&x`, also in an initializer:
# a write through the pointer changes it), a `volatile` one, and a `static` one (another call writes it). The address
# passed as the flag of a CC_ACQUIRES_IF (`flags`, by the id of the `&x`) is not one: the call sets the flag, and the
# mark says what it means.
def opaque_of(keys: Map[String, String], nodes: List[Json], flags: Set[String]) -> Set[String]
  found: Set[String] = Set.new([])
  for node in nodes
    kind = Ast.kind(node)
    if kind == "VarDecl"
      type = Ast.text(JSON.get(node, "type").unwrap_or(JSON.from("")), "qualType")
      if Ast.text(node, "storageClass") == "static" or type.include?("volatile")
        found = found.add(declared_key(keys, node))
      end
    elsif kind == "UnaryOperator" and Ast.text(node, "opcode") == "&" and not flags.include?(Ast.text(node, "id"))
      root = storage_root(keys, Ast.children(node).first)
      if root != ""
        found = found.add(root)
      end
    end
  end

  found
end

# The keys of the variables that the condition of an `if`, a loop or a switch reads when the statement holds a call
# that takes or releases a lock, or a way out (`return`, `goto`, `break`, `continue`): only such a test can change
# what a path does with a lock, so only its variables get a fact from a constant written to them. The `else if` of an
# `if` is a statement of its own. The flag passed to a CC_RELEASES_IF is such a test too.
def guarded_of(ctx: Context, keys: Map[String, String], nodes: List[Json]) -> Set[String]
  found: Set[String] = Set.new([])
  for node in nodes
    at = GUARDS.get(Ast.kind(node), -1)
    if at >= 0
      parts = Ast.children(node)
      inside = parts
      if Ast.kind(node) == "IfStmt" and parts.size > 2 and Ast.kind(parts[2]) == "IfStmt"
        inside = parts.take(2)
      end

      if at < parts.size and inside.any? do |part| locks?(ctx, part) or leaves?(part) end
        found = found.union(Set.new(roots_of(keys, parts[at])))
      end
    elsif Ast.kind(node) == "CallExpr"
      # The flag of a CC_RELEASES_IF is a test that guards its release.
      args = Ast.children(node).drop(1)
      for i in flag_places(ctx, callee_name(node), false)
        if i < args.size
          found = found.union(Set.new(roots_of(keys, args[i])))
        end
      end
    end
  end

  found
end

# The ids of the `&x` that the calls among `nodes` pass as the flag of a CC_ACQUIRES_IF (`lock_if(q, &locked)`).
def flag_addresses(ctx: Context, nodes: List[Json]) -> Set[String]
  found: Set[String] = Set.new([])
  for node in nodes
    next if Ast.kind(node) != "CallExpr"

    args = Ast.children(node).drop(1)
    for at in flag_places(ctx, callee_name(node), true)
      next if at >= args.size

      arg = see_through(args[at])
      if Ast.kind(arg) == "UnaryOperator" and Ast.text(arg, "opcode") == "&"
        found = found.add(Ast.text(arg, "id"))
      end
    end
  end

  found
end

# The places of the parameters that a function names as the flag of its CC_ACQUIRES_IF (`takes`) or its
# CC_RELEASES_IF.
def flag_places(ctx: Context, name: String, takes: Bool) -> List[Int]
  return [] if name == ""

  case ctx.callees.get(key_of_function(ctx, name))
    some(callee) ->
      flagged = callee.locks.select do |lock| lock.flag != "" and lock.takes == takes end
      flagged.flat_map do |lock| (0...lock.params.size).to_a.select do |i| lock.params[i] == lock.flag end end
    none -> []
  end
end

# Whether a statement holds a way out of it.
def leaves?(node: Json) -> Bool = WAYS_OUT.include?(Ast.kind(node)) or Ast.children(node).any?(&leaves?)

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

  values.select do |name, _value| not written.include?(name) end
end

# Whether a node writes the variable of its first child: an assignment, `++`, `--`, or `&`, which lends it.
def writes?(node: Json) -> Bool
  opcode = Ast.text(node, "opcode")
  case Ast.kind(node)
    "BinaryOperator" -> ASSIGNMENTS.include?(opcode)
    "CompoundAssignOperator" -> true
    "UnaryOperator" -> opcode == "++" or opcode == "--" or opcode == "&"
    _ -> false
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

  found
end

def statement(b: Builder, node: Json, preds: List[Int]) -> Built
  case Ast.kind(node)
    "" -> Built(b: b, exits: preds)
    "CompoundStmt" -> block(b, node, preds)
    "IfStmt" -> if_statement(b, node, preds)
    "WhileStmt" -> while_loop(b, node, preds)
    "DoStmt" -> do_loop(b, node, preds)
    "ForStmt" -> for_loop(b, node, preds)
    "SwitchStmt" -> switch_statement(b, node, preds)
    "CaseStmt" -> case_label(b, node, preds, "case")
    "DefaultStmt" -> case_label(b, node, preds, "default")
    "BreakStmt" -> break_statement(b, node, preds)
    "ContinueStmt" -> continue_statement(b, node, preds)
    "ReturnStmt" -> return_statement(b, node, preds)
    "GotoStmt" -> goto_statement(b, node, Ast.text(node, "targetLabelDeclId"), preds)
    "IndirectGotoStmt" -> goto_statement(b, node, "", preds)
    "LabelStmt" ->
      label = labelled(b, node, preds)
      statement(label.b, last_child(node), label.exits)
    "AttributedStmt" -> statement(b, last_child(node), preds)
    "DeclStmt" ->
      declared = declarations(b, node, preds)
      flushed(declared.b, node, declared.exits)
    "NullStmt" -> Built(b: b, exits: preds)
    "GCCAsmStmt" ->
      # An operand of `asm` may read or write a whole local struct (`"r"(&p)`, `"r"(p.inner)`): an escape of it. A
      # field of it (`p.n`) is no read of the struct.
      built = Built(b: b, exits: preds)
      inside = descendants(Ast.children(node))
      # The item of an array that a field is in (`a[0].left`) and the array under it are no read of the array either.
      fields = inside.select do |n| struct_of(n) != "" end
      structs = fields.map do |n| see_through(Ast.children(n).first) end
      under_structs = structs.flat_map do |base|
        [base].concat(Ast.children(base).take(1).flat_map do |under| [under, see_through(under)] end)
      end

      bases = Set.new(under_structs.map do |base| Ast.text(base, "id") end)

      refs = inside.select do |n|
        (Ast.kind(n) == "DeclRefExpr" or whole_key(b, n) != "") and not bases.include?(Ast.text(n, "id"))
      end

      for ref in refs
        built = escaped(built.b, ref, built.exits)
      end

      built
    _ ->
      done = expression(b, node, preds)
      flushed(done.b, node, done.exits)
  end
end

# The label of a `LabelStmt`: the paths join there, and a `goto` finds it.
def labelled(b: Builder, node: Json, preds: List[Int]) -> Built
  label = add(b, Event.Join, preds)
  Built(b: label.b.with(labels: label.b.labels.put(Ast.text(node, "declId"), label.exits.first)), exits: label.exits)
end

# The end of a full statement (`node`): the pointers of its statement expressions close there (`pending`). One that a
# variable still stands for stays, so they close again with the block around the statement, where that variable may
# close with them.
def flushed(b: Builder, node: Json, preds: List[Int]) -> Built
  return Built(b: b, exits: preds) if b.pending.empty?

  scopes = b.scopes
  if not scopes.empty?
    scope = scopes.last
    added = b.pending.select do |name| not scope.declared.include?(name) end
    scopes = scopes.set(scopes.size - 1, scope.with(declared: scope.declared.concat(added)))
  end

  place = Ast.end_of(node)
  mark = Mark(word: "ends", line: place.line, column: place.column)
  closes_at(b.with(pending: [], scopes: scopes), b.pending, mark, preds)
end

# `flushed` on both sides of a condition (`node`) of a statement.
def flushed_split(split: Split, node: Json) -> Split
  yes = flushed(split.b, node, split.yes)
  no = flushed(yes.b.with(pending: split.b.pending), node, split.no)
  Split(b: no.b, yes: yes.exits, no: no.exits)
end

# A close of the pointers `names` at `mark` after `preds`; nothing for no names, or no node before it.
def closes_at(b: Builder, names: List[String], mark: Mark, preds: List[Int]) -> Built
  return Built(b: b, exits: preds) if names.empty? or preds.empty?

  add(b, Event.Closes(Closing(names: names, mark: mark)), preds)
end

# The block of a statement expression `({ ...; v; })` opens as a scope for the cleanups of its variables.
def opened_expression(b: Builder, node: Json) -> Builder
  inner = last_child(see_through(node))
  scope = Scope(id: Ast.text(inner, "id"), cleanups: [], outer: b.pending)
  b.with(scopes: b.scopes.push(scope), pending: [])
end

# A statement expression (`node`, with statements) up to its value: its scope opened, and its statements run but the
# expression of the last one, under the labels on it (`done: p;`). A last statement that is not an expression runs
# too, and gives no value.
def valued_expression(b: Builder, node: Json, preds: List[Int]) -> Valued
  statements = Ast.children(last_child(node))
  opened = opened_expression(b, node)
  built = in_order_statements(opened, statements.take(statements.size - 1), preds)
  last_value(built.b, statements.last, built.exits)
end

def last_value(b: Builder, node: Json, preds: List[Int]) -> Valued
  kind = Ast.kind(node)
  if kind == "LabelStmt"
    label = labelled(b, node, preds)
    return last_value(label.b, last_child(node), label.exits)
  end

  return last_value(b, last_child(node), preds) if kind == "AttributedStmt"

  if kind.end_with?("Stmt")
    built = statement(b, node, preds)
    return Valued(b: built.b, exits: built.exits, value: JSON.from(""))
  end

  Valued(b: b, exits: preds, value: node)
end

# The end of the block of a statement expression: the cleanups of its variables run, and its pointers close at the end
# of the statement around it (`pending`), as its value outlives the block.
def closed_expression(b: Builder, preds: List[Int]) -> Built
  scope = b.scopes.last
  called = calls(b, scope.cleanups.reverse, preds)
  Built(
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

  closed(built.b, node, built.exits)
end

# The way out of the innermost scope (`node`) at its end: its cleanup calls, the close of its pointers, and the scope
# gone.
def closed(b: Builder, node: Json, preds: List[Int]) -> Built
  place = Ast.end_of(node)
  left = leaving(b, b.scopes.size - 1, preds, some(Mark(word: "ends", line: place.line, column: place.column)))
  Built(b: left.b.with(scopes: left.b.scopes.take(left.b.scopes.size - 1)), exits: left.exits)
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
    return Built(b: then_part.b, exits: exits.concat(split.no)) if not Ast.flag?(current, "hasElse")

    if Ast.kind(parts[2]) != "IfStmt"
      else_part = statement(then_part.b, parts[2], split.no)
      return Built(b: else_part.b, exits: exits.concat(else_part.exits))
    end

    current = parts[2]
    built = then_part.b
    pending = split.no
  end

  Built(b: built, exits: exits)
end

def while_loop(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  head = add(b, Event.Join, preds)
  split = flushed_split(condition(head.b, parts[0], head.exits), parts[0])
  looped(split.b, parts[1], split, head.exits.first, JSON.from(""))
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
  Built(b: link(split.b, split.yes, head.exits.first), exits: split.no.concat(jump.breaks))
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
  closed(ran.b, node, ran.exits)
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
  Built(b: link(stepped.b, stepped.exits, head), exits: split.no.concat(jump.breaks))
end

def loop_jump(b: Builder, head: Int) -> Jump
  Jump(switch: false, head: head, depth: b.scopes.size, breaks: [], continues: [], defaulted: false)
end

# A switch jumps from its head to each `case` and `default` of its body; without a `default`, a value that no case
# names goes past the body.
def switch_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  evaluated = expression(b, parts[0], preds)
  value = flushed(evaluated.b, parts[0], evaluated.exits)
  head = add(value.b, Event.Join, value.exits)
  keys = head.b.owners.places.keys
  source = copied(head.b, parts[0])
  text = written_text(head.b, source, false, keys, 0)
  subject: Optional[Fact] = none
  if text != ""
    fact = Fact(
      text: text,
      value: false,
      roots: roots_of(keys, source),
      line: 0,
      column: 0,
      word: "case",
      single: true,
    )

    subject = some(fact)
  end

  zero = zero_case?(parts[1])
  jump = Jump(
    switch: true,
    head: head.exits.first,
    depth: head.b.scopes.size,
    breaks: [],
    continues: [],
    defaulted: false,
    subject: subject,
    zero: zero,
  )

  body = statement(head.b.with(jumps: head.b.jumps.push(jump)), parts[1], [])
  done = body.b.jumps.last
  closed = body.b.with(jumps: body.b.jumps.take(body.b.jumps.size - 1))
  exits = body.exits.concat(done.breaks)
  return Built(b: closed, exits: exits) if done.defaulted

  place = Ast.start_of(node)
  missed = add(closed, label_event(done, "no case", none, place), head.exits)
  Built(b: missed.b, exits: exits.concat(missed.exits))
end

# The node where a switch goes to a label (or past its body, "no case"): the value of its subject where the label
# tells it, a step that shows the label otherwise. `case 0` tells that the subject is 0 and another number (`number`)
# that it is not, and so do `default` and no case when the switch has a `case 0`.
def label_event(jump: Jump, word: String, number: Optional[String], place: Ast.Place) -> Event
  shown = Event.Note(Mark(word: word, line: place.line, column: place.column))
  case jump.subject
    some(subject) ->
      fact = subject.with(value: true, word: word, line: place.line, column: place.column)
      case number
        some(value) -> return Event.Branch(fact.with(value: value != "0"))
        none -> return shown if word == "case" or not jump.zero
      end

      Event.Branch(fact)
    none -> shown
  end
end

# Whether the body of a switch has a `case 0` of its own, not one of a switch inside it.
def zero_case?(node: Json) -> Bool
  return false if Ast.kind(node) == "SwitchStmt"

  parts = Ast.children(node)
  if Ast.kind(node) == "CaseStmt" and parts.size == 2
    number = see_through(parts.first)
    return true if Ast.kind(number) == "IntegerLiteral" and Ast.text(number, "value") == "0"
  end

  parts.any?(&zero_case?)
end

def case_label(b: Builder, node: Json, preds: List[Int], word: String) -> Built
  at = innermost(b.jumps, true)
  return statement(b, last_child(node), preds) if at < 0

  jump = b.jumps[at]
  place = Ast.start_of(node)
  # A label in a block inside the body of the switch goes into that block, as a `goto` into it does.
  entering = b.with(enters: b.enters or b.scopes.size > jump.depth + 1)
  parts = Ast.children(node)
  literal = see_through(parts.first)
  number: Optional[String] = none
  if word == "case" and parts.size == 2 and Ast.kind(literal) == "IntegerLiteral"
    number = some(Ast.text(literal, "value"))
  end

  marked = add(entering, label_event(jump, word, number, place), [jump.head])
  entry = add(marked.b, Event.Join, preds.concat(marked.exits))
  updated = entry.b.with(jumps: entry.b.jumps.set(at, jump.with(defaulted: jump.defaulted or word == "default")))
  statement(updated, last_child(node), entry.exits)
end

def break_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  at = innermost(b.jumps, false)
  return Built(b: b, exits: []) if at < 0

  left = leaving(b, b.jumps[at].depth, preds, some(mark_at(node, "break")))
  jump = left.b.jumps[at]
  Built(b: left.b.with(jumps: left.b.jumps.set(at, jump.with(breaks: jump.breaks.concat(left.exits)))), exits: [])
end

def continue_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  at = innermost_loop(b.jumps)
  return Built(b: b, exits: []) if at < 0

  left = leaving(b, b.jumps[at].depth, preds, some(mark_at(node, "continue")))
  jump = left.b.jumps[at]
  updated = left.b.jumps.set(at, jump.with(continues: jump.continues.concat(left.exits)))
  Built(b: left.b.with(jumps: updated), exits: [])
end

# The index of the innermost jump a `break` leaves (a loop or a switch), or a `case` belongs to (a switch); -1
# for none.
def innermost(jumps: List[Jump], switch_only: Bool) -> Int
  i = jumps.size - 1
  while i >= 0
    return i if jumps[i].switch or not switch_only

    i -= 1
  end

  -1
end

def innermost_loop(jumps: List[Jump]) -> Int
  i = jumps.size - 1
  while i >= 0
    return i if not jumps[i].switch

    i -= 1
  end

  -1
end

def return_statement(b: Builder, node: Json, preds: List[Int]) -> Built
  value = Built(b: b, exits: preds)
  for child in Ast.children(node)
    value = handed_value(value.b, none, child, value.exits)
  end

  failed = Ast.children(node).any?(&error_value?)
  mark = mark_at(node, "returns").with(failed: failed)
  left = leaving(value.b, 0, value.exits, some(mark))
  ended = add(left.b, Event.Exit(mark), left.exits)
  Built(b: ended.b.with(pending: []), exits: [])
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

  open = Set.new(b.scopes.map do |scope| scope.id end)
  targets = [b.label_blocks.get(label).unwrap_or([])]
  if label == ""
    targets = b.label_blocks.values
  end

  enters = targets.any? do |blocks| blocks.any? do |id| not open.include?(id) end end
  left = leaving(b.with(enters: b.enters or enters), depth, preds, mark)
  jumped = add(left.b, Event.Join, left.exits)
  Built(b: jumped.b.with(gotos: jumped.b.gotos.push(Goto(from: jumped.exits.first, label: label))), exits: [])
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

  linked
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
    some(mark) -> closes_at(called.b, b.pending.concat(names), mark, called.exits)
    none -> called
  end
end

# A mark at the start of a statement.
def mark_at(node: Json, word: String) -> Mark
  place = Ast.start_of(node)
  Mark(word: word, line: place.line, column: place.column)
end

def calls(b: Builder, sites: List[Site], preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for site in sites
    built = add(built.b, Event.Call(site), built.exits)
  end

  built
end

def declarations(b: Builder, node: Json, preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for child in Ast.children(node)
    if Ast.kind(child) == "VarDecl"
      built = declaration(built.b, child, built.exits)
    end
  end

  built
end

# A variable: its value, then the write of it, and its cleanup call for the way out of its block.
def declaration(b: Builder, node: Json, preds: List[Int]) -> Built
  name = Ast.text(node, "name")
  key = declared_key(b.owners.places.keys, node)
  values = Ast.children(node).select do |child| not Ast.kind(child).end_with?("Attr") end
  written = Built(b: b, exits: preds)
  fields = b.owners.places.fields.get(key, [])
  if b.owners.names.include?(key) and values.size == 1
    written = owner_assigned(b, key, values.first, preds)
  elsif not fields.empty? and values.size == 1 and Ast.kind(see_through(values.first)) == "InitListExpr"
    initialized = initializer(b, key, see_through(values.first), preds)
    written = add(initialized.b, Event.Writes([key]), initialized.exits)
  elsif values.size == 1 and keeps?(b, key) and tried_call(b, values.first).some?
    written = kept_result(b, key, tried_call(b, values.first).unwrap!, preds)
  else
    built = in_order(b, values, preds)
    written = add(built.b, Event.Writes([key]), built.exits)
    if values.size == 1
      written = constant_written(written.b, key, values.first, written.exits)
    end
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
  return written if cleanup.empty? or written.b.scopes.empty?

  function = Ast.text(JSON.get(cleanup.first, "cleanup_function").unwrap_or(JSON.from("")), "name")
  place = Ast.place_of(node)
  owner = ""
  if written.b.owners.names.include?(key)
    owner = key
  end

  aliased_class = written.b.aliases.get(name).map do |value| class_of(written.b, value) end
  var = Arg(text: "&#{local_text(written.b, name)}", class: aliased_class.unwrap_or(""), owner: owner, address: true)

  # A cleanup function of a followed struct frees each of its CC_OWNS fields at the end of the block.
  site = site_of(written.b, function, [var], place, false)
  site = site.with(frees: site.frees.concat(written.b.owners.places.fields.get(key, [])))
  scope = written.b.scopes.last
  scopes = written.b.scopes.set(written.b.scopes.size - 1, scope.with(cleanups: scope.cleanups.push(site)))
  Built(b: written.b.with(scopes: scopes), exits: written.exits)
end

# The initializer of a followed struct, or of a struct in it, whose key is `key`: each CC_OWNS field gets its item, and
# null when it has none, and each struct in it gets its own initializer the same way; the other items are read in
# order. A struct in it that gets another value (`{ .inner = q }`) holds what `q` held: its fields are someone else's,
# as after an escape. `held` are the items that a compound literal read before the store (see `reset_by_literal`).
def initializer(b: Builder, key: String, init: Json, preds: List[Int], held: Map[Int, String] = {}) -> Built
  items = Ast.items(init)
  at: Map[Int, String] = {}
  for place in b.owners.places.parts.get(key, [])
    case b.owners.places.items.get(place)
      some(i) -> at = at.put(i, place)
      none -> next
    end
  end

  built = Built(b: b, exits: preds)
  for i in 0...items.size
    place = at.get(i, "")
    item = see_through(items[i])
    if place == ""
      if not held.key?(i)
        built = expression(built.b, items[i], built.exits)
      end
    elsif b.owners.places.parts.key?(place)
      if held.key?(i)
        built = add(built.b, Event.Escapes(built.b.owners.places.fields.get(place, [])), built.exits)
      elsif Ast.kind(item) == "InitListExpr"
        built = initializer(built.b, place, item, built.exits)
      elsif Ast.kind(item) == "ImplicitValueInitExpr"
        built = nulled_struct(built.b, place, init, built.exits)
      else
        read = expression(built.b, items[i], built.exits)
        built = add(read.b, Event.Escapes(read.b.owners.places.fields.get(place, [])), read.exits)
      end
    elsif held.key?(i)
      built = moved_field(built.b, place, held[i], items[i], built.exits)
    elsif Ast.kind(items[i]) != "ImplicitValueInitExpr"
      built = owner_assigned(built.b, place, items[i], built.exits)
    else
      built = nulled_field(built.b, place, init, built.exits)
    end
  end

  for i in at.keys.sort
    if i >= items.size
      built = nulled_struct(built.b, at[i], init, built.exits)
    end
  end

  built
end

# A CC_OWNS field, or each one of a struct in the struct, that an initializer leaves out: it is null.
def nulled_struct(b: Builder, place: String, init: Json, preds: List[Int]) -> Built
  return nulled_field(b, place, init, preds) if not b.owners.places.parts.key?(place)

  built = Built(b: b, exits: preds)
  for field in b.owners.places.fields.get(place, [])
    built = nulled_field(built.b, field, init, built.exits)
  end

  built
end

# A field that takes the value an item of a compound literal held before the store (`held`).
def moved_field(b: Builder, place: String, temp: String, item: Json, preds: List[Int]) -> Built
  at = Ast.start_of(item)
  assign = Assign(name: place, value: "moved", from: temp, shown: plain(temp), line: at.line, column: at.column)
  written = add(b, Event.Writes([place]), preds)
  add(written.b, Event.Assigns(assign), written.exits)
end

# A CC_OWNS field that an initializer leaves out: it is null.
def nulled_field(b: Builder, place: String, init: Json, preds: List[Int]) -> Built
  at = Ast.start_of(init)
  assign = Assign(name: place, value: "null", from: "", shown: "NULL", line: at.line, column: at.column)
  written = add(b, Event.Writes([place]), preds)
  add(written.b, Event.Assigns(assign), written.exits)
end

def expression(b: Builder, node: Json, preds: List[Int]) -> Built
  case Ast.kind(node)
    "" -> Built(b: b, exits: preds)
    "CallExpr" -> call(b, node, preds, false)
    "DeclRefExpr" -> used(b, node, preds)
    "MemberExpr" ->
      return used(b, node, preds) if owner_named(b, node) != ""

      # `p.inner` of a followed struct names a struct in it whole, which escapes there; `p.n` reads a field, which
      # is no escape of the struct (see `item_read`).
      return escaped(b, node, preds) if whole_key(b, node) != ""

      return item_read(b, node, preds) if struct_of(node) != ""

      in_order(b, Ast.children(node), preds)
    "ArraySubscriptExpr" ->
      # `a[0]` of a followed array names an item whole, which escapes there.
      return escaped(b, node, preds) if whole_key(b, node) != ""

      in_order(b, Ast.children(node), preds)
    "BinaryOperator" ->
      opcode = Ast.text(node, "opcode")
      if opcode == "&&" or opcode == "||"
        split = condition(b, node, preds)
        return Built(b: split.b, exits: split.yes.concat(split.no))
      end

      return assignment(b, node, preds) if ASSIGNMENTS.include?(opcode)

      in_order(b, Ast.children(node), preds)
    "CompoundAssignOperator" -> assignment(b, node, preds)
    "UnaryOperator" ->
      opcode = Ast.text(node, "opcode")
      operand = Ast.children(node).first
      lent = owner_named(b, operand)
      if opcode == "&" and lent != ""
        # `&p` lends the pointer itself, to be set: what it owns after that is not known.
        written = add(b, Event.Writes([lent]), preds)
        return add(written.b, Event.Lends([lent]), written.exits)
      end

      # The address of an item of a followed array (`&a[0]`, which `unfollowed_arrays` allows only at a `memset` or a
      # CC_FREES parameter) may reach every item: the whole array escapes.
      item = see_through(operand)
      inner = Built(b: b, exits: preds)
      if opcode == "&" and Ast.kind(item) == "ArraySubscriptExpr" and whole_key(b, Ast.children(item).first) != ""
        inner = in_order(b, Ast.children(item), preds)
      else
        inner = expression(b, operand, preds)
      end

      return add(inner.b, Event.Writes(written_roots(b, operand)), inner.exits) if opcode == "++" or opcode == "--"

      # The address of a variable lets a callee change it; the address of `q->mu` does not change `q`.
      root = storage_root(b.owners.places.keys, operand)
      return add(inner.b, Event.Writes([root]), inner.exits) if opcode == "&" and root != ""

      inner
    "ConditionalOperator" ->
      parts = Ast.children(node)
      split = condition(b, parts[0], preds)
      chosen = expression(split.b, parts[1], split.yes)
      other = expression(chosen.b, parts[2], split.no)
      Built(b: other.b, exits: chosen.exits.concat(other.exits))
    "BinaryConditionalOperator" ->
      # `x ?: y`: the value of `x` when it is true, else `y`.
      parts = Ast.children(node)
      split = condition(b, parts[0], preds)
      other = expression(split.b, parts.last, split.no)
      Built(b: other.b, exits: split.yes.concat(other.exits))
    "InitListExpr" ->
      # A pointer that owns, put in a CC_OWNS field by an initializer or a compound literal, is handed on to it; in any
      # other item it is only read.
      owning = owning_items(b.ctx, node)
      built = Built(b: b, exits: preds)
      items = Ast.children(node)
      for i in 0...items.size
        item = items[i]
        if owning.include?(i) and owner_named(built.b, item) != ""
          built = handed_on(built.b, some("an initializer"), item, built.exits)
        else
          built = expression(built.b, item, built.exits)
        end
      end

      built
    "StmtExpr" ->
      opened = opened_expression(b, node)
      built = in_order_statements(opened, Ast.children(last_child(node)), preds)
      closed_expression(built.b, built.exits)
    "UnaryExprOrTypeTraitExpr" -> Built(b: b, exits: preds)
    _ -> in_order(b, Ast.children(node), preds)
  end
end

# A field of a local struct that the rules do not follow as a pointer (`p.n`, `a[0].n`): no read of the struct. An
# index that is not a constant (`a[i].n`, of an array that is then not followed) is read.
def item_read(b: Builder, node: Json, preds: List[Int]) -> Built
  base = see_through(Ast.children(node).first)
  while Ast.kind(base) == "MemberExpr"
    base = see_through(Ast.children(base).first)
  end

  return Built(b: b, exits: preds) if Ast.kind(base) != "ArraySubscriptExpr" or whole_key(b, base) != ""

  in_order(b, Ast.children(base), preds)
end

def in_order(b: Builder, nodes: List[Json], preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for node in nodes
    built = expression(built.b, node, built.exits)
  end

  built
end

def in_order_statements(b: Builder, nodes: List[Json], preds: List[Int]) -> Built
  built = Built(b: b, exits: preds)
  for node in nodes
    built = statement(built.b, node, built.exits)
  end

  built
end

# An assignment: the value, then the target. A plain write of a variable does not read it; a pointer that owns gets
# its new value, and one stored in a CC_OWNS place is handed on.
def assignment(b: Builder, node: Json, preds: List[Int]) -> Built
  parts = Ast.children(node)
  if Ast.kind(node) == "BinaryOperator" and Ast.text(node, "opcode") == "=" and parts.size == 2
    name = variable_key(b.owners.places.keys, parts[0])
    return owner_assigned(b, name, parts[1], preds) if b.owners.names.include?(name)

    kept_try = kept_trial(b, node)
    return kept_result(b, name, kept_try.unwrap!, preds) if kept_try.some?

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

      written = add(value.b, Event.Writes([pointed].concat(b.opaque.to_a)), value.exits)
      return add(written.b, Event.Assigns(assign), written.exits)
    end

    handing = place_owns?(b.ctx, parts[0]) or handed_place?(b.owners.places, parts[0])
    if handing and values_of(parts[1]).any? do |value| owner_named(b, value) != "" end
      target = expression(b, parts[0], preds)
      gave = handed_value(target.b, some(text_of(b, parts[0], false)), parts[1], target.exits)
      return add(gave.b, Event.Writes([target_root(b.owners.places.keys, parts[0])]), gave.exits)
    end

    if name != "" or whole_key(b, parts[0]) != ""
      value = case reset_by_literal(b, parts[0], parts[1], preds)
        some(reset) -> reset
        none -> struct_assigned_after(b, parts[0], parts[1], preds)
      end

      written = add(value.b, Event.Writes([target_root(b.owners.places.keys, parts[0])]), value.exits)
      return written if Ast.kind(see_through(parts[0])) != "DeclRefExpr"

      return constant_written(written.b, name, parts[1], written.exits)
    end
  end

  value = in_order(b, parts.drop(1).concat(parts.take(1)), preds)
  add(value.b, Event.Writes(written_roots(b, parts.first)), value.exits)
end

# The variables a write to `target` changes, by key: its root, and for a write through a pointer (`*p = 1`, `p->n =
# 0`) every local whose address the function takes (`Builder.opaque`), which the pointer may reach.
def written_roots(b: Builder, target: Json) -> List[String]
  keys = b.owners.places.keys
  root = target_root(keys, target)
  return [root] if storage_root(keys, target) != "" or b.opaque.empty?

  [root].concat(b.opaque.to_a)
end

# A value handed on: returned (`into` is none) or stored in a place that hands it on (`into`). A pointer that owns is
# handed on there, on its side of a `?:` (`x->held = n ? p : NULL`, `return n ? p : NULL`, `x->held = p ?: q`) or as
# the last expression of a statement expression, the same values as `values_of`.
def handed_value(b: Builder, into: Optional[String], value: Json, preds: List[Int]) -> Built
  bare = see_through(value)
  if Ast.kind(bare) == "ConditionalOperator"
    parts = Ast.children(bare)
    split = condition(b, parts[0], preds)
    chosen = handed_value(split.b, into, parts[1], split.yes)
    other = handed_value(chosen.b, into, parts[2], split.no)
    return Built(b: other.b, exits: chosen.exits.concat(other.exits))
  end

  if Ast.kind(bare) == "BinaryConditionalOperator"
    # `x ?: y`: `x`, read once by the condition, where it is true, else `y`.
    parts = Ast.children(bare)
    split = condition(b, parts.first, preds)
    chosen = Built(b: split.b, exits: split.yes)
    if owner_named(b, parts.first) != ""
      chosen = handed_on(split.b, into, parts.first, split.yes)
    end

    other = handed_value(chosen.b, into, parts.last, split.no)
    return Built(b: other.b, exits: chosen.exits.concat(other.exits))
  end

  if Ast.kind(bare) == "StmtExpr" and not Ast.children(last_child(bare)).empty?
    inner = valued_expression(b, bare, preds)
    last = Built(b: inner.b, exits: inner.exits)
    if Ast.kind(inner.value) != ""
      last = handed_value(inner.b, into, inner.value, inner.exits)
    end

    return closed_expression(last.b, last.exits)
  end

  return expression(b, value, preds) if owner_named(b, value) == ""

  handed_on(b, into, value, preds)
end

# A pointer that owns, `value`, handed on by a return (`into` is none) or to the place `into` by a store.
def handed_on(b: Builder, into: Optional[String], value: Json, preds: List[Int]) -> Built
  given = owner_named(b, value)
  place = Ast.start_of(value)
  stored = into.map do |shown| "stores #{plain(given)} in #{shown}" end
  word = stored.unwrap_or("returns")

  add(b, Event.Gives(Give(name: given, word: word, line: place.line, column: place.column)), preds)
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

  if Ast.kind(bare) == "StmtExpr" and not Ast.children(last_child(bare)).empty?
    # `({ char *q = make(n); ...; q; })`: its statements, then the value of the last one.
    inner = valued_expression(b, bare, preds)
    last = Built(b: inner.b, exits: inner.exits)
    if Ast.kind(inner.value) != ""
      last = owner_assigned(inner.b, name, inner.value, inner.exits)
    end

    return closed_expression(last.b, last.exits)
  end

  assign = assigned(b, name, value)
  built = Built(b: b, exits: preds)
  if assign.value != "moved" and assign.value != "alias"
    built = expression(b, value, preds)
  end

  written = add(built.b, Event.Writes([name]), built.exits)
  add(written.b, Event.Assigns(assign), written.exits)
end

# How a pointer that owns, or may stand for one, gets a value (`Assign`).
def assigned(b: Builder, name: String, value: Json) -> Assign
  place = Ast.start_of(value)
  start = Assign(name: name, value: "other", from: "", shown: "", line: place.line, column: place.column)
  bare = see_through(value)
  marked = b.owners.marked.include?(name)
  return start.with(value: "null", shown: "NULL") if zero?(bare)

  source = owner_named(b, bare)
  if source == ""
    source = pointee_owner(b, bare)
  end

  if source != ""
    # A followed field set from a local stands for the local (an alias): a free of either frees the one pointer.
    if marked and not (followed_field?(b, name) and owner_named(b, bare) == source and not followed_field?(b, source))
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

  start.with(shown: text_of(b, bare, false))
end

# A read of a variable: an event when it is a pointer that owns, or may stand for one, or a local struct whose CC_OWNS
# fields the rules follow, which escapes there (a field of it is no read of the struct: see `expression`).
def used(b: Builder, node: Json, preds: List[Int]) -> Built
  name = owner_named(b, node)
  return escaped(b, node, preds) if name == ""

  place = Ast.start_of(node)
  add(b, Event.Uses(Use(name: name, line: place.line, column: place.column)), preds)
end

# A new value of a whole local struct (`p = q`): each followed CC_OWNS field gets a value the rules do not know, so
# one that still owns leaks there, and then the fields are the new value's, as after an escape.
def struct_assigned(b: Builder, target: Json, value: Json, preds: List[Int]) -> Built
  fields = followed_struct(b, target)
  return Built(b: b, exits: preds) if fields.empty?

  place = Ast.start_of(value)
  shown = text_of(b, value, false)
  if shown == ""
    shown = "a value"
  end

  built = Built(b: b, exits: preds)
  for field in fields
    assign = Assign(name: field, value: "other", from: "", shown: shown, line: place.line, column: place.column)
    built = add(built.b, Event.Assigns(assign), built.exits)
  end

  add(built.b, Event.Escapes(fields), built.exits)
end

# The value of a variable that is not a pointer that owns, then what it does to a whole local struct (`p = q`).
def struct_assigned_after(b: Builder, target: Json, value: Json, preds: List[Int]) -> Built
  read = expression(b, value, preds)
  struct_assigned(read.b, target, value, read.exits)
end

# `p = (struct pair){ ... }` of a followed struct: the fields are followed again, and each gets its item as from an
# initializer (null when it has none), so one that still owned leaks there; none for any other assignment.
def reset_by_literal(b: Builder, target: Json, value: Json, preds: List[Int]) -> Optional[Built]
  fields = followed_struct(b, target)
  bare = see_through(value)
  return none if fields.empty? or Ast.kind(bare) != "CompoundLiteralExpr"

  init = see_through(Ast.children(bare).first)
  return none if Ast.kind(init) != "InitListExpr"

  # C evaluates the whole literal before it stores the struct. An item that reads a field of the struct other than
  # by naming it (`p.left ? p.left : make(n)`, `steal(p.left)`) is read first: into a place of its own when it goes to
  # a CC_OWNS field, else as an expression, which the initializer then leaves (`held` maps it to ""). Then an item that
  # names a field (`.left = p.right`) is moved to a place of its own. The field of each takes its place.
  items = Ast.children(init)
  key = whole_key(b, target)
  places: Map[Int, String] = {}
  for place in b.owners.places.parts.get(key, [])
    case b.owners.places.items.get(place)
      some(i) -> places = places.put(i, place)
      none -> next
    end
  end

  built = Built(b: b, exits: preds)
  held: Map[Int, String] = {}
  for i in 0...items.size
    if not fields.include?(owner_named(built.b, items[i])) and reads_field?(built.b, items[i], fields)
      place = places.get(i, "")
      if place == "" or b.owners.places.parts.key?(place)
        built = expression(built.b, items[i], built.exits)
        held = held.put(i, "")
      else
        temp = "#{place}#{KEY_MARK}9#{i}"
        built = owner_assigned(built.b, temp, items[i], built.exits)
        held = held.put(i, temp)
      end
    end
  end

  for i in 0...items.size
    source = owner_named(built.b, items[i])
    if fields.include?(source)
      place = Ast.start_of(items[i])
      temp = "#{source}#{KEY_MARK}9#{i}"
      assign = Assign(
        name: temp,
        value: "moved",
        from: source,
        shown: plain(source),
        line: place.line,
        column: place.column,
      )

      built = add(built.b, Event.Assigns(assign), built.exits)
      held = held.put(i, temp)
    end
  end

  reset = add(built.b, Event.Resets(fields), built.exits)
  stored = initializer(reset.b, key, init, reset.exits, held)
  return some(stored) if held.empty?

  closing = Closing(names: held.values.select do |temp| temp != "" end, mark: mark_at(init, "ends"))
  some(add(stored.b, Event.Closes(closing), stored.exits))
end

# Whether a fill byte is zero: `0` or `'\0'`.
def zero_byte?(node: Json) -> Bool
  bare = see_through(node)
  zero?(bare) or (Ast.kind(bare) == "CharacterLiteral" and Ast.number(bare, "value") == 0)
end

# Whether the size of a `memset` of `&p` (or `&p.inner`) is that of the whole struct: `sizeof p`, `sizeof(struct pair)`
# or the size of a typedef of it. A smaller size clears some of the fields only, and stays an escape. A followed array
# (`memset(a, 0, sizeof a)`) is cleared by `sizeof a` only.
def whole_size?(b: Builder, target: Json, size: Json) -> Bool
  bare = see_through(size)
  return false if Ast.kind(bare) != "UnaryExprOrTypeTraitExpr" or Ast.text(bare, "name") != "sizeof"

  pointed = see_through(target)
  if address?(target)
    pointed = see_through(Ast.children(pointed).first)
  end

  whole = whole_key(b, pointed)
  measured = Ast.children(bare)
  return whole != "" and whole_key(b, measured.first) == whole if not measured.empty?

  return false if not address?(target) or b.ctx.owning.lengths.key?(Ast.referenced_id(pointed))

  # The record of a variable by its declaration, of a struct in it by its field.
  id = Ast.referenced_id(pointed)
  if Ast.kind(pointed) == "MemberExpr"
    id = Ast.text(pointed, "referencedMemberDecl")
  end

  record = b.ctx.owning.typed.get(id)
  record.some? and b.ctx.owning.typed.get(Ast.text(bare, "id")) == record
end

# Whether an expression reads one of the followed fields `fields` (`p.left`) anywhere in it.
def reads_field?(b: Builder, node: Json, fields: List[String]) -> Bool
  return true if Ast.kind(node) == "MemberExpr" and fields.include?(b.owners.places.keys.get(Ast.text(node, "id"), ""))

  Ast.children(node).any? do |child| reads_field?(b, child, fields) end
end

# Whether a key is that of a followed CC_OWNS field of a local struct (`p.left`).
def followed_field?(b: Builder, key: String) -> Bool
  b.owners.places.fields.values.any? do |places| places.include?(key) end
end

# The followed CC_OWNS fields of the local struct, or the struct in it (`p.inner`), that an expression names whole, or
# none.
def followed_struct(b: Builder, node: Json) -> List[String] = b.owners.places.fields.get(whole_key(b, node), [])

# The key of the followed local struct (`p`), of the struct in it (`p.inner`), of a followed array (`a`) or of an item
# of it (`a[0]`), that an expression names whole; "".
def whole_key(b: Builder, node: Json) -> String
  bare = see_through(node)
  if Ast.kind(bare) == "MemberExpr" or Ast.kind(bare) == "ArraySubscriptExpr"
    return b.owners.places.wholes.get(Ast.text(bare, "id"), "")
  end

  return "" if Ast.kind(bare) != "DeclRefExpr"

  key = variable_key(b.owners.places.keys, bare)
  return key if b.owners.places.fields.key?(key)

  ""
end

# The followed CC_OWNS fields of the local struct whose address an expression is (`&p`), or none.
def struct_address(b: Builder, node: Json) -> List[String]
  bare = see_through(node)
  return [] if not address?(bare)

  followed_struct(b, Ast.children(bare).first)
end

# The followed CC_OWNS fields of what a `memset` clears: the struct whose address it gets (`&p`), or a followed array
# that it gets whole (`a`).
def cleared_struct(b: Builder, node: Json) -> List[String]
  bare = see_through(node)
  return followed_struct(b, bare) if Ast.kind(bare) == "DeclRefExpr"

  struct_address(b, bare)
end

# `memset(&p, 0, sizeof p)` of a followed struct: its fields are followed again, null, so one that still owned leaks
# there.
def cleared(b: Builder, fields: List[String], node: Json, preds: List[Int]) -> Built
  at = Ast.start_of(node)
  built = add(b, Event.Resets(fields), preds)
  for field in fields
    assign = Assign(name: field, value: "null", from: "", shown: "NULL", line: at.line, column: at.column)
    written = add(built.b, Event.Writes([field]), built.exits)
    built = add(written.b, Event.Assigns(assign), written.exits)
  end

  built
end

# The followed CC_OWNS fields of a local struct that an expression names whole, which escape there; nothing for any
# other expression.
def escaped(b: Builder, node: Json, preds: List[Int]) -> Built
  fields = followed_struct(b, node)
  return Built(b: b, exits: preds) if fields.empty?

  add(b, Event.Escapes(fields), preds)
end

# The pointer that owns, or may stand for one, that an expression is, through casts and parentheses; "".
def owner_named(b: Builder, node: Json) -> String
  name = variable_key(b.owners.places.keys, node)
  return name if b.owners.names.include?(name)

  ""
end

# The pointer that owns an argument names: `p`, `&p` (a cleanup function, or a function that frees through a pointer
# to it) or `*p`, also as the last expression of a statement expression; "" for none, or for a `?:`.
def owner_of(b: Builder, node: Json) -> String
  bare = see_through(single_value(node))
  return owner_named(b, Ast.children(bare).first) if address?(bare)

  pointed = pointee_owner(b, bare)
  return pointed if pointed != ""

  owner_named(b, bare)
end

# The one value of an expression (`values_of`): the last expression of a statement expression, or the expression
# itself, also when it may have several (`?:`).
def single_value(node: Json) -> Json
  values = values_of(node)
  return values.first if values.size == 1

  node
end

# Whether an expression takes the address of something: `&x`.
def address?(node: Json) -> Bool
  bare = see_through(node)
  Ast.kind(bare) == "UnaryOperator" and Ast.text(bare, "opcode") == "&"
end

# The CC_FREES parameter that `*p` stands for when the parameter points to the pointer it frees (`T **p`, a cleanup
# function); "" for any other.
def pointee_owner(b: Builder, node: Json) -> String = pointee_param(b.owners.places.keys, node, b.owners.places.freed)

# The parameter in `freed` that `*p` is, when `*p` is itself a pointer; "" for any other expression.
def pointee_param(keys: Map[String, String], node: Json, freed: Set[String]) -> String
  bare = see_through(node)
  return "" if Ast.kind(bare) != "UnaryOperator" or Ast.text(bare, "opcode") != "*" or not pointer_type?(bare)

  name = variable_key(keys, Ast.children(bare).first)
  return "" if not freed.include?(name)

  name
end

# Whether the type of an expression is a pointer, as written or behind a typedef, `const` or not (`char *const`).
def pointer_type?(node: Json) -> Bool
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  [Ast.text(type, "qualType"), Ast.text(type, "desugaredQualType")].any? do |text| unqualified(text).end_with?("*") end
end

# A call: its arguments in order, then the call. A call that never comes back ends the path. `tried` leaves out the
# lock that a call of `Known.TRIES` takes: the condition around it takes it on the branch where it worked.
def call(b: Builder, node: Json, preds: List[Int], tried: Bool) -> Built
  parts = Ast.children(node)
  return Built(b: b, exits: preds) if parts.empty?

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
    return Built(b: through.b, exits: []) if site.stops

    return through
  end

  # A pointer that the call frees or takes is not read by it, nor one whose address it gets to hand an owned pointer
  # out through.
  name = Ast.referenced_name(callee)
  return Built(b: b, exits: preds) if Known.UNEVALUATED.include?(name)

  taking = taken(b.ctx, name, key_of_function(b.ctx, name))
  filling = out_params(b.ctx, name)
  # `pair_free(&p)` at a CC_FREES parameter frees the fields of a followed struct, and `memset(&p, 0, sizeof p)` clears
  # them: neither is an escape of the struct.
  frees_fields = b.ctx.owning.frees.get(key_of_function(b.ctx, name), [])
  clearing: List[String] = []
  if Known.FILLS.include?(name) and args.size > 2 and zero_byte?(args[1]) and whole_size?(b, args[0], args[2])
    clearing = cleared_struct(b, args[0])
  end

  # A followed struct passed by value to a CC_OWNS parameter hands its fields on to the callee.
  handing = b.ctx.owning.takes.get(key_of_function(b.ctx, name), [])
  struct_freed: List[String] = []
  struct_handed: List[String] = []
  built = Built(b: b, exits: preds)
  for i in 0...args.size
    fields = struct_address(built.b, args[i])
    if frees_fields.include?(i) and not fields.empty?
      # As for `free_and_null(&p)`, the helper is taken to null what it frees: a condition on a field is forgotten.
      struct_freed = struct_freed.concat(fields)
      built = add(built.b, Event.Writes(fields), built.exits)
      later = later_items(built.b, args[i])
      if not later.empty?
        built = add(built.b, Event.Escapes(later), built.exits)
      end
    elsif handing.include?(i) and record_type?(args[i]) and not followed_struct(built.b, args[i]).empty?
      struct_handed = struct_handed.concat(followed_struct(built.b, args[i]))
    elsif i == 0 and not clearing.empty?
      next
    else
      built = argument(built.b, args[i], taking.include?(i), filling.include?(i), built.exits)
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

  site = site.with(
    frees: site.frees.concat(struct_freed),
    clears: site.clears.concat(struct_freed),
    hands: site.hands.concat(struct_handed),
  )

  called = flagged_call(built.b, site, args, built.exits)
  return Built(b: called.b, exits: []) if site.stops

  return cleared(called.b, clearing, node, called.exits) if not clearing.empty?

  called
end

# The call of `site`, on each side of the flags of the CC_ACQUIRES_IF and CC_RELEASES_IF of its function: before the
# call, a node for each value of the flag, then the call with the lock taken or released where the flag is not 0. A
# function with no such mark is one call. The flag of a take is the local whose address the call gets (`&locked`): it
# gets the value there, as a write, which a later test of it reads; a flag that is no local of the function (`&b->f`,
# a pointer it was passed) splits the path with no value a test can read. The flag of a release is a test of the
# argument, as an `if` reads it, and a constant flag takes one side.
def flagged_call(b: Builder, site: Site, args: List[Json], preds: List[Int]) -> Built
  flagged = case b.ctx.callees.get(site.key)
    some(callee) -> callee.locks.select do |lock| lock.flag != "" end
    none -> []
  end

  return add(b, Event.Call(site), preds) if flagged.empty?

  texts = args.map do |arg| text_of(b, arg, true) end
  sides = [Flagged(exits: preds, takes: [], drops: [])]
  built = b
  for lock in flagged
    locks = annotated_lock(lock, texts)
    places = (0...lock.params.size).to_a.select do |i| lock.params[i] == lock.flag end
    # The mark names a parameter (`Unit.function_mark_error`); with none, the flag is no argument of the call.
    at = args.size
    if not places.empty?
      at = places.first
    end

    split = Split(b: built, yes: [], no: [])
    grown: List[Flagged] = []
    for side in sides
      split = flag_split(split.b, site, lock.takes, locks, args, at, side.exits)
      if not split.yes.empty? and lock.takes
        grown = grown.push(side.with(exits: split.yes, takes: side.takes.concat(locks), acts: true))
      elsif not split.yes.empty?
        grown = grown.push(side.with(exits: split.yes, drops: side.drops.concat(locks), acts: true))
      end

      if not split.no.empty?
        grown = grown.push(side.with(exits: split.no))
      end
    end

    built = split.b
    sides = grown
  end

  exits: List[Int] = []
  for side in sides
    idle = not side.acts and site.takes.empty? and site.drops.empty? and site.waits.empty?
    called = add(
      built,
      Event.Call(site.with(takes: site.takes.concat(side.takes), drops: site.drops.concat(side.drops), idle: idle)),
      side.exits,
    )

    built = called.b
    exits = exits.concat(called.exits)
  end

  Built(b: built, exits: exits)
end

# The two sides of the flag of one lock of a call (`at` is the place of the argument): where the call takes (`takes`)
# or releases `locks`, and where it does not.
def flag_split(
  b: Builder,
  site: Site,
  takes: Bool,
  locks: List[Lock],
  args: List[Json],
  at: Int,
  preds: List[Int],
) -> Split
  place_fact = Fact(text: "", value: true, roots: [], line: site.line, column: site.column, quiet: true)
  if at >= args.size
    yes = add(b, Event.Branch(place_fact), preds)
    no = add(yes.b, Event.Branch(place_fact.with(value: false)), preds)
    return Split(b: no.b, yes: yes.exits, no: no.exits)
  end

  return released_split(b, place_fact, args[at], preds) if not takes

  arg = see_through(args[at])
  keys = b.owners.places.keys
  written = Built(b: b, exits: preds)
  fact = place_fact.with(written: true)
  if Ast.kind(arg) == "UnaryOperator" and Ast.text(arg, "opcode") == "&"
    target = Ast.children(arg).first
    written = add(b, Event.Writes(written_roots(b, target)), preds)
    key = variable_key(keys, target)
    if Ast.kind(see_through(target)) == "DeclRefExpr" and keeps?(b, key)
      fact = fact.with(text: key, roots: [key])
    end
  else
    # A pointer the function was passed: the call writes what it points to, which any local whose address the
    # function takes may be.
    written = add(b, Event.Writes([target_root(keys, arg)].concat(b.opaque.to_a)), preds)
  end

  shown = locks.map do |lock| lock.shown end
  taken = add(written.b, Event.Branch(fact), written.exits)
  word = "does not take #{shown.join(", ")}"
  if shown.empty?
    word = "does not take its lock"
  end

  other = fact.with(value: false, quiet: false, word: word, failed: locks)
  missed = add(taken.b, Event.Branch(other), written.exits)
  Split(b: missed.b, yes: taken.exits, no: missed.exits)
end

# The two sides of the flag of a CC_RELEASES_IF: the argument read as the test of an `if` (`fact_of`), quiet, as the
# call tests it; a constant takes one side.
def released_split(b: Builder, place_fact: Fact, arg: Json, preds: List[Int]) -> Split
  bare = see_through(arg)
  if Ast.kind(bare) == "IntegerLiteral"
    return Split(b: b, yes: [], no: preds) if Ast.text(bare, "value") == "0"

    return Split(b: b, yes: preds, no: [])
  end

  fact = fact_of(b, bare).with(line: place_fact.line, column: place_fact.column, quiet: true)
  yes = add(b, Event.Branch(fact), preds)
  no = add(yes.b, Event.Branch(fact.with(value: not fact.value)), preds)
  Split(b: no.b, yes: yes.exits, no: no.exits)
end

# The followed CC_OWNS fields of the items after the one whose address an argument is (`&a[0]` of `a[2]`): a CC_FREES
# parameter that gets it may free them too (`pairs_free(&a[0], n)`), so they escape there; none for any other.
def later_items(b: Builder, arg: Json) -> List[String]
  item = see_through(Ast.children(see_through(arg)).first)
  return [] if Ast.kind(item) != "ArraySubscriptExpr"

  items = b.owners.places.parts.get(whole_key(b, Ast.children(item).first), [])
  place = whole_key(b, item)
  at = (0...items.size).to_a.select do |i| items[i] == place end
  return [] if at.empty?

  items.drop(at.first + 1).flat_map do |later| b.owners.places.fields.get(later, []) end
end

# An argument of a call, before the call. A pointer that owns at a parameter that frees or takes it (`taking`), or
# whose address is at a CC_OWNS_OUT parameter (`filling`), is not read. A statement expression runs its statements,
# then its last expression is the argument (`free(({ ...; p; }))` frees `p`).
def argument(b: Builder, arg: Json, taking: Bool, filling: Bool, preds: List[Int]) -> Built
  bare = see_through(arg)
  if Ast.kind(bare) == "StmtExpr" and not Ast.children(last_child(bare)).empty?
    inner = valued_expression(b, bare, preds)
    last = Built(b: inner.b, exits: inner.exits)
    if Ast.kind(inner.value) != ""
      last = argument(inner.b, inner.value, taking, filling, inner.exits)
    end

    return closed_expression(last.b, last.exits)
  end

  owner = owner_of(b, arg)
  # `&p` at a CC_OWNS_OUT parameter emits no `Lends`: the call fills `p`, and `after_call` checks that a value it still
  # owned is not lost, which a `Lends` before it would hide.
  set = taking or (filling and address?(arg))
  return expression(b, arg, preds) if not (set and owner != "")

  if address?(arg)
    # `free_and_null(&p)` may set `p`: a condition on it is forgotten.
    return add(b, Event.Writes([owner]), preds)
  end

  Built(b: b, exits: preds)
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
      # A lock that the call takes or releases on one side only is not on the site: `flagged_call` and `trial` add it.
      plain = callee.locks.select do |lock| lock.flag == "" and not lock.tries end
      taken = plain.select do |lock| lock.takes end
      dropped = plain.select do |lock| not lock.takes end
      site.with(
        unnamed: unnamed or taken.any? do |lock| annotated_lock(lock, texts).empty? end,
        takes: takes.concat(taken.flat_map do |lock| annotated_lock(lock, texts) end),
        drops: drops.concat(dropped.flat_map do |lock| annotated_lock(lock, texts) end),
        stops: stops or callee.stops,
      )
    none -> site
  end
end

# An argument that passes the address of a pointer that owns (`&p`) as it is; any other with no owner.
def by_address(arg: Arg) -> Arg
  return arg if arg.address

  arg.with(owner: "")
end

# The pointers that own among the arguments at `indices`.
def owners_at(args: List[Arg], indices: List[Int]) -> List[String]
  owning = indices.select do |i| i < args.size and args[i].owner != "" end
  owning.map do |i| args[i].owner end
end

# The lock of the argument at `index`, if the call has it and it names an object.
def lock_of(args: List[Arg], index: Int) -> List[Lock]
  return [] if index >= args.size

  locks_of([args[index].text]).map do |lock| lock.with(class: args[index].class, through: args[index].through) end
end

# The key of a lock of CC_RELEASES in the names of the parameters of the definition, which may not be those of the
# prototype that wrote it; "" for the restore of a pair.
def released_key(lock: Annotated, names: List[String]) -> String
  return "" if lock.pair != ""

  key_of(substituted(lock.text, lock.params, names))
end

# The lock of an annotation, in the texts of the arguments of the call.
def annotated_lock(lock: Annotated, texts: List[String]) -> List[Lock]
  locks_of([substituted(lock.text, lock.params, texts)]).map do |found|
    found.with(class: lock.class, pair: lock.pair, through: lock.through)
  end
end

def arg_of(b: Builder, node: Json) -> Arg
  Arg(
    text: text_of(b, node, true),
    class: class_of(b, node),
    owner: owner_of(b, node),
    address: address?(single_value(node)),
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
    "MemberExpr" -> pointer_type?(bare)
    # An item of an array of pointers (`p->mus[i]` of `pthread_mutex_t *mus[2]`) is a pointer itself.
    "ArraySubscriptExpr" -> pointer_type?(bare) or aliased_through?(b, Ast.children(bare).first, depth)
    "DeclRefExpr" ->
      case b.aliases.get(Ast.referenced_name(bare))
        some(value) if depth < ALIAS_DEPTH -> aliased_through?(b, value, depth + 1)
        _ -> pointer_type?(bare)
      end

    _ -> false
  end
end

# The class of a lock expression: the field it ends in, or a global variable, through `&`, `*` and the local variables
# set once.
def class_of(b: Builder, node: Json) -> String = aliased_class(b, node, 0)

def aliased_class(b: Builder, node: Json, depth: Int) -> String
  bare = see_through(node)
  while Ast.kind(bare) == "UnaryOperator" and UNARY_TEXT.include?(Ast.text(bare, "opcode"))
    bare = see_through(Ast.children(bare).first)
  end

  case Ast.kind(bare)
    "MemberExpr" -> b.ctx.fields.get(Ast.text(bare, "referencedMemberDecl")).unwrap_or("")
    "ArraySubscriptExpr" -> aliased_class(b, Ast.children(bare).first, depth)
    "DeclRefExpr" ->
      name = Ast.referenced_name(bare)
      case b.aliases.get(name)
        some(value) if depth < ALIAS_DEPTH -> aliased_class(b, value, depth + 1)
        _ ->
          declared = JSON.get(bare, "referencedDecl").unwrap_or(JSON.from(""))
          b.ctx.globals.get(Ast.text(declared, "id")).unwrap_or("")
      end

    _ -> ""
  end
end

# The locks of lock texts; a text that is "" (an expression that names no object, such as a call) is no lock.
def locks_of(texts: List[String]) -> List[Lock]
  named = texts.select do |text| text != "" end
  named.map do |text| Lock(key: key_of(text), shown: shown_of(text)) end
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
    return Split(b: b, yes: [], no: preds) if Ast.text(bare, "value") == "0"

    return Split(b: b, yes: preds, no: [])
  end

  # `(r = pthread_mutex_trylock(&m)) != 0`: the result kept in `r`, then the test of `r`.
  compared = zero_compared(bare)
  if compared.some? and kept_trial(b, compared.unwrap!.operand).some?
    inner = condition(b, compared.unwrap!.operand, preds)
    return Split(b: inner.b, yes: inner.no, no: inner.yes) if compared.unwrap!.equal

    return inner
  end

  kept_try = kept_trial(b, bare)
  if kept_try.some?
    kept = kept_result(b, variable_key(b.owners.places.keys, parts.first), kept_try.unwrap!, preds)
    return condition(kept.b, parts.first, kept.exits)
  end

  case tried_call(b, bare)
    some(tried) -> trial(b, tried, preds)
    none -> branch(b, bare, preds)
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

  [current].concat(rights.reverse)
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

  return Split(b: built, yes: pending, no: out) if all

  Split(b: built, yes: out, no: pending)
end

# A condition of any other form: its calls, then a node for each of its values. A test against 0 is a fact of what it
# compares (`Fact`).
def branch(b: Builder, bare: Json, preds: List[Int]) -> Split
  value = expression(b, bare, preds)
  keys = value.b.owners.places.keys
  fact = fact_of(value.b, bare)
  yes_fact = fact
  no_fact = fact.with(value: not fact.value)
  if fact.word != ""
    no_fact = no_fact.with(word: "false")
  end

  null_on_true: List[String] = []
  null_on_false: List[String] = []
  case null_test(value.b, bare)
    some(test) if test.null_if -> null_on_true = [test.name]
    some(test) -> null_on_false = [test.name]
    none -> null_on_false = []
  end

  yes = add(value.b, Event.Branch(yes_fact.with(nulls: null_on_true, set: null_on_false)), value.exits)
  no = add(yes.b, Event.Branch(no_fact.with(nulls: null_on_false, set: null_on_true)), value.exits)
  split = Split(b: no.b, yes: yes.exits, no: no.exits)
  case compared_with(bare, false)
    some(compared) -> nonzero_side(split, compared, keys)
    none -> split
  end
end

# The fact of a condition where it is true. A test against 0 is a fact of what it compares, and `r != EBUSY` the fact
# of `r == EBUSY`, the other way round, whichever side the number is on.
def fact_of(b: Builder, bare: Json) -> Fact
  keys = b.owners.places.keys
  tested = copied(b, bare)
  place = Ast.start_of(bare)
  fact = Fact(
    text: written_text(b, tested, false, keys, 0),
    value: true,
    roots: roots_of(keys, tested),
    line: place.line,
    column: place.column,
  )

  case zero_compared(bare)
    some(compared) ->
      source = copied(b, compared.operand)
      operand = written_text(b, source, false, keys, 0)
      if operand != "" and compared.equal
        fact = fact.with(text: operand, roots: roots_of(keys, source), value: false, word: "true")
      elsif operand != ""
        fact = fact.with(text: operand, roots: roots_of(keys, source))
      end

    none -> fact = fact
  end

  case compared_with(bare, false)
    some(compared) ->
      source = copied(b, compared.operand)
      operand = written_text(b, source, false, keys, 0)
      equal = "#{operand} == #{compared.number}"
      if operand != "" and compared.equal
        fact = fact.with(text: equal, roots: roots_of(keys, source))
      elsif operand != ""
        fact = fact.with(text: equal, roots: roots_of(keys, source), value: false, word: "true")
      end

    none -> fact = fact
  end

  fact
end

# `r == EBUSY` where it holds, and `r != EBUSY` where it does not, also tell that `r` is not 0: a fact of `r` after
# that side.
def nonzero_side(split: Split, compared: Compared, keys: Map[String, String]) -> Split
  source = copied(split.b, compared.operand)
  operand = written_text(split.b, source, false, keys, 0)
  return split if operand == ""

  place = Ast.start_of(compared.operand)
  fact = Fact(
    text: operand,
    value: true,
    roots: roots_of(keys, source),
    line: place.line,
    column: place.column,
    quiet: true,
  )

  if compared.equal
    known = add(split.b, Event.Branch(fact), split.yes)
    return Split(b: known.b, yes: known.exits, no: split.no)
  end

  known = add(split.b, Event.Branch(fact), split.no)
  Split(b: known.b, yes: split.yes, no: known.exits)
end

# The variable that a test reads: for a local set once to another local set once (`int busy = r;`), that one, so a
# test of the copy is one of the result it copies; the node itself for anything else, and for a copy of a local whose
# value can change behind the code, or into one (`Builder.opaque`: `static`, `volatile`, its address taken).
def copied(b: Builder, node: Json) -> Json
  bare = see_through(node)
  return node if Ast.kind(bare) != "DeclRefExpr"

  keys = b.owners.places.keys
  case b.aliases.get(Ast.referenced_name(bare))
    some(value) ->
      source = see_through(value)
      return node if Ast.kind(source) != "DeclRefExpr" or not b.aliases.key?(Ast.referenced_name(source))

      return node if b.opaque.include?(referenced_key(keys, bare)) or b.opaque.include?(referenced_key(keys, source))

      source
    none -> node
  end
end

# A comparison with 0 (`x == 0`, `0 != x`, `p == NULL`): what it compares, and whether it is `==`.
def zero_compared(node: Json) -> Optional[Compared] = compared_with(node, true)

# A comparison with 0 (`zero`) or with a whole number other than 0 (`r == EBUSY`).
def compared_with(node: Json, zero: Bool) -> Optional[Compared]
  bare = see_through(node)
  opcode = Ast.text(bare, "opcode")
  parts = Ast.children(bare)
  return none if Ast.kind(bare) != "BinaryOperator" or (opcode != "==" and opcode != "!=") or parts.size != 2

  for pair in [[parts[0], parts[1]], [parts[1], parts[0]]]
    number = see_through(pair[1])
    nonzero = Ast.kind(number) == "IntegerLiteral" and Ast.text(number, "value") != "0"
    if (zero and zero?(pair[1])) or (not zero and nonzero)
      return some(Compared(operand: pair[0], equal: opcode == "==", number: Ast.text(number, "value")))
    end
  end

  none
end

# Whether a condition tells that a pointer that owns is null: `p`, `p = malloc(n)`, and either compared with 0.
def null_test(b: Builder, node: Json) -> Optional[NullTest]
  bare = see_through(node)
  name = owner_named(b, bare)
  if name == ""
    name = pointee_owner(b, bare)
  end

  return some(NullTest(name: name, null_if: false)) if name != ""

  opcode = Ast.text(bare, "opcode")
  parts = Ast.children(bare)
  return none if Ast.kind(bare) != "BinaryOperator" or parts.size != 2

  if opcode == "="
    target = owner_named(b, parts[0])
    return none if target == ""

    return some(NullTest(name: target, null_if: false))
  end

  return none if opcode != "==" and opcode != "!="

  for pair in [[parts[0], parts[1]], [parts[1], parts[0]]]
    if zero?(pair[1])
      return null_test(b, pair[0]).map do |test| test.with(null_if: test.null_if != (opcode == "==")) end
    end
  end

  none
end

# A call of `Known.TRIES` or of a function with CC_TRIES, alone, negated or compared with 0 (`call`, `!call`,
# `call == 0`).
def tried_call(b: Builder, node: Json) -> Optional[Tried]
  bare = see_through(node)
  return some(Tried(call: bare, zero_is_true: false)) if try_call?(b, bare)

  if Ast.kind(bare) == "UnaryOperator" and Ast.text(bare, "opcode") == "!"
    return tried_call(b, Ast.children(bare).first).map do |tried| tried.with(zero_is_true: not tried.zero_is_true) end
  end

  case zero_compared(bare)
    some(compared) ->
      tried_call(b, compared.operand).map do |tried| tried.with(zero_is_true: tried.zero_is_true != compared.equal) end
    none -> none
  end
end

def try_call?(b: Builder, node: Json) -> Bool
  bare = see_through(node)
  return false if Ast.kind(bare) != "CallExpr"

  name = callee_name(bare)
  Known.TRIES.include?(name) or not marked_tries(b, name).empty?
end

# The locks of the CC_TRIES of a function, by name; none for another function.
def marked_tries(b: Builder, name: String) -> List[Annotated]
  return [] if name == ""

  case b.ctx.callees.get(key_of_function(b.ctx, name))
    some(callee) -> callee.locks.select do |lock| lock.tries end
    none -> []
  end
end

# The call, then on the branch where it gave 0 a node that takes its lock.
def trial(b: Builder, tried: Tried, preds: List[Int]) -> Split
  called = call(b, tried.call, preds, true)
  taken = add(called.b, Event.Call(taking_site(called.b, tried.call)), called.exits)
  return Split(b: taken.b, yes: taken.exits, no: called.exits) if tried.zero_is_true

  Split(b: taken.b, yes: called.exits, no: taken.exits)
end

# The take of the lock of a call of `Known.TRIES`, or of the locks of a CC_TRIES, where it gave 0. A CC_TRIES never
# waits for its lock.
def taking_site(b: Builder, node: Json) -> Site
  name = callee_name(node)
  passed = Ast.children(node).drop(1).map do |arg| arg_of(b, arg) end
  site = site_of(b, name, passed, Ast.start_of(node), false)
  marked = marked_tries(b, name)
  if not marked.empty?
    texts = passed.map do |arg| arg.text end
    # The call itself is the node before this one (`trial`), with what it does to the pointers that own.
    taken = site.with(frees: [], hands: [], clears: [], fills: [], lost: false, drops: [], waits: [])
    return taken.with(takes: marked.flat_map do |lock| annotated_lock(lock, texts) end, tried: true)
  end

  site.with(takes: lock_of(passed, 0), tried: Known.NO_WAIT.include?(name))
end

# The call of an assignment that keeps the result of a trylock in a local variable or a parameter (`r =
# pthread_mutex_trylock(&m)`, `ok = pthread_mutex_trylock(&m) == 0`).
def kept_trial(b: Builder, node: Json) -> Optional[Tried]
  bare = see_through(node)
  parts = Ast.children(bare)
  return none if Ast.kind(bare) != "BinaryOperator" or Ast.text(bare, "opcode") != "=" or parts.size != 2

  return none if Ast.kind(see_through(parts[0])) != "DeclRefExpr"

  key = variable_key(b.owners.places.keys, parts[0])
  return none if not keeps?(b, key)

  tried_call(b, parts[1])
end

# Whether a write of the local `key` can give it a value that a path knows: not one that owns, nor one whose value the
# rules never know (`opaque_of`).
def keeps?(b: Builder, key: String) -> Bool
  key != "" and not b.owners.names.include?(key) and not b.opaque.include?(key)
end

# The result of a trylock kept in the variable `key`: the call, the write, then a side where the call worked, which
# takes the lock, and one where it failed, each with the value of the variable there. A later test of the variable
# goes the same way, until a write forgets it. The failure of a call that waits for its lock is an error, which a path
# reaches only when the function tests the result.
def kept_result(b: Builder, key: String, tried: Tried, preds: List[Int]) -> Built
  called = call(b, tried.call, preds, true)
  written = add(called.b, Event.Writes([key]), called.exits)
  place = Ast.start_of(tried.call)
  fact = Fact(
    text: key,
    value: tried.zero_is_true,
    roots: [key],
    line: place.line,
    column: place.column,
    quiet: true,
    written: true,
  )

  site = taking_site(written.b, tried.call)
  worked = add(written.b, Event.Branch(fact), written.exits)
  taken = add(worked.b, Event.Call(site), worked.exits)
  waits = Known.TAKES.include?(callee_name(tried.call))
  other = fact.with(value: not tried.zero_is_true, quiet: false, word: "fails", if_tested: waits, failed: site.takes)
  failed = add(taken.b, Event.Branch(other), written.exits)
  Built(b: failed.b, exits: taken.exits.concat(failed.exits))
end

# After the write of a local variable (`key`) with a constant (`locked = 1`, `bool taken = false`), the value of the
# variable as a fact of its own, when a test of it guards a lock (`guarded_of`); any other write gives none.
def constant_written(b: Builder, key: String, value: Json, preds: List[Int]) -> Built
  bare = see_through(value)
  number = ""
  case Ast.kind(bare)
    "IntegerLiteral" -> number = Ast.text(bare, "value")
    "CharacterLiteral" -> number = "#{Ast.number(bare, "value")}"
    _ -> number = ""
  end

  return Built(b: b, exits: preds) if number == "" or not keeps?(b, key) or not b.guarded.include?(key)

  place = Ast.start_of(value)
  fact = Fact(
    text: key,
    value: number != "0",
    roots: [key],
    line: place.line,
    column: place.column,
    quiet: true,
    written: true,
    single: true,
  )

  add(b, Event.Branch(fact), preds)
end

# The text of an expression, from the names, fields, constants and operators of `UNARY_TEXT` and `BINARY_TEXT`; ""
# for anything else. With `aliases`, a local variable set once reads as its value.
def text_of(b: Builder, node: Json, aliases: Bool) -> String = written_text(b, node, aliases, {}, 0)

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
        found = b.aliases.get(name).map do |value| written_text(b, value, aliases, keys, depth + 1) end
        aliased = found.unwrap_or("")
      end

      return aliased if aliased != ""

      referenced_key(keys, bare)
    "MemberExpr" ->
      base = written_text(b, parts.first, aliases, keys, depth)
      return "" if base == ""

      return "#{base}->#{Ast.text(bare, "name")}" if Ast.flag?(bare, "isArrow")

      "#{base}.#{Ast.text(bare, "name")}"
    "ArraySubscriptExpr" ->
      array = written_text(b, parts[0], aliases, keys, depth)
      index = written_text(b, parts[1], aliases, keys, depth)
      return "" if array == "" or index == ""

      "#{array}[#{index}]"
    "UnaryOperator" ->
      operand = written_text(b, parts.first, aliases, keys, depth)
      return "" if operand == "" or Ast.flag?(bare, "isPostfix") or not UNARY_TEXT.include?(Ast.text(bare, "opcode"))

      "#{Ast.text(bare, "opcode")}#{operand}"
    "BinaryOperator" ->
      left = written_text(b, parts[0], aliases, keys, depth)
      right = written_text(b, parts[1], aliases, keys, depth)
      return "" if left == "" or right == "" or not BINARY_TEXT.include?(Ast.text(bare, "opcode"))

      "#{left} #{Ast.text(bare, "opcode")} #{right}"
    "IntegerLiteral" -> Ast.text(bare, "value")
    "CharacterLiteral" -> "#{Ast.number(bare, "value")}"
    _ -> ""
  end
end

# The text of a local variable, through its alias when it has one.
def local_text(b: Builder, name: String) -> String
  case b.aliases.get(name)
    some(value) ->
      aliased = text_of(b, value, true)
      return aliased if aliased != ""

      name
    none -> name
  end
end

# The variables an expression reads, by key (`referenced_key`).
def roots_of(keys: Map[String, String], node: Json) -> List[String]
  return [referenced_key(keys, node)] if Ast.kind(node) == "DeclRefExpr"

  # A followed CC_OWNS field of a local struct is a variable of its own, besides the struct.
  if Ast.kind(node) == "MemberExpr" and keys.key?(Ast.text(node, "id"))
    under = Ast.children(node).flat_map do |child| roots_of(keys, child) end
    return [keys[Ast.text(node, "id")]].concat(under).uniq
  end

  roots = Ast.children(node).flat_map do |child| roots_of(keys, child) end
  roots.uniq
end

# The variable an assignment writes, by key (`referenced_key`): the root of `x`, `x->a.b` or `x[i]`.
def target_root(keys: Map[String, String], node: Json) -> String
  bare = see_through(node)
  case Ast.kind(bare)
    "DeclRefExpr" -> referenced_key(keys, bare)
    "MemberExpr" ->
      # A followed CC_OWNS field of a local struct is a variable of its own.
      return keys[Ast.text(bare, "id")] if keys.key?(Ast.text(bare, "id"))

      target_root(keys, Ast.children(bare).first)
    "ArraySubscriptExpr" -> target_root(keys, Ast.children(bare).first)
    "UnaryOperator" -> target_root(keys, Ast.children(bare).first)
    _ -> ""
  end
end

# The variable whose own storage an expression is, by key: `x`, `x.a`, `x[i]` of an array `x`; "" through a pointer
# (`q->mu`, `*p`, `p[i]`), whose variable a write through the address does not change.
def storage_root(keys: Map[String, String], node: Json) -> String
  bare = see_through(node)
  case Ast.kind(bare)
    "DeclRefExpr" -> referenced_key(keys, bare)
    "MemberExpr" ->
      return "" if Ast.flag?(bare, "isArrow")

      storage_root(keys, Ast.children(bare).first)
    "ArraySubscriptExpr" ->
      base = Ast.children(bare).first
      return "" if Ast.text(base, "castKind") != "ArrayToPointerDecay"

      storage_root(keys, Ast.children(base).first)
    _ -> ""
  end
end

def last_child(node: Json) -> Json
  parts = Ast.children(node)
  return JSON.from("") if parts.empty?

  parts.last
end

# A new node after `preds`.
def add(b: Builder, event: Event, preds: List[Int]) -> Built
  index = b.nodes.size
  grown = b.with(nodes: b.nodes.push(Node(event: event, next: [])))
  Built(b: link(grown, preds, index), exits: [index])
end

def link(b: Builder, froms: List[Int], to: Int) -> Builder
  nodes = b.nodes
  for from in froms
    node = nodes[from]
    if not node.next.include?(to)
      nodes = nodes.set(from, node.with(next: node.next.push(to)))
    end
  end

  b.with(nodes: nodes)
end

# `found` with the node and every node inside it, in order. Only pushes, so the list is never copied.
def with_descendants(found: List[Json], node: Json) -> List[Json]
  all = found.push(node)
  for child in Ast.children(node)
    all = with_descendants(all, child)
  end

  all
end
