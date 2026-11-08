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

# The prefix of an annotation of include/cchecker.h. Under CCHECKER_AST the macros are `deprecated` attributes, whose
# message clang 19 keeps in its JSON AST (it drops the string of an `annotate` attribute).
MARK_PREFIX = "cchecker:"

# The attributes of a function that never returns.
NORETURN_ATTRS = Set.new(["C11NoReturnAttr", "NoReturnAttr", "CXX11NoReturnAttr"])

# The annotations that name locks, and whether the function takes them.
LOCK_MARKS = {"acquires": true, "releases": false}

PAIR_MARK = "pair("

# The marks of ownership.
OWNS = "owns"
FREES = "frees"

# The marks of the collector rule.
GC = "gc"
GC_ALLOC = "gc_alloc"

# The nodes a function pointer goes through on its way to a call or a store, which do not change where it points.
TRANSPARENT = Set.new(["ImplicitCastExpr", "CStyleCastExpr", "ParenExpr", "CompoundLiteralExpr"])

## A function of the project, as one translation unit declares it. `key` is its name, and `name@file` for a static
## function, which is another function in each file. `marks` are the annotations, as written after `cchecker:`
## (`short`, `blocking`, `hot`). The place is that of the declaration, of the definition when `defined`.
export struct Function
  key: String
  name: String
  file: String
  line: Int
  column: Int
  defined: Bool
  marks: List[String]
end

## Where a call goes: a function, by key, or a slot.
export enum Target
  Direct(String)
  Slot(String)
end

## A call of `caller`, a function key.
export struct Call
  caller: String
  target: Target
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
end

## The functions, calls and stores of one translation unit, the graphs of its functions that take or release a lock
## or own a pointer, the annotations of its locks, and the findings of the collector rule, which reads one unit.
export struct Unit
  functions: List[Function]
  calls: List[Call]
  stores: List[Store]
  bodies: List[Flow.Body] = []
  lock_marks: List[LockMark] = []
  collected: List[Finding] = []
end

# A struct or union: its name (a typedef name for an anonymous one) and the ids and names of its fields.
struct Record
  name: String
  field_ids: List[String]
  fields: List[String]
  types: List[String] = []
end

# The functions of a CC_PAIR(set, restore), by name.
struct Pair
  set: String
  restore: String
end

# A record declaration and the name of the record it is declared in ("" at the top level).
struct Nested
  node: Json
  parent: String
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
  found = Found(calls: [], stores: [])
  for node in nodes
    case Ast.kind(node)
      "FunctionDecl" ->
        function = function_of(tables, node)
        functions = functions.push(function)
        found = in_function(tables, function.key, node, found)
        own = paired(ctx, tables, function)
        if function.defined and (Flow.locks?(own, node) or Flow.owns?(own, function.key, node))
          bodies = bodies.push(Flow.body_of(own, function.key, node))
        end

        if function.defined
          params = owned_params(ctx, function.key, node)
          collected = collected.concat(Collector.stores(marks, ctx, function.name, Ast.place_of(node), params, node))
        end

      "VarDecl" ->
        slot = "var:#{variable_key(tables, Ast.text(node, "name"))}"
        for value in values(node)
          found = with_stores(found, stored(tables, file_scope(), slot, value))
        end

      _ -> next
    end
  end

  return ok(
    Unit(
      functions: functions,
      calls: found.calls,
      stores: found.stores,
      bodies: bodies,
      lock_marks: lock_marks_of(tables, nodes),
      collected: collected,
    ),
  )
end

# What the functions of the unit say about locks, from all their declarations: the locks of CC_ACQUIRES and
# CC_RELEASES, with the names of the parameters of the declaration that carries them, and whether they never return
# (`_Noreturn`, `__attribute__((noreturn))`, CC_NORETURN).
def context_of(tables: Tables, nodes: List[Json]) -> Flow.Context
  callees: Map[String, Flow.Callee] = {}
  globals = Set.new(nodes.select do |node| Ast.kind(node) == "VarDecl" end.map do |node| Ast.text(node, "name") end)
  declarations = nodes.select do |node| Ast.kind(node) == "FunctionDecl" end
  for node in declarations
    function = function_of(tables, node)
    params = params_of(node)
    types = param_types_of(node)
    # A definition inherits the annotations of the prototype before it, in the names of the prototype's parameters:
    # only the declaration that wrote an annotation knows what its names are.
    locks = own_marks(node)
      .flat_map do |mark| annotated(mark, params) end
      .map do |lock| lock.with(class: class_of_text(tables, globals, lock.text, params, types)) end

    attributes = Ast.children(node).map(&Ast.kind)
    stops = function.marks.include?("noreturn") or attributes.any? do |name| NORETURN_ATTRS.include?(name) end
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
    globals: globals,
    owning: owning_of(tables, nodes),
  )
