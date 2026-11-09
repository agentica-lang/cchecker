## What the rules need from the AST of one translation unit: its functions with their annotations, its calls, and the
## functions it stores in function pointers.
##
## A function pointer is followed through the place it is stored in, a slot: a parameter of a function, a variable or
## a field of a struct. A call through a slot reaches every function the project stores in that slot anywhere; a slot
## that no function is stored in reaches nothing.

import Ast from "ast"
import Collector from "collector"
import {Finding} from "findings"
import Flow from "flow"
import Known from "known"

# The prefix of an annotation of include/cchecker.h. Under CCHECKER_AST the macros are `deprecated` attributes, whose
# message clang 19 keeps in its JSON AST (it drops the string of an `annotate` attribute).
MARK_PREFIX = "cchecker:"

# The attributes of a function that never returns (`_Noreturn`, `[[noreturn]]`).
NORETURN_ATTRS = Set.new(["C11NoReturnAttr", "NoReturnAttr", "CXX11NoReturnAttr"])

# The annotations that name locks, and whether the function takes them.
LOCK_MARKS = {"acquires": true, "releases": false}

## The start of the mark of CC_PAIR(set, restore).
export PAIR_MARK = "pair("

# The marks of ownership.
OWNS = "owns"
FREES = "frees"
OWNS_OUT = "owns_out"

# The marks of the collector rule.
GC = "gc"
GC_ALLOC = "gc_alloc"

# The most nodes of the AST of a function that the path rules build a graph for, about four times the largest function
# of the Agentica VM. A larger function is an error of the tool, so a run never runs out of memory on one.
MAX_BODY_NODES = 20_000

# The words of a type that are not the name of its struct.
TYPE_QUALIFIERS = Set.new([
  "const", "volatile", "restrict", "__restrict", "__restrict__", "_Atomic", "_Nonnull", "_Nullable",
  "_Null_unspecified", "struct", "union",
])

# The marks of a lock field or global: CC_NO_SYSCALL_UNDER() and CC_LOCK_LEVEL(n), n a decimal number.
QUIET_MARK = "no_syscall_under"
LEVEL_MARK = "lock_level"

# The slot that the argument of a callback is read into, which no other store names: only its sources are kept.
CALLBACK_SLOT = "callback"

# The nodes a function pointer goes through on its way to a call or a store, which do not change where it points.
TRANSPARENT = Set.new(["ImplicitCastExpr", "CStyleCastExpr", "ParenExpr", "CompoundLiteralExpr"])

## A function of the project, as one translation unit declares it. `key` is its name, and `name@file` for a static
## function, which is another function in each file. `marks` are the annotations, as written after `cchecker:`
## (`short`, `blocking`, `hot`). The place is that of the declaration, of the definition when `defined`. `noreturn`
## says that the declaration never returns (an attribute, its type, CC_NORETURN or CC_JUMPS), and `cold` that it is
## `__attribute__((cold))`: either is an error exit.
export struct Function
  key: String
  name: String
  file: String
  line: Int
  column: Int
  defined: Bool
  marks: List[String]
  noreturn: Bool = false
  cold: Bool = false
end

## Where a call goes: a function, by key, or a slot.
export enum Target
  Direct(String)
  Slot(String)
end

## A call of `caller`, a function key. A call through a slot has the place of the call, so the path rules find the
## functions that a call of a pointer under a lock reaches. A call that takes a lock (`Known.TAKES`) has the class of
## its lock in `lock` (`queue.mu`, or a global), "" when the rules cannot tell. A call of `Known.FLAG_ARGUMENTS` has
## the value of its flags in `flags` when they are a constant, else -1, and `named` says that they name the flag that
## makes it return at once as a constant of an enum.
export struct Call
  caller: String
  target: Target
  line: Int = 0
  column: Int = 0
  lock: String = ""
  flags: Int = -1
  named: Bool = false
end

## What a slot gets: a function, by key, or every function of another slot (a copy of a pointer).
export enum Source
  Function(String)
  Copy(String)
end

## A store of a function pointer in a slot.
export struct Store
  slot: String
  source: Source
end

## An annotation of a lock: a field (`queue.mu`, by struct and field name) or a global variable, and the mark
## (`no_syscall_under()`, `lock_level(2)`).
export struct LockMark
  class: String
  mark: String
  named: String = ""
  file: String = ""
end

## A lock mark that cannot be read: what is wrong with it, and the file it is written in (a header shared by several
## units gives the same error in each).
export struct MarkError
  file: String
  message: String
end

# The lock marks of a unit that can be read, and the errors of those that cannot.
struct LockMarks
  marks: List[LockMark]
  errors: List[MarkError]
end

## A function pointer passed to a libuv call, or stored in a field that libuv calls, on the loop thread
## (`Known.LOOP_CALLBACKS`, `Known.LOOP_CALLBACK_FIELDS`): the call (the field for a store), the place of the argument
## (from 0; -1 for a store), the place of the call or store (`file` absolute), and what the argument holds, which is
## empty when it is neither a function nor a pointer that the rules follow.
export struct Callback
  call: String
  argument: Int
  file: String
  line: Int
  sources: List[Source]
end

