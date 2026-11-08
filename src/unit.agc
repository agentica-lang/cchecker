## What the rules need from the AST of one translation unit: its functions with their annotations, its calls, and the
## functions it stores in function pointers.
##
## A function pointer is followed through the place it is stored in, a slot: a parameter of a function, a variable or
## a field of a struct. A call through a slot reaches every function the project stores in that slot anywhere; a slot
## that no function is stored in reaches nothing.

# The prefix of an annotation of include/cchecker.h. Under CCHECKER_AST the macros are `deprecated` attributes, whose
# message clang 19 keeps in its JSON AST (it drops the string of an `annotate` attribute).
MARK_PREFIX = "cchecker:"

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

## The functions, calls and stores of one translation unit.
export struct Unit
  functions: List[Function]
  calls: List[Call]
  stores: List[Store]
end

struct Place
  file: String
  line: Int
  column: Int
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
  functions: List[Function] = []
  found = Found(calls: [], stores: [])
  for node in nodes
    case kind(node)
      "FunctionDecl" ->
        function = function_of(tables, node)
        functions = functions.push(function)
        found = in_function(tables, function.key, node, found)
      "VarDecl" ->
        slot = "var:#{variable_key(tables, text(node, "name"))}"
        for value in values(node)
          found = with_stores(found, stored(tables, file_scope(), slot, value))
        end

      _ -> next
    end
  end

  return ok(Unit(functions: functions, calls: found.calls, stores: found.stores))
end

def tables_of(nodes: List[Json]) -> Tables
  static_variables: Map[String, String] = {}
  for node in nodes
    if kind(node) == "VarDecl" and text(node, "storageClass") == "static"
      name = text(node, "name")
      if not static_variables.key?(name)
        static_variables = static_variables.put(name, "#{name}@#{place_of(node).file}")
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
  statics = nodes.select do |node| kind(node) == "FunctionDecl" and text(node, "storageClass") == "static" end
  for node in statics.select(&defines?).concat(statics)
    name = text(node, "name")
    if not keys.key?(name)
      keys = keys.put(name, "#{name}@#{place_of(node).file}")
    end
  end

  return keys
end

def defines?(node: Json) -> Bool
  return children(node).any? do |child| kind(child) == "CompoundStmt" end
end

# The records of the unit by id, nested ones included. An anonymous one takes the name of a typedef of it.
def records_of(nodes: List[Json]) -> Map[String, Record]
  records: Map[String, Record] = {}
  for nested in record_decls(nodes, "")
    node = nested.node
    if has_fields?(node)
      # An unnamed bit-field takes no item of an initializer; the field of an anonymous union or struct does.
      fields = children(node).select do |child| kind(child) == "FieldDecl" and not unnamed_bit_field?(child) end
      name = text(node, "name")
      if name == ""
        name = nested.parent
      end

      records = records.put(
        text(node, "id"),
        Record(
          name: name,
          field_ids: fields.map do |f| text(f, "id") end,
          fields: fields.map do |f| text(f, "name") end,
        ),
      )
    end
  end

  for node in nodes
    if kind(node) == "TypedefDecl"
      case records.get(record_id_of(node))
        some(record) if record.name == "" ->
          records = records.put(record_id_of(node), record.with(name: text(node, "name")))
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
    if kind(node) == "RecordDecl"
      name = text(node, "name")
      if name == ""
        name = parent
      end

      found = found.push(Nested(node: node, parent: parent)).concat(record_decls(children(node), name))
    end
  end

  return found
end

def unnamed_bit_field?(node: Json) -> Bool
  return text(node, "name") == "" and flag?(node, "isBitfield")
end

# Every node under the given ones, in order.
def all_nodes(nodes: List[Json]) -> List[Json]
  found: List[Json] = []
  for node in nodes
    found = found.push(node).concat(all_nodes(children(node)))
  end

  return found
end

def has_fields?(node: Json) -> Bool
  return children(node).any? do |child| kind(child) == "FieldDecl" end
end

# The record that a typedef names: the `decl` of the RecordType in its type.
def record_id_of(node: Json) -> String
  for child in all_nodes(children(node))
    if kind(child) == "RecordType"
      case JSON.get(child, "decl")
        ok(decl) -> return text(decl, "id")
        error(_) -> next
      end
    end
  end

  return ""
