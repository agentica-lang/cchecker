## What the rules need from the AST of one translation unit: its functions with their annotations, its calls, and the
## functions it stores in function pointers.
##
## A function pointer is followed through the place it is stored in, a slot: a parameter of a function, a variable or
## a field of a struct. A call through a slot reaches every function the project stores in that slot anywhere; a slot
## that no function is stored in reaches nothing.

import Ast from "ast"
import Flow from "flow"

# The prefix of an annotation of include/cchecker.h. Under CCHECKER_AST the macros are `deprecated` attributes, whose
# message clang 19 keeps in its JSON AST (it drops the string of an `annotate` attribute).
MARK_PREFIX = "cchecker:"

# The attributes of a function that never returns.
NORETURN_ATTRS = Set.new(["C11NoReturnAttr", "NoReturnAttr", "CXX11NoReturnAttr"])

# The annotations that name locks, and whether the function takes them.
LOCK_MARKS = {"acquires": true, "releases": false}

# The most nodes of the AST of a function that the path rules build a graph for, about four times the largest function
# of the Agentica VM. A larger function is an error of the tool, so a run never runs out of memory on one.
MAX_BODY_NODES = 20_000

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

## The functions, calls and stores of one translation unit, and the graphs of its functions that take or release a
## lock. `too_large` names the functions too large for a graph (`MAX_BODY_NODES`).
export struct Unit
  functions: List[Function]
  calls: List[Call]
  stores: List[Store]
  bodies: List[Flow.Body] = []
  too_large: List[String] = []
end

# A struct or union: its name (a typedef name for an anonymous one) and the ids and names of its fields.
struct Record
  name: String
  field_ids: List[String]
  fields: List[String]
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
  functions: List[Function] = []
  bodies: List[Flow.Body] = []
  too_large: List[String] = []
  found = Found(calls: [], stores: [])
  for node in nodes
    case Ast.kind(node)
      "FunctionDecl" ->
        function = function_of(tables, node)
        functions = functions.push(function)
        found = in_function(tables, function.key, node, found)
        if function.defined and Flow.locks?(ctx, node)
          if Ast.size_of(node, MAX_BODY_NODES) > MAX_BODY_NODES
            too_large = too_large.push(function.name)
          else
            bodies = bodies.push(Flow.body_of(ctx, function.key, node))
          end
        end

      "VarDecl" ->
        slot = "var:#{variable_key(tables, Ast.text(node, "name"))}"
        for value in values(node)
          found = with_stores(found, stored(tables, file_scope(), slot, value))
        end

      _ -> next
    end
  end

  return ok(Unit(functions: functions, calls: found.calls, stores: found.stores, bodies: bodies, too_large: too_large))
end

# What the functions of the unit say about locks, from all their declarations: the locks of CC_ACQUIRES and
# CC_RELEASES, with the names of the parameters of the declaration that carries them, and whether they never return
# (`_Noreturn`, `__attribute__((noreturn))`, CC_NORETURN).
def context_of(tables: Tables, nodes: List[Json]) -> Flow.Context
  callees: Map[String, Flow.Callee] = {}
  declarations = nodes.select do |node| Ast.kind(node) == "FunctionDecl" end
  for node in declarations
    function = function_of(tables, node)
    params = params_of(node)
    # A definition inherits the annotations of the prototype before it, in the names of the prototype's parameters:
    # only the declaration that wrote an annotation knows what its names are.
    locks = own_marks(node).flat_map do |mark| annotated(mark, params) end
    attributes = Ast.children(node).map(&Ast.kind)
    stops = function.marks.include?("noreturn") or attributes.any? do |name| NORETURN_ATTRS.include?(name) end
    if not locks.empty? or stops
      known = callees.get(function.key).unwrap_or(Flow.Callee(locks: [], stops: false))
      callees = callees.put(function.key, Flow.Callee(locks: known.locks.concat(locks), stops: known.stops or stops))
    end
  end

  return Flow.Context(callees: callees, statics: tables.static_functions)
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

  return Tables(
    static_functions: static_functions_of(nodes),
    static_variables: static_variables,
    field_slots: field_slots,
    records: by_type,
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