## The functions, calls and stores of one translation unit, its callbacks of libuv, the graphs of its functions that
## take or release a lock or own a pointer, the annotations of its locks, and the findings of the collector rule, which
## reads one unit. `too_large` names the functions too large for a graph (`MAX_BODY_NODES`), and `mark_errors` says
## what is wrong with the lock marks that cannot be read. `target` is the triple of clang that the unit was built for,
## "" when it is not known.
export struct Unit
  functions: List[Function]
  calls: List[Call]
  stores: List[Store]
  bodies: List[Flow.Body] = []
  lock_marks: List[LockMark] = []
  too_large: List[String] = []
  mark_errors: List[MarkError] = []
  callbacks: List[Callback] = []
  collected: List[Finding] = []
  target: String = ""
end

# A struct or union: its name (a typedef name for an anonymous one), the ids and names of its fields, and their types
# as written and without their typedefs ("" for a type with none).
struct Record
  name: String
  field_ids: List[String]
  fields: List[String]
  types: List[String] = []
  desugared: List[String] = []
end

# The functions of a CC_PAIR(set, restore), by name.
struct Pair
  set: String
  restore: String
end

# A record declaration and its name: an anonymous one takes the name of a typedef of it, else the name of the record
# it is declared in ("" at the top level).
struct Nested
  node: Json
  name: String
end

# What the walk of the functions needs from the whole unit: the keys of its static functions and variables by name,
# the slots of the fields by id, and the records by type name.
struct Tables
  static_functions: Map[String, String]
  static_variables: Map[String, String]
  field_slots: Map[String, String]
  records: Map[String, Record]
  record_ids: Map[String, Record]
end

# The function a walk is in: its key, its parameters by name and the names of its local variables.
struct Scope
  caller: String
  params: Map[String, Int]
  locals: Set[String]
end

# What a walk found so far.
struct Found
  calls: List[Call]
  stores: List[Store]
  callbacks: List[Callback] = []
end

## Returns the unit of the declarations that `Scan` kept, a JSON array.
export def read(decls: Json) -> Result[Unit]
  nodes = try JSON.list(decls)
  tables = tables_of(nodes)
  ctx = context_of(tables, nodes)
  marks = collector_marks(tables, nodes)
  functions: List[Function] = []
  bodies: List[Flow.Body] = []
  collected = Collector.statics(marks, nodes)
  too_large: List[String] = []
  found = Found(calls: [], stores: [])
  for node in nodes
    case Ast.kind(node)
      "FunctionDecl" ->
        function = function_of(tables, node)
        functions = functions.push(function)
        found = in_function(tables, function.key, node, found)
        own = paired(ctx, tables, function)
        if function.defined and (Flow.locks?(own, node) or Flow.owns?(own, function.key, node))
          if Ast.size_of(node, MAX_BODY_NODES) > MAX_BODY_NODES
            too_large = too_large.push(function.name)
          else
            bodies = bodies.push(Flow.body_of(own, function.key, node))
          end
        end

        if function.defined
          params = Flow.owned_params(ctx, function.key, node)
          collected = collected.concat(Collector.stores(marks, ctx, function.name, Ast.place_of(node), params, node))
        end

      "VarDecl" ->
        slot = "var:#{variable_key(tables, Ast.text(node, "name"))}"
        for value in values(node)
          found = with_field_stores(found, node, stored(tables, file_scope(), slot, value))
        end

      _ -> next
    end
  end

  marked = lock_marks_of(tables, nodes)
  return ok(
    Unit(
      functions: functions,
      calls: found.calls,
      stores: found.stores,
      bodies: bodies,
      lock_marks: marked.marks,
      too_large: too_large,
      mark_errors: marked.errors,
      callbacks: found.callbacks,
      collected: collected,
    ),
  )
end

# What the functions of the unit say about locks, from all their declarations: the locks of CC_ACQUIRES and
# CC_RELEASES, with the names of the parameters of the declaration that carries them, and whether they never return
# (`_Noreturn`, `__attribute__((noreturn))`, CC_NORETURN).
def context_of(tables: Tables, nodes: List[Json]) -> Flow.Context
  callees: Map[String, Flow.Callee] = {}
  variables = nodes.select do |node| Ast.kind(node) == "VarDecl" end
  globals: Map[String, String] = {}
  global_ids: Map[String, String] = {}
  for node in variables
    class = variable_key(tables, Ast.text(node, "name"))
    globals = globals.put(Ast.text(node, "name"), class)
    global_ids = global_ids.put(Ast.text(node, "id"), class)
  end

  declarations = nodes.select do |node| Ast.kind(node) == "FunctionDecl" end
  for node in declarations
    function = function_of(tables, node)
    params = Flow.params_named(node)
    types = param_types_of(node)
    # A definition inherits the annotations of the prototype before it, in the names of the prototype's parameters:
    # only the declaration that wrote an annotation knows what its names are.
    locks = own_marks(node)
      .flat_map do |mark| annotated(mark, params) end
      .map do |lock| lock.with(class: class_of_text(tables, globals, lock.text, params, types)) end

    stops = function.noreturn
    if not locks.empty? or stops
      known = callees.get(function.key).unwrap_or(Flow.Callee(locks: [], stops: false))
      callees = callees.put(function.key, Flow.Callee(locks: known.locks.concat(locks), stops: known.stops or stops))
    end
  end

  # CC_PAIR(set, restore) on `set` itself holds in every function that calls it.
  for node in declarations
    name = Ast.text(node, "name")
    for pair in own_marks(node).flat_map(&pair_of)
      if pair.set == name
        callees = with_pair(callees, tables, pair)
      end
    end
  end

  fields: Map[String, String] = {}
  for id in tables.field_slots.keys
    fields = fields.put(id, tables.field_slots[id].replace("field:", ""))
  end

  return Flow.Context(
    callees: callees,
    statics: tables.static_functions,
    fields: fields,
    globals: global_ids,
    owning: owning_of(tables, nodes),
  )