end

# What the declarations of the unit say about ownership: CC_OWNS on a function (it returns an owned pointer), on a
# parameter (it takes what the caller passes), on a field or a global (a store into it hands a pointer on), and
# CC_FREES on a parameter. The marks of the parameters of all the declarations of a function hold, by index.
def owning_of(tables: Tables, nodes: List[Json]) -> Flow.Owning
  returns: Set[String] = Set.new([])
  takes: Map[String, List[Int]] = {}
  frees: Map[String, List[Int]] = {}
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

      if marks.include?(FREES) and not frees.get(key, []).include?(i)
        frees = frees.put(key, frees.get(key, []).push(i))
      end
    end
  end

  fields: Set[String] = Set.new([])
  for nested in record_decls(nodes, "")
    record_fields = Ast.children(nested.node).select do |child| Ast.kind(child) == "FieldDecl" end
    for field in record_fields
      if own_marks(field).include?(OWNS)
        fields = fields.add(Ast.text(field, "id"))
      end
    end
  end

  globals = nodes.select do |n| Ast.kind(n) == "VarDecl" and own_marks(n).include?(OWNS) end
    .map do |n| Ast.text(n, "name") end

  return Flow.Owning(returns: returns, takes: takes, frees: frees, fields: fields, globals: Set.new(globals))
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
        named = tables.record_ids.get(record_id_of(node)).map do |r| r.name end.unwrap_or("")
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
    for name in tables.records.keys
      record = tables.records[name]
      if not grown.holders.include?(name) and record.types.any? do |t| Collector.collector_type?(grown, t) end
        grown = grown.with(holders: grown.holders.add(name).add(record.name))
        grew = true
      end
    end
  end

  return grown
end

# The names of the parameters of a function that own what the caller passes (CC_OWNS or CC_FREES).
def owned_params(ctx: Flow.Context, key: String, node: Json) -> List[String]
  names = params_of(node)
  indices = ctx.owning.takes.get(key, []).concat(ctx.owning.frees.get(key, []))
  return indices.select do |i| i < names.size end.map do |i| names[i] end
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

# The callees with the lock of a pair: `set` takes it and `restore` releases it. The lock names no parameter, so a call
# passes nothing to it. A pair marked twice gives `set` two takes and `restore` two releases, which cancel the
# same way.
def with_pair(callees: Map[String, Flow.Callee], tables: Tables, pair: Pair) -> Map[String, Flow.Callee]
  text = "#{Flow.PAIR_PREFIX}#{pair.set}"
  added = callees
  for side in [pair.set, pair.restore]
    lock = Flow.Annotated(text: text, params: [], takes: side == pair.set, pair: pair.restore)
    key = function_key(tables, side)
    known = added.get(key).unwrap_or(Flow.Callee(locks: [], stops: false))
    added = added.put(key, known.with(locks: known.locks.push(lock)))
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
# `pool.mu`; a global is its name. "" when a type on the way is not a struct of the project.
def class_of_text(
  tables: Tables,
  globals: Set[String],
  text: String,
  params: List[String],
  types: List[String],
) -> String
  path = Flow.shown_of(text).replace("*", "").replace("->", ".").split(".")
  at = -1
  for i in 0...params.size
    if params[i] == path.first
      at = i
    end
  end

  if at < 0
    if path.size == 1 and globals.include?(path.first)
      return path.first
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

# The name of the struct of a type as clang writes it: `struct server *` and `const server *` are `server`.
def type_name(type: String) -> String
  name = type
  for word in ["const ", "volatile ", "struct ", "union ", "restrict", "*"]
    name = name.replace(word, "")
  end

  return name.strip
end