end

def function_of(tables: Tables, node: Json) -> Function
  name = text(node, "name")
  place = place_of(node)
  marks = children(node)
    .select do |child| kind(child) == "DeprecatedAttr" and text(child, "message").start_with?(MARK_PREFIX) end
    .map do |child|
      text(child, "message").slice(MARK_PREFIX.length, text(child, "message").length - MARK_PREFIX.length)
    end

  return Function(
    key: function_key(tables, name),
    name: name,
    file: place.file,
    line: place.line,
    column: place.column,
    defined: children(node).any? do |child| kind(child) == "CompoundStmt" end,
    marks: marks,
  )
end

def in_function(tables: Tables, key: String, node: Json, found: Found) -> Found
  params: Map[String, Int] = {}
  parameters = children(node).select do |child| kind(child) == "ParmVarDecl" end
  for i in 0...parameters.size
    params = params.put(text(parameters[i], "name"), i)
  end

  bodies = children(node).select do |child| kind(child) == "CompoundStmt" end
  locals = Set.new(all_nodes(bodies).select do |n| kind(n) == "VarDecl" end.map do |n| text(n, "name") end)
  scope = Scope(caller: key, params: params, locals: locals)
  walked = found
  for body in bodies
    walked = walk(tables, scope, body, walked)
  end

  return walked
end