end

# What the declarations of the unit say about ownership: CC_OWNS on a function (it returns an owned pointer), on a
# parameter (it takes what the caller passes), on a field or a global (a store into it hands a pointer on), CC_FREES
# on a parameter, and CC_OWNS_OUT on a parameter (the function hands an owned pointer out to the caller through it).
# The marks of the parameters of all the declarations of a function hold, by index.
def owning_of(tables: Tables, nodes: List[Json]) -> Flow.Owning
  returns: Set[String] = Set.new([])
  takes: Map[String, List[Int]] = {}
  frees: Map[String, List[Int]] = {}
  outs: Map[String, List[Int]] = {}
  declarations = nodes.select do |n| Ast.kind(n) == "FunctionDecl" end
  for node in declarations
    key = function_key(tables, Ast.text(node, "name"))
    if own_marks(node).include?(OWNS)
      returns = returns.add(key)
    end

    parameters = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
    for i in 0...parameters.size
      marks = own_marks(parameters[i])
      if marks.include?(OWNS) and not takes.get(key, []).include?(i)
        takes = takes.put(key, takes.get(key, []).push(i))
      end

      if marks.include?(OWNS_OUT) and not outs.get(key, []).include?(i)
        outs = outs.put(key, outs.get(key, []).push(i))
      end

      if marks.include?(FREES) and not frees.get(key, []).include?(i)
        frees = frees.put(key, frees.get(key, []).push(i))
      end
    end
  end

  # The records of the unit, those declared in a function body too.
  bodies = declarations.flat_map do |n| Ast.children(n).select do |child| Ast.kind(child) == "CompoundStmt" end end
  inner = Flow.descendants(bodies).select do |n| Ast.kind(n) == "DeclStmt" end.flat_map(&Ast.children)
  fields: Set[String] = Set.new([])
  for nested in record_decls(nodes, "").concat(record_decls(inner, ""))
    record_fields = Ast.children(nested.node).select do |child| Ast.kind(child) == "FieldDecl" end
    for field in record_fields
      if own_marks(field).include?(OWNS)
        fields = fields.add(Ast.text(field, "id"))
      end
    end
  end

  # A global by the ids of all its declarations, so that the mark of one holds in the others and a local of the same
  # name is not it.
  variables = nodes.select do |n| Ast.kind(n) == "VarDecl" end
  marked = Set.new(variables.select do |n| own_marks(n).include?(OWNS) end.map do |n| Ast.text(n, "name") end)
  globals = variables.select do |n| marked.include?(Ast.text(n, "name")) end.map do |n| Ast.text(n, "id") end
  return Flow.Owning(
    returns: returns,
    takes: takes,
    frees: frees,
    outs: outs,
    fields: fields,
    globals: Set.new(globals),
  )
end

# What the collector rule needs from the unit: the types marked CC_GC (a struct or a union by its name, a typedef by
# its name and the name of the record it names, and a typedef of a marked record), the records that hold a value of
# one of them (by value or by pointer, directly or in a record they hold), the allocators marked CC_GC_ALLOC, and the
# variables of static storage declared at the top of the file.
def collector_marks(tables: Tables, nodes: List[Json]) -> Collector.Marks
  types: Set[String] = Set.new([])
  for nested in record_decls(nodes, "")
    if own_marks(nested.node).include?(GC)
      types = types.add(tables.record_ids.get(Ast.text(nested.node, "id")).map do |r| r.name end.unwrap_or(""))
    end
  end

  allocators: Set[String] = Set.new([])
  statics: Set[String] = Set.new([])
  for node in nodes
    marks = own_marks(node)
    case Ast.kind(node)
      "TypedefDecl" ->
        # A typedef of a marked record is marked too: clang does not desugar the pointee of `obj_t *`.
        named = tables.record_ids.get(own_record_id(node)).map do |r| r.name end.unwrap_or("")
        if marks.include?(GC) or types.include?(named)
          types = types.add(Ast.text(node, "name")).add(named)
        end

      "FunctionDecl" ->
        if marks.include?(GC_ALLOC)
          allocators = allocators.add(function_key(tables, Ast.text(node, "name")))
        end

      "VarDecl" -> statics = statics.add(Ast.text(node, "id"))
      _ -> next
    end
  end

  start = Collector.Marks(types: types.delete(""), holders: Set.new([]), allocators: allocators, statics: statics)
  return with_holders(start, tables)
end

# The marks with the records that hold a value of the collector, until no more are found.
def with_holders(marks: Collector.Marks, tables: Tables) -> Collector.Marks
  grown = marks
  grew = true
  while grew
    grew = false
    for record in tables.record_ids.values
      types = record.types.concat(record.desugared)
      if not grown.holders.include?(record.name) and types.any? do |t| Collector.collector_type?(grown, t) end
        grown = grown.with(holders: grown.holders.add(record.name))
        grew = true
      end
    end
  end

  return grown
end

# The record that a typedef names itself (`typedef struct obj obj_t`), not one in a pointer or a function type
# (`typedef value (*make_fn)(void)`); "" for none.
def own_record_id(node: Json) -> String
  types = Ast.children(node).select do |child| not Ast.kind(child).end_with?("Attr") end
  if types.empty?
    return ""
  end

  type = types.first
  if Ast.kind(type) == "ElaboratedType" and not Ast.children(type).empty?
    type = Ast.children(type).first
  end

  if Ast.kind(type) != "RecordType"
    return ""
  end

  return Ast.text(JSON.get(type, "decl").unwrap_or(JSON.from("")), "id")