# The marks of the fields and the global variables of the unit, by their class.
def lock_marks_of(tables: Tables, nodes: List[Json]) -> List[LockMark]
  found: List[LockMark] = []
  for nested in record_decls(nodes, "")
    fields = Ast.children(nested.node).select do |child| Ast.kind(child) == "FieldDecl" end
    for field in fields
      class = tables.field_slots.get(Ast.text(field, "id")).unwrap_or("").replace("field:", "")
      found = found.concat(own_marks(field).map do |mark| LockMark(class: class, mark: mark) end)
    end
  end

  variables = nodes.select do |node| Ast.kind(node) == "VarDecl" end
  for node in variables
    found = found.concat(own_marks(node).map do |mark| LockMark(class: Ast.text(node, "name"), mark: mark) end)
  end

  return found.select do |mark| mark.class != "" end
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

def params_of(node: Json) -> List[String]
  parameters = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
  return parameters.map do |child| Ast.text(child, "name") end
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
  records: Map[String, Record] = {}
  for nested in record_decls(nodes, "")
    node = nested.node
    if has_fields?(node)
      # An unnamed bit-field takes no item of an initializer; the field of an anonymous union or struct does.
      fields = Ast.children(node).select do |child|
        Ast.kind(child) == "FieldDecl" and not unnamed_bit_field?(child)
      end

      name = Ast.text(node, "name")
      if name == ""
        name = nested.parent
      end

      records = records.put(
        Ast.text(node, "id"),
        Record(
          name: name,
          field_ids: fields.map do |f| Ast.text(f, "id") end,
          fields: fields.map do |f| Ast.text(f, "name") end,
          types: fields.map do |f| Ast.text(JSON.get(f, "type").unwrap_or(JSON.from("")), "qualType") end,
        ),
      )
    end
  end

  for node in nodes
    if Ast.kind(node) == "TypedefDecl"
      case records.get(record_id_of(node))
        some(record) if record.name == "" ->
          records = records.put(record_id_of(node), record.with(name: Ast.text(node, "name")))
        _ -> next
      end
    end
  end

  return records
end

# The records at the top level and those declared in them, each with the name of the record it is in. The fields of
# an anonymous union or struct are read as fields of the record it is in, as C reads them.
def record_decls(nodes: List[Json], parent: String) -> List[Nested]
  found: List[Nested] = []
  for node in nodes
    if Ast.kind(node) == "RecordDecl"
      name = Ast.text(node, "name")
      if name == ""
        name = parent
      end

      found = found.push(Nested(node: node, parent: parent)).concat(record_decls(Ast.children(node), name))
    end
  end

  return found
end

def unnamed_bit_field?(node: Json) -> Bool
  return Ast.text(node, "name") == "" and Ast.flag?(node, "isBitfield")
end

# Every node under the given ones, in order.
def all_nodes(nodes: List[Json]) -> List[Json]
  found: List[Json] = []
  for node in nodes
    found = found.push(node).concat(all_nodes(Ast.children(node)))
  end

  return found
end

def has_fields?(node: Json) -> Bool
  return Ast.children(node).any? do |child| Ast.kind(child) == "FieldDecl" end
end

# The record that a typedef names: the `decl` of the RecordType in its type.
def record_id_of(node: Json) -> String
  for child in all_nodes(Ast.children(node))
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
  )
end

def in_function(tables: Tables, key: String, node: Json, found: Found) -> Found
  params: Map[String, Int] = {}
  parameters = Ast.children(node).select do |child| Ast.kind(child) == "ParmVarDecl" end
  for i in 0...parameters.size
    params = params.put(Ast.text(parameters[i], "name"), i)
  end

  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  locals = Set.new(all_nodes(bodies).select do |n| Ast.kind(n) == "VarDecl" end.map do |n| Ast.text(n, "name") end)
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
      with_stores(found, values(node).flat_map do |value| stored(tables, scope, local_slot(scope, node), value) end)
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

    if async_fs?(Ast.referenced_name(callee), parts)
      return with_stores(found, stores)
    end

    called = found.with(calls: found.calls.push(Call(caller: scope.caller, target: Target.Direct(key))))
    return with_stores(called, stores)
  end

  case slot_of(tables, scope, callee)
    some(slot) -> return found.with(calls: found.calls.push(Call(caller: scope.caller, target: Target.Slot(slot))))
    none -> return found
  end
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
    some(slot) -> return with_stores(found, stored(tables, scope, slot, parts[1]))
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