# Records the calls and the stores of a node and of everything in it.
def walk(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  here = case kind(node)
    "CallExpr" -> with_call(tables, scope, node, found)
    "BinaryOperator" -> with_assignment(tables, scope, node, found)
    "CleanupAttr" -> with_cleanup(tables, scope, node, found)
    "VarDecl" ->
      with_stores(found, values(node).flat_map do |value| stored(tables, scope, local_slot(scope, node), value) end)
    _ -> found
  end

  walked = here
  for child in children(node)
    walked = walk(tables, scope, child, walked)
  end

  return walked
end

# A direct call also stores the functions it passes in the parameters of the callee.
def with_call(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  parts = children(node)
  if parts.empty?
    return found
  end

  callee = bare(parts.first)
  if kind(callee) == "DeclRefExpr" and referenced_kind(callee) == "FunctionDecl"
    key = function_key(tables, referenced_name(callee))
    stores: List[Store] = []
    for i in 1...parts.size
      stores = stores.concat(stored(tables, scope, "param:#{key}:#{i - 1}", parts[i]))
    end

    if async_fs?(referenced_name(callee), parts)
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
  return not (kind(last) == "IntegerLiteral" and text(last, "value") == "0")
end

# `__attribute__((cleanup(f)))` on a variable calls f when the variable goes out of scope.
def with_cleanup(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  name = text(JSON.get(node, "cleanup_function").unwrap_or(JSON.from("")), "name")
  if name == ""
    return found
  end

  return found.with(
    calls: found.calls.push(Call(caller: scope.caller, target: Target.Direct(function_key(tables, name)))),
  )
end

def with_assignment(tables: Tables, scope: Scope, node: Json, found: Found) -> Found
  parts = children(node)
  if text(node, "opcode") != "=" or parts.size != 2
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
  case kind(node)
    "InitListExpr" -> return stored_items(tables, scope, slot, node)
    "DeclRefExpr" ->
      if referenced_kind(node) == "FunctionDecl"
        return [Store(slot: slot, source: Source.Function(function_key(tables, referenced_name(node))))]
      end

      return copied(tables, scope, slot, node)
    "MemberExpr" -> return copied(tables, scope, slot, node)
    "ArraySubscriptExpr" -> return copied(tables, scope, slot, node)
    "ConditionalOperator" -> return children(node).drop(1).flat_map do |branch| stored(tables, scope, slot, branch) end
    _ -> return []
  end
end

def stored_items(tables: Tables, scope: Scope, slot: String, node: Json) -> List[Store]
  items = children(node)
  # The initializer of a union names the field it sets, which need not be the first.
  case JSON.get(node, "field")
    ok(field) ->
      case tables.field_slots.get(text(field, "id"))
        some(field_slot) -> return items.flat_map do |item| stored(tables, scope, field_slot, item) end
        none -> return []
      end

    error(_) -> return stored_fields(tables, scope, slot, node)
  end
end

def stored_fields(tables: Tables, scope: Scope, slot: String, node: Json) -> List[Store]
  items = children(node)
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
  case kind(node)
    "DeclRefExpr" -> return named_slot(tables, scope, node)
    "MemberExpr" -> return tables.field_slots.get(text(node, "referencedMemberDecl"))
    "ArraySubscriptExpr" ->
      parts = children(node)
      if parts.empty?
        return none
      end

      return slot_of(tables, scope, parts.first)
    _ -> return none
  end
end

def named_slot(tables: Tables, scope: Scope, node: Json) -> Optional[String]
  name = referenced_name(node)
  case referenced_kind(node)
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
  return pointer_text?(text(type, "qualType")) or pointer_text?(text(type, "desugaredQualType"))
end

def pointer_text?(type: String) -> Bool
  return type.include?("(*") and type.include?(")(")
end

# What a declaration at the top level of the file reads: no parameters and no local variables.
def file_scope() -> Scope
  return Scope(caller: "", params: {}, locals: Set.new([]))
end

def local_slot(scope: Scope, node: Json) -> String
  return "local:#{scope.caller}:#{text(node, "name")}"
end

# The record of the initializer of a struct, by its type: `struct ops`, `const struct ops` or a typedef name. The
# initializer of a union names its field (`stored_items`).
def record_of(tables: Tables, node: Json) -> Optional[Record]
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  name = text(type, "qualType")
  for word in ["const ", "volatile ", "struct "]
    name = name.replace(word, "")
  end

  return tables.records.get(name.strip)
end

# The expression without the casts, parentheses, `&` and `*` around it, which do not change the function it names.
def bare(node: Json) -> Json
  parts = children(node)
  if parts.empty?
    return node
  end

  if TRANSPARENT.include?(kind(node))
    return bare(parts.first)
  end

  if kind(node) == "UnaryOperator" and (text(node, "opcode") == "&" or text(node, "opcode") == "*")
    return bare(parts.first)
  end

  return node
end

# The value of a variable: its children that are no attribute.
def values(node: Json) -> List[Json]
  return children(node).select do |child| not kind(child).end_with?("Attr") end
end

def function_key(tables: Tables, name: String) -> String
  return tables.static_functions.get(name).unwrap_or(name)
end

def variable_key(tables: Tables, name: String) -> String
  return tables.static_variables.get(name).unwrap_or(name)
end

# The place of a declaration: where its macro was expanded, when it comes from one.
def place_of(node: Json) -> Place
  loc = JSON.get(node, "loc").unwrap_or(JSON.from(""))
  case JSON.get(loc, "expansionLoc")
    ok(expansion) -> return place_in(expansion)
    error(_) -> return place_in(loc)
  end
end

def place_in(loc: Json) -> Place
  return Place(file: text(loc, "cc_file"), line: number(loc, "cc_line"), column: number(loc, "col"))
end

def referenced_kind(node: Json) -> String
  return text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "kind")
end

def referenced_name(node: Json) -> String
  return text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "name")
end

def kind(node: Json) -> String
  return text(node, "kind")
end

# The nodes under a node. clang 19 writes the items of an array initializer with a filler (designated items, or fewer
# items than the array holds) under `array_filler` instead of `inner`, as one list: the filler first, then the items.
def children(node: Json) -> List[Json]
  return list_at(node, "inner").concat(list_at(node, "array_filler"))
end

def list_at(node: Json, key: String) -> List[Json]
  empty: List[Json] = []
  case JSON.get(node, key)
    ok(nodes) -> return JSON.list(nodes).unwrap_or(empty)
    error(_) -> return empty
  end
end

# A missing key or another kind of value reads as "" or 0: the dump of a node leaves out what it does not have.
def text(node: Json, key: String) -> String
  case JSON.get(node, key)
    ok(value) -> return JSON.string(value).unwrap_or("")
    error(_) -> return ""
  end
end

def flag?(node: Json, key: String) -> Bool
  case JSON.get(node, key)
    ok(value) -> return JSON.bool(value).unwrap_or(false)
    error(_) -> return false
  end
end

def number(node: Json, key: String) -> Int
  case JSON.get(node, key)
    ok(value) -> return JSON.int(value).unwrap_or(0)
    error(_) -> return 0
  end
end