end

# The context of the body of a function: CC_PAIR(set, restore) on a function other than `set` holds in its body only.
def paired(ctx: Flow.Context, tables: Tables, function: Function) -> Flow.Context
  callees = ctx.callees
  for pair in function.marks.flat_map(&pair_of)
    if pair.set != function.name
      callees = with_pair(callees, tables, pair)
    end
  end

  return ctx.with(callees: callees)
end

# The callees with the lock of a pair, `pair:set:restore`: `set` takes it and `restore` releases it, so two pairs on
# one set, or one restore of two sets, are two locks. The lock names no parameter, so a call passes nothing to it. A
# pair written twice (on two declarations, or on `set` and on its caller) counts once.
def with_pair(callees: Map[String, Flow.Callee], tables: Tables, pair: Pair) -> Map[String, Flow.Callee]
  text = "#{Flow.PAIR_PREFIX}#{pair.set}:#{pair.restore}"
  added = callees
  for side in [pair.set, pair.restore]
    lock = Flow.Annotated(text: text, params: [], takes: side == pair.set, pair: pair.restore)
    key = function_key(tables, side)
    known = added.get(key).unwrap_or(Flow.Callee(locks: [], stops: false))
    if not known.locks.include?(lock)
      added = added.put(key, known.with(locks: known.locks.push(lock)))
    end
  end

  return added
end

# The functions of a mark `pair(set, restore)`; none for another mark, or one that does not name two functions.
def pair_of(mark: String) -> List[Pair]
  if not mark.start_with?(PAIR_MARK) or not mark.end_with?(")")
    return []
  end

  names = mark.slice(PAIR_MARK.length, mark.length - PAIR_MARK.length - 1).split(",").map do |name| name.strip end
  if names.size != 2 or names.any? do |name| name == "" end
    return []
  end

  return [Pair(set: names[0], restore: names[1])]
end

# The class of the lock of an annotation, through the types of the parameters: `s->pool->mu` of `struct server *s` is
# `pool.mu`, and `p->m[0]` the field `m`; a global is its name (`name@file` for a static one), unless a parameter has
# that name. "" when a type on the way is not a struct of the project.
def class_of_text(
  tables: Tables,
  globals: Map[String, String],
  text: String,
  params: List[String],
  types: List[String],
) -> String
  path = Flow.shown_of(text).replace("*", "").replace("->", ".").split(".").map do |part| part.split("[").first end
  at = -1
  for i in 0...params.size
    if params[i] == path.first
      at = i
    end
  end

  if at < 0
    if path.size == 1
      return globals.get(path.first).unwrap_or("")
    end

    return ""
  end

  type = types[at]
  for j in 1...path.size
    case tables.records.get(type_name(type))
      some(record) ->
        for k in 0...record.fields.size
          if record.fields[k] == path[j]
            if j == path.size - 1
              return "#{record.name}.#{path[j]}"
            end

            type = record.types[k]
          end
        end

      none -> return ""
    end
  end

  return ""
end

# The name of the struct of a type as clang writes it: `struct server *`, `const server *`, `struct server *const`,
# `_Atomic(struct server *)` and `struct server * _Nonnull` are `server`.
def type_name(type: String) -> String
  words = type.replace("_Atomic(", " ")
    .replace(")", " ")
    .replace("*", " ")
    .split(" ")
    .select do |word| word != "" and not TYPE_QUALIFIERS.include?(word) end

  return words.join(" ")
end

# The lock marks of the fields and the global variables of the unit, by their class, and the errors of the marks that
# cannot be read: a level that is not a decimal number, a lock named in the mark of a field, or a field of a struct
# with no name.
def lock_marks_of(tables: Tables, nodes: List[Json]) -> LockMarks
  marks: List[LockMark] = []
  for nested in record_decls(nodes, "")
    fields = Ast.children(nested.node).select do |child| Ast.kind(child) == "FieldDecl" end
    for field in fields
      class = tables.field_slots.get(Ast.text(field, "id")).unwrap_or("").replace("field:", "")
      named = class
      if named == ""
        named = Ast.text(field, "name")
      end

      file = Ast.place_of(field).file
      marks = marks.concat(
        own_marks(field).map do |mark| LockMark(class: class, mark: mark, named: named, file: file) end,
      )
    end
  end

  variables = nodes.select do |node| Ast.kind(node) == "VarDecl" end
  for node in variables
    class = variable_key(tables, Ast.text(node, "name"))
    file = Ast.place_of(node).file
    marks = marks.concat(
      own_marks(node).map do |mark| LockMark(class: class, mark: mark, named: class, file: file) end,
    )
  end

  locks = marks.select do |found| lock_mark?(found.mark) end
  errors = locks.select do |found| mark_error(found) != "" end
    .map do |found| MarkError(file: found.file, message: mark_error(found)) end

  return LockMarks(marks: locks.select do |found| mark_error(found) == "" end, errors: errors)
end

def lock_mark?(mark: String) -> Bool
  return mark.start_with?("#{QUIET_MARK}(") or mark.start_with?("#{LEVEL_MARK}(")
end

# What is wrong with a lock mark, or "".
def mark_error(mark: LockMark) -> String
  # A field of a struct with no name and no typedef has the class `.field`, which no other struct can name.
  if mark.class == "" or mark.class.start_with?(".")
    return "#{mark.named}: a lock mark needs a field of a named struct or a global"
  end

  if mark.mark.start_with?("#{QUIET_MARK}(") and mark.mark != "#{QUIET_MARK}()"
    return "#{mark.named}: CC_NO_SYSCALL_UNDER() on a lock names no lock: #{mark.mark}"
  end

  if mark.mark.start_with?("#{LEVEL_MARK}(")
    inside = mark.mark.slice(LEVEL_MARK.length + 1, mark.mark.length - LEVEL_MARK.length - 2).strip
    digits = inside != "" and inside.split("").all? do |c| c.code >= 48 and c.code <= 57 end
    if not digits or not mark.mark.end_with?(")")
      return "#{mark.named}: CC_LOCK_LEVEL takes a decimal number: #{mark.mark}"
    end
  end

  return ""
end

# The locks of an annotation `acquires(a, b)` or `releases(a)`; none for another one.
def annotated(mark: String, params: List[String]) -> List[Flow.Annotated]
  for word in LOCK_MARKS.keys
    if mark.start_with?("#{word}(") and mark.end_with?(")")
      inside = mark.slice(word.length + 1, mark.length - word.length - 2)
      texts = inside.split(",").map do |text| text.strip end.select do |text| text != "" end
      return texts.map do |text| Flow.Annotated(text: text, params: params, takes: LOCK_MARKS[word]) end
    end
  end

  return []
end

def own_marks(node: Json) -> List[String]
  written = Ast.children(node).select do |child|
    Ast.kind(child) == "DeprecatedAttr" and not Ast.flag?(child, "inherited")
  end

  return written.map(&mark_of).select do |mark| mark != "" end
end

# The text of an annotation after `cchecker:`, or "" for another `deprecated` attribute.
def mark_of(attribute: Json) -> String
  message = Ast.text(attribute, "message")
  if not message.start_with?(MARK_PREFIX)
    return ""
  end

  return message.slice(MARK_PREFIX.length, message.length - MARK_PREFIX.length)
end

def param_types_of(node: Json) -> List[String]
  parameters = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
  return parameters.map do |child| Ast.text(JSON.get(child, "type").unwrap_or(JSON.from("")), "qualType") end
end

def tables_of(nodes: List[Json]) -> Tables
  static_variables: Map[String, String] = {}
  for node in nodes
    if Ast.kind(node) == "VarDecl" and Ast.text(node, "storageClass") == "static"
      name = Ast.text(node, "name")
      if not static_variables.key?(name)
        static_variables = static_variables.put(name, "#{name}@#{Ast.place_of(node).file}")
      end
    end
  end

  records = records_of(nodes)
  field_slots: Map[String, String] = {}
  by_type: Map[String, Record] = {}
  for record in records.values
    by_type = by_type.put(record.name, record)
    for i in 0...record.fields.size
      field_slots = field_slots.put(record.field_ids[i], "field:#{record.name}.#{record.fields[i]}")
    end
  end

  # A typedef of a named struct (`typedef struct runtime runtime_t`) is another name of its type.
  for node in nodes
    if Ast.kind(node) == "TypedefDecl"
      case records.get(record_id_of(node))
        some(record) -> by_type = by_type.put(Ast.text(node, "name"), record)
        none -> next
      end
    end
  end

  return Tables(
    static_functions: static_functions_of(nodes),
    static_variables: static_variables,
    field_slots: field_slots,
    records: by_type,
    record_ids: records,
  )
end

# The keys of the static functions by name. A static function is keyed by the file of its definition, its own file: a
# header can declare a static function that each file including it defines in its own way.
def static_functions_of(nodes: List[Json]) -> Map[String, String]
  keys: Map[String, String] = {}
  statics = nodes.select do |node| Ast.kind(node) == "FunctionDecl" and Ast.text(node, "storageClass") == "static" end
  for node in statics.select(&defines?).concat(statics)
    name = Ast.text(node, "name")
    if not keys.key?(name)
      keys = keys.put(name, "#{name}@#{Ast.place_of(node).file}")
    end
  end

  return keys
end

def defines?(node: Json) -> Bool
  return Ast.children(node).any? do |child| Ast.kind(child) == "CompoundStmt" end
end

# The records of the unit by id, nested ones included. An anonymous one takes the name of a typedef of it.
def records_of(nodes: List[Json]) -> Map[String, Record]
  # The typedef names come first, so that a record nested in an anonymous typedef'd one takes the typedef name too.
  aliases: Map[String, String] = {}
  for node in nodes
    if Ast.kind(node) == "TypedefDecl" and not aliases.key?(record_id_of(node))
      aliases = aliases.put(record_id_of(node), Ast.text(node, "name"))
    end
  end

  records: Map[String, Record] = {}
  for nested in record_decls(nodes, "", aliases)
    node = nested.node
    if has_fields?(node)
      # An unnamed bit-field takes no item of an initializer; the field of an anonymous union or struct does.
      fields = Ast.children(node).select do |child|
        Ast.kind(child) == "FieldDecl" and not unnamed_bit_field?(child)
      end

      records = records.put(
        Ast.text(node, "id"),
        Record(
          name: nested.name,
          field_ids: fields.map do |f| Ast.text(f, "id") end,
          fields: fields.map do |f| Ast.text(f, "name") end,
          types: fields.map do |f| Ast.text(JSON.get(f, "type").unwrap_or(JSON.from("")), "qualType") end,
          desugared: fields.map do |f| Ast.text(JSON.get(f, "type").unwrap_or(JSON.from("")), "desugaredQualType") end,
        ),
      )
    end
  end

  return records
end

# The records at the top level and those declared in them, each with its name (see Nested). The fields of
# an anonymous union or struct are read as fields of the record it is in, as C reads them.
def record_decls(nodes: List[Json], parent: String, aliases: Map[String, String] = {}) -> List[Nested]
  found: List[Nested] = []
  for node in nodes
    if Ast.kind(node) == "RecordDecl"
      name = Ast.text(node, "name")
      if name == ""
        name = aliases.get(Ast.text(node, "id")).unwrap_or(parent)
      end

      found = found.push(Nested(node: node, name: name)).concat(record_decls(Ast.children(node), name, aliases))
    end
  end

  return found
end

def unnamed_bit_field?(node: Json) -> Bool
  return Ast.text(node, "name") == "" and Ast.flag?(node, "isBitfield")
end

def has_fields?(node: Json) -> Bool
  return Ast.children(node).any? do |child| Ast.kind(child) == "FieldDecl" end
end

# The record that a typedef names: the `decl` of the RecordType in its type.
def record_id_of(node: Json) -> String
  for child in Flow.descendants(Ast.children(node))
    if Ast.kind(child) == "RecordType"
      case JSON.get(child, "decl")
        ok(decl) -> return Ast.text(decl, "id")
        error(_) -> next
      end
    end
  end

  return ""
end

def function_of(tables: Tables, node: Json) -> Function
  name = Ast.text(node, "name")
  place = Ast.place_of(node)
  marks = Ast.children(node)
    .select do |child| Ast.kind(child) == "DeprecatedAttr" and Ast.text(child, "message").start_with?(MARK_PREFIX) end
    .map do |child|
      Ast.text(child, "message").slice(MARK_PREFIX.length, Ast.text(child, "message").length - MARK_PREFIX.length)
    end

  return Function(
    key: function_key(tables, name),
    name: name,
    file: place.file,
    line: place.line,
    column: place.column,
    defined: Ast.children(node).any? do |child| Ast.kind(child) == "CompoundStmt" end,
    marks: marks,
    noreturn: marks.include?("noreturn") or marks.include?("jumps") or noreturn?(node),
    cold: Ast.children(node).any? do |child| Ast.kind(child) == "ColdAttr" end,
  )
end

# A declaration that never returns by an attribute, or by its type, as written or behind a typedef (`fatal_fn die;`).
def noreturn?(node: Json) -> Bool
  return Ast.children(node).any? do |child| NORETURN_ATTRS.include?(Ast.kind(child)) end or Ast.noreturn_type?(node)
end

def in_function(tables: Tables, key: String, node: Json, found: Found) -> Found
  params: Map[String, Int] = {}
  parameters = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
  for i in 0...parameters.size
    params = params.put(Ast.text(parameters[i], "name"), i)
  end

  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  locals = Set.new(
    Flow.descendants(bodies).select do |n| Ast.kind(n) == "VarDecl" end.map do |n| Ast.text(n, "name") end,
  )

  scope = Scope(caller: key, params: params, locals: locals)
  walked = found
  for body in bodies
    walked = walk(tables, scope, body, walked)
  end

  return walked
end

# Records the calls and the stores of a node and of everything in it.
def walk(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  here = case Ast.kind(node)
    "CallExpr" -> with_call(tables, scope, node, found)
    "BinaryOperator" -> with_assignment(tables, scope, node, found)
    "CleanupAttr" -> with_cleanup(tables, scope, node, found)
    "VarDecl" ->
      with_field_stores(
        found,
        node,
        values(node).flat_map do |value| stored(tables, scope, local_slot(scope, node), value) end,
      )
    _ -> found
  end

  walked = here
  for child in Ast.children(node)
    walked = walk(tables, scope, child, walked)
  end

  return walked
end

# A direct call also stores the functions it passes in the parameters of the callee.
def with_call(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  parts = Ast.children(node)
  if parts.empty?
    return found
  end

  callee = bare(parts.first)
  if Ast.kind(callee) == "DeclRefExpr" and Ast.referenced_kind(callee) == "FunctionDecl"
    key = function_key(tables, Ast.referenced_name(callee))
    stores: List[Store] = []
    for i in 1...parts.size
      stores = stores.concat(stored(tables, scope, "param:#{key}:#{i - 1}", parts[i]))
    end

    noted = with_callbacks(found, callbacks_of(tables, scope, node, Ast.referenced_name(callee), parts))
    if async_fs?(Ast.referenced_name(callee), parts)
      return with_field_stores(noted, node, stores)
    end

    call = Call(caller: scope.caller, target: Target.Direct(key))
    if Known.TAKES.include?(Ast.referenced_name(callee)) and parts.size > 1
      call = call.with(lock: lock_class(slot_of(tables, scope, parts[1]).unwrap_or("")))
    end

    # The flags of a call that a flag makes return at once, as the place of its argument says.
    at = Known.FLAG_ARGUMENTS.get(Ast.referenced_name(callee)).unwrap_or(-1)
    if at >= 0 and at + 1 < parts.size
      flag = Known.nonblocking_name(Ast.referenced_name(callee))
      # A mode is one value, not bits to add: only the constant itself names it (`UV_RUN_ONCE | UV_RUN_NOWAIT`
      # does not).
      named = names_flag?(parts[at + 1], flag, Known.one_value?(Ast.referenced_name(callee)))
      call = call.with(flags: constant(parts[at + 1]), named: named)
    end

    called = noted.with(calls: noted.calls.push(call))
    return with_field_stores(called, node, stores)
  end

  case slot_of(tables, scope, callee)
    some(slot) ->
      place = Ast.start_of(node)
      call = Call(caller: scope.caller, target: Target.Slot(slot), line: place.line, column: place.column)
      return found.with(calls: found.calls.push(call))
    none -> return found
  end
end

# The callbacks of a call of libuv that runs them on the loop. A null pointer (`NULL`, 0) is no callback.
def callbacks_of(tables: Tables, scope: Scope, node: Json, name: String, parts: List[Json]) -> List[Callback]
  places = Known.LOOP_CALLBACKS.get(name).unwrap_or([])
  if places.empty?
    return []
  end

  # The place of the call: where its macro was expanded, when a macro wrote it.
  place = Ast.start_of(node)
  found: List[Callback] = []
  for argument in places
    if argument + 1 < parts.size and not null?(parts[argument + 1])
      sources = stored(tables, scope, CALLBACK_SLOT, parts[argument + 1]).map do |store| store.source end
      found = found.push(
        Callback(call: name, argument: argument, file: place.file, line: place.line, sources: sources),
      )
    end
  end

  return found
end

def null?(node: Json) -> Bool
  value = bare(node)
  return Ast.kind(value) == "IntegerLiteral" and Ast.text(value, "value") == "0"
end

def with_callbacks(found: Found, callbacks: List[Callback]) -> Found
  return found.with(callbacks: found.callbacks.concat(callbacks))
end

# Records the stores of a node (a variable with an initializer, an assignment). A store in a field that libuv calls on
# the loop (`Known.LOOP_CALLBACK_FIELDS`) is also a callback, placed at the node, with the field in `call` and -1 as
# its argument place: a later call (`uv_spawn`) reads the field, so no argument of the node holds it.
def with_field_stores(found: Found, node: Json, stores: List[Store]) -> Found
  place = Ast.start_of(node)
  callbacks = stores.flat_map do |store|
    case Known.LOOP_CALLBACK_FIELDS.get(store.slot)
      some(field) -> [Callback(call: field, argument: -1, file: place.file, line: place.line, sources: [store.source])]
      none -> []
    end
  end

  return with_callbacks(with_stores(found, stores), callbacks)
end

# The value of an integer constant written with literals, `|` and `+` (`O_RDONLY | O_NONBLOCK` once the macros are
# expanded), or -1 for any other expression.
def constant(node: Json) -> Int
  value = Flow.see_through(node)
  parts = Ast.children(value)
  case Ast.kind(value)
    "IntegerLiteral" -> return Ast.text(value, "value").to_i.unwrap_or(-1)
    "BinaryOperator" ->
      opcode = Ast.text(value, "opcode")
      if parts.size != 2 or (opcode != "|" and opcode != "+")
        return -1
      end

      left = constant(parts[0])
      right = constant(parts[1])
      if left < 0 or right < 0
        return -1
      end

      if opcode == "+"
        return left + right
      end

      return Int.bit_or(left, right)
    _ -> return -1
  end
end

# Whether flags joined with `|` or `+` name the constant of an enum `flag` (`MSG_DONTWAIT | MSG_NOSIGNAL`), or,
# when the
# argument is one `exact` value, whether it is that constant alone.
def names_flag?(node: Json, flag: String, exact: Bool) -> Bool
  value = Flow.see_through(node)
  parts = Ast.children(value)
  case Ast.kind(value)
    "DeclRefExpr" -> return Ast.referenced_kind(value) == "EnumConstantDecl" and Ast.referenced_name(value) == flag
    "BinaryOperator" ->
      opcode = Ast.text(value, "opcode")
      return not exact and (opcode == "|" or opcode == "+") and parts.any? do |part| names_flag?(part, flag, exact) end
    _ -> return false
  end
end

# The class of a lock by its slot: a field (`field:queue.mu`) or a global (`var:big_lock`); "" for a local or a
# parameter, whose lock the rules do not know.
def lock_class(slot: String) -> String
  for prefix in ["field:", "var:"]
    if slot.start_with?(prefix)
      return slot.slice(prefix.length, slot.length - prefix.length)
    end
  end

  return ""
end

# A call of libuv's file functions with a callback, its last argument, only starts the work: the loop runs it on a
# thread of its own. Without one (NULL or 0) it runs at once on the calling thread.
def async_fs?(name: String, parts: List[Json]) -> Bool
  if not name.start_with?("uv_fs_") or parts.size < 2
    return false
  end

  last = bare(parts.last)
  return not (Ast.kind(last) == "IntegerLiteral" and Ast.text(last, "value") == "0")
end

# `__attribute__((cleanup(f)))` on a variable calls f when the variable goes out of scope.
def with_cleanup(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  name = Ast.text(JSON.get(node, "cleanup_function").unwrap_or(JSON.from("")), "name")
  if name == ""
    return found
  end

  return found.with(
    calls: found.calls.push(Call(caller: scope.caller, target: Target.Direct(function_key(tables, name)))),
  )
end

def with_assignment(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  parts = Ast.children(node)
  if Ast.text(node, "opcode") != "=" or parts.size != 2
    return found
  end

  case slot_of(tables, scope, parts[0])
    some(slot) -> return with_field_stores(found, node, stored(tables, scope, slot, parts[1]))
    none -> return found
  end
end

def with_stores(found: Found, stores: List[Store]) -> Found
  return found.with(stores: found.stores.concat(stores))
end

# What a value stores in a slot: the functions it names, or a copy of the slot it reads. The items of an initializer of
# a struct go to the slots of its fields, and those of an array to the slot of the array.
def stored(tables: Tables, scope: Scope, slot: String, value: Json) -> List[Store]
  node = bare(value)
  case Ast.kind(node)
    "InitListExpr" -> return stored_items(tables, scope, slot, node)
    "DeclRefExpr" ->
      if Ast.referenced_kind(node) == "FunctionDecl"
        return [Store(slot: slot, source: Source.Function(function_key(tables, Ast.referenced_name(node))))]
      end

      return copied(tables, scope, slot, node)
    "MemberExpr" -> return copied(tables, scope, slot, node)
    "ArraySubscriptExpr" -> return copied(tables, scope, slot, node)
    "ConditionalOperator" ->
      return Ast.children(node).drop(1).flat_map do |branch| stored(tables, scope, slot, branch) end
    _ -> return []
  end
end

def stored_items(tables: Tables, scope: Scope, slot: String, node: Json) -> List[Store]
  items = Ast.children(node)
  # The initializer of a union names the field it sets, which need not be the first.
  case JSON.get(node, "field")
    ok(field) ->
      case tables.field_slots.get(Ast.text(field, "id"))
        some(field_slot) -> return items.flat_map do |item| stored(tables, scope, field_slot, item) end
        none -> return []
      end

    error(_) -> return stored_fields(tables, scope, slot, node)
  end
end

def stored_fields(tables: Tables, scope: Scope, slot: String, node: Json) -> List[Store]
  items = Ast.children(node)
  case record_of(tables, node)
    some(record) ->
      stores: List[Store] = []
      for i in 0...[items.size, record.fields.size].min.unwrap_or(0)
        stores = stores.concat(stored(tables, scope, "field:#{record.name}.#{record.fields[i]}", items[i]))
      end

      return stores
    none -> return items.flat_map do |item| stored(tables, scope, slot, item) end
  end
end

# Only a function pointer is followed: a copy of any other value stores nothing.
def copied(tables: Tables, scope: Scope, slot: String, node: Json) -> List[Store]
  if not function_pointer?(node)
    return []
  end

  case slot_of(tables, scope, node)
    some(from) if from != slot -> return [Store(slot: slot, source: Source.Copy(from))]
    _ -> return []
  end
end

# The slot that an expression reads or writes: a parameter, a variable, a field, or an item of one of them.
def slot_of(tables: Tables, scope: Scope, expression: Json) -> Optional[String]
  node = bare(expression)
  case Ast.kind(node)
    "DeclRefExpr" -> return named_slot(tables, scope, node)
    "MemberExpr" -> return tables.field_slots.get(Ast.text(node, "referencedMemberDecl"))
    "ArraySubscriptExpr" ->
      parts = Ast.children(node)
      if parts.empty?
        return none
      end

      return slot_of(tables, scope, parts.first)
    _ -> return none
  end
end

def named_slot(tables: Tables, scope: Scope, node: Json) -> Optional[String]
  name = Ast.referenced_name(node)
  case Ast.referenced_kind(node)
    "ParmVarDecl" -> return scope.params.get(name).map do |i| "param:#{scope.caller}:#{i}" end
    "VarDecl" ->
      if scope.locals.include?(name)
        return some("local:#{scope.caller}:#{name}")
      end

      return some("var:#{variable_key(tables, name)}")
    _ -> return none
  end
end

# Whether the type of an expression is a pointer to a function, `int (*)(int)` or `int (*const)(int)`, also under a
# typedef.
def function_pointer?(node: Json) -> Bool
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  return pointer_text?(Ast.text(type, "qualType")) or pointer_text?(Ast.text(type, "desugaredQualType"))
end

def pointer_text?(type: String) -> Bool
  return type.include?("(*") and type.include?(")(")
end

# What a declaration at the top level of the file reads: no parameters and no local variables.
def file_scope() -> Scope
  return Scope(caller: "", params: {}, locals: Set.new([]))
end

def local_slot(scope: Scope, node: Json) -> String
  return "local:#{scope.caller}:#{Ast.text(node, "name")}"
end

# The record of the initializer of a struct, by its type: `struct ops`, `const struct ops` or a typedef name. The
# initializer of a union names its field (`stored_items`).
def record_of(tables: Tables, node: Json) -> Optional[Record]
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  name = Ast.text(type, "qualType")
  for word in ["const ", "volatile ", "struct "]
    name = name.replace(word, "")
  end

  return tables.records.get(name.strip)
end

# The expression without the casts, parentheses, `&` and `*` around it, which do not change the function it names.
def bare(node: Json) -> Json
  parts = Ast.children(node)
  if parts.empty?
    return node
  end

  if TRANSPARENT.include?(Ast.kind(node))
    return bare(parts.first)
  end

  if Ast.kind(node) == "UnaryOperator" and (Ast.text(node, "opcode") == "&" or Ast.text(node, "opcode") == "*")
    return bare(parts.first)
  end

  return node
end

# The value of a variable: its children that are no attribute.
def values(node: Json) -> List[Json]
  return Ast.children(node).select do |child| not Ast.kind(child).end_with?("Attr") end
end

def function_key(tables: Tables, name: String) -> String
  return tables.static_functions.get(name).unwrap_or(name)
end

def variable_key(tables: Tables, name: String) -> String
  return tables.static_variables.get(name).unwrap_or(name)
end
