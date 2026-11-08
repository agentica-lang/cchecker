## The collector rule: a value that the collector manages is never stored in memory from `malloc` or in a variable of
## static storage, where the collector does not look for the pointers to what it manages and may free it.
##
## A value of the collector is one of a type marked CC_GC (a struct, a union or a typedef), a pointer to one, a struct
## that holds one, the result of a function marked CC_GC_ALLOC or of an allocator of the Boehm collector, or a local
## that got one of those. Memory from `malloc` is what a pointer points to when it got the value of `malloc`,
## `calloc`, `realloc`, `strdup` or a CC_OWNS function, or is marked CC_OWNS (a local, a parameter, a field or a
## global). The rule reads each store (`a[i] = v`, `p->f = v`, `*p = v`, `x = v`) of a function on its own, whatever
## the path, and each declaration of a variable of static storage of a collector type. A finding that only the
## allocators of the Boehm collector make has `source` `libgc_alloc`, the `[library]` flag that turns them off.

import Ast from "ast"
import {Finding} from "findings"
import Flow from "flow"
import {Context} from "flow"
import Known from "known"
import ToolKind from "tool_kind"
import {Tool} from "tool_kind"

## The code of a value of the collector stored in memory from malloc.
export IN_MALLOC = "CC-OWN-GC-IN-MALLOC"

## The code of a value of the collector stored in, or declared as, a variable of static storage.
export IN_STATIC = "CC-OWN-GC-IN-STATIC"

# The words of a type that do not change what it is.
QUALIFIERS = ["const ", "volatile ", "struct ", "union ", "restrict", "_Atomic "]

## What the rule knows of a translation unit: the names of the types that the collector manages (CC_GC on a struct,
## a union or a typedef), the records that hold one of their values (by name), the keys of the functions marked
## CC_GC_ALLOC, and the ids of the variables of static storage declared at the top of the file.
export struct Marks
  types: Set[String]
  holders: Set[String]
  allocators: Set[String]
  statics: Set[String]
end

# What the check of one function knows: the marks of the unit and its context, the library allocators of the
# collector it counts, the ids of its static locals, its locals that point to memory from malloc (`heap`) and those
# that hold a value of the collector (`collected`).
struct Scope
  marks: Marks
  ctx: Context
  library: Set[String]
  statics: Set[String]
  heap: Set[String]
  collected: Set[String]
end

## Returns whether a type (as clang writes it) is that of a value of the collector: a type marked CC_GC or a pointer to
## one, or a record that holds one, or an array of those. A pointer to a pointer is not, and neither is a function or a
## pointer to one: what is left of its text once the stars go (`value_t ()(int)`) names no type.
export def collector_type?(marks: Marks, type: String) -> Bool
  name = type
  case name.index_of("[")
    some(at) -> name = name.slice(0, at)
    none -> name = name
  end

  name = Flow.unqualified(name)
  for word in QUALIFIERS
    name = name.replace(word, "")
  end

  stars = name.length - name.replace("*", "").length
  base = name.replace("*", "").strip
  if base == ""
    return false
  end

  return (stars <= 1 and marks.types.include?(base)) or (stars == 0 and marks.holders.include?(base))
end

## Returns the findings of the rule in a function definition, at the function: `key` and `name` are the function's, at
## `place`, and `params` the names of the parameters that own what the caller passes.
export def stores(
  marks: Marks,
  ctx: Context,
  name: String,
  place: Ast.Place,
  params: List[String],
  node: Json,
) -> List[Finding]
  bodies = Ast.children(node).select do |child| Ast.kind(child) == "CompoundStmt" end
  all = Flow.descendants(bodies)
  decls = all.select do |n| Ast.kind(n) == "VarDecl" end
  static_locals = decls.select do |n| Ast.text(n, "storageClass") == "static" end
  locals = Set.new(
    Ast.children(node)
      .select do |n| Ast.kind(n) == "ParmVarDecl" end
      .concat(decls.select do |n| Ast.text(n, "storageClass") != "static" end)
      .map do |n| Ast.text(n, "name") end,
  )

  written = Flow.writes_of(all, locals)
  marked = decls.select(&Flow.marked_owner?).map do |n| Ast.text(n, "name") end
  start = Scope(
    marks: marks,
    ctx: ctx,
    library: Set.new([]),
    statics: marks.statics.union(Set.new(static_locals.map do |n| Ast.text(n, "id") end)),
    heap: Set.new(params.concat(marked)),
    collected: Set.new([]),
  )

  # The marks alone, and the marks with the Boehm allocators: a store that only the second sees is theirs.
  marked_only = grown(start, written)
  scope = grown(start.with(library: Known.LIBGC_ALLOC), written)
  found: Map[String, Finding] = {}
  for decl in static_locals
    if declared_collector?(marks, decl)
      local = Ast.text(decl, "name")
      message = "#{name} stores a value of the collector in a static: #{local}"
      found = found.put("#{IN_STATIC} #{local}", at(place, IN_STATIC, message, []))
    end
  end

  for n in all
    parts = Ast.children(n)
    if (
      Ast.kind(n) == "BinaryOperator" and
      Ast.text(n, "opcode") == "=" and
      parts.size == 2 and
      collected?(scope, parts[1])
    )
      target = shown(parts[0])
      where = Ast.start_of(n)
      step = "#{where.line}:#{where.column} stores #{value_word(parts[1])} in #{target}"
      code = ""
      message = ""
      case storage(scope, parts[0])
        "static" ->
          code = IN_STATIC
          message = "#{name} stores a value of the collector in a static: #{target}"
        "heap" ->
          code = IN_MALLOC
          message = "#{name} stores a value of the collector in memory from malloc: #{target}"
        _ -> code = ""
      end

      # A store that the marks make wins over one of the same target that only the Boehm allocators make.
      source = ""
      if not collected?(marked_only, parts[1])
        source = Known.LIBGC_ALLOC_FLAG
      end

      key = "#{code} #{target}"
      if code != "" and (not found.key?(key) or (source == "" and found.get(key).unwrap!.source != ""))
        found = found.put(key, at(place, code, message, [step]).with(source: source))
      end
    end
  end

  return found.values
end

## Returns the findings of the variables of static storage declared at the top of the file with a collector type, at
## each variable. An `extern` declaration is not one: the definition is.
export def statics(marks: Marks, nodes: List[Json]) -> List[Finding]
  found: List[Finding] = []
  for node in nodes
    if Ast.kind(node) == "VarDecl" and Ast.text(node, "storageClass") != "extern"
      if declared_collector?(marks, node)
        name = Ast.text(node, "name")
        message = "#{name} is a static that holds a value of the collector"
        found = found.push(at(Ast.place_of(node), IN_STATIC, message, []))
      end
    end
  end

  return found
end

# Whether a variable is declared with a collector type, as written or behind a typedef (`obj_ref`), and may change.
def declared_collector?(marks: Marks, decl: Json) -> Bool
  type = type_of(decl)
  return (collector_type?(marks, type) or collector_type?(marks, desugared_type_of(decl))) and not constant?(type)
end

# The scope with the locals that point to memory from malloc and those that hold a value of the collector, through
# the values they get, until no more are found.
def grown(start: Scope, written: List[Flow.Written]) -> Scope
  scope = start
  grew = true
  while grew
    grew = false
    for w in written
      if not scope.heap.include?(w.name) and heap?(scope, w.value)
        scope = scope.with(heap: scope.heap.add(w.name))
        grew = true
      end

      if not scope.collected.include?(w.name) and collected?(scope, w.value)
        scope = scope.with(collected: scope.collected.add(w.name))
        grew = true
      end
    end
  end

  return scope
end

# Whether an expression is a value of the collector: by its type or the type of a cast in it, a call of an allocator
# of the collector, a local that got one, or either side of `?:`.
def collected?(scope: Scope, node: Json) -> Bool
  # A null pointer is no value: clang gives the cast of `NULL` or `0` the type of the target.
  if Flow.zero?(node)
    return false
  end

  bare = node
  while true
    if Ast.text(bare, "castKind") == "NullToPointer"
      return false
    end

    if collector_type?(scope.marks, type_of(bare)) or collector_type?(scope.marks, desugared_type_of(bare))
      return true
    end

    if not Flow.SEE_THROUGH.include?(Ast.kind(bare)) or Ast.children(bare).empty?
      break
    end

    bare = Ast.children(bare).first
  end

  case Ast.kind(bare)
    "CallExpr" ->
      called = Flow.callee_name(bare)
      return scope.library.include?(called) or scope.marks.allocators.include?(Flow.key_of_function(scope.ctx, called))
    "DeclRefExpr" -> return scope.collected.include?(Flow.variable_name(bare))
    "ConditionalOperator" -> return Ast.children(bare).drop(1).any? do |branch| collected?(scope, branch) end
    _ -> return false
  end
end

# Whether a pointer points to memory from malloc: a local that got it or is marked CC_OWNS, a CC_OWNS field or global,
# a call of an allocator, or an offset from one of those.
def heap?(scope: Scope, node: Json) -> Bool
  bare = Flow.see_through(node)
  parts = Ast.children(bare)
  case Ast.kind(bare)
    "DeclRefExpr" ->
      return (
        scope.heap.include?(Flow.variable_name(bare)) or
        scope.ctx.owning.globals.include?(Ast.referenced_id(bare))
      )
    "MemberExpr" -> return scope.ctx.owning.fields.include?(Ast.text(bare, "referencedMemberDecl"))
    "CallExpr" -> return Known.OWNED.include?(Flow.callee_name(bare)) or Flow.owning_call?(scope.ctx, bare)
    "BinaryOperator" ->
      opcode = Ast.text(bare, "opcode")
      return (opcode == "+" or opcode == "-") and parts.any? do |part| heap?(scope, part) end
    _ -> return false
  end
end

# Where a store goes: "static" (a variable of static storage, or a field or an item of one), "heap" (memory that a
# pointer from malloc points to), or "" (anything else: the stack, memory of the collector, memory the rule cannot
# tell).
def storage(scope: Scope, node: Json) -> String
  bare = Flow.see_through(node)
  parts = Ast.children(bare)
  case Ast.kind(bare)
    "DeclRefExpr" ->
      if scope.statics.include?(Ast.text(JSON.get(bare, "referencedDecl").unwrap_or(JSON.from("")), "id"))
        return "static"
      end

      return ""
    "MemberExpr" ->
      if Ast.flag?(bare, "isArrow")
        return pointee(scope, parts.first)
      end

      return storage(scope, parts.first)
    "ArraySubscriptExpr" ->
      base = Flow.see_through(parts.first)
      if type_of(base).include?("[")
        return storage(scope, base)
      end

      return pointee(scope, parts.first)
    "UnaryOperator" ->
      if Ast.text(bare, "opcode") == "*"
        return pointee(scope, parts.first)
      end

      return ""
    _ -> return ""
  end
end

def pointee(scope: Scope, pointer: Json) -> String
  if heap?(scope, pointer)
    return "heap"
  end

  return ""
end

# How a step names the value stored: the function called, or the expression.
def value_word(node: Json) -> String
  bare = Flow.see_through(node)
  if Ast.kind(bare) == "CallExpr" and Flow.callee_name(bare) != ""
    return Flow.callee_name(bare)
  end

  return shown(node)
end

# The text of the target of a store, from its names, fields, items and `*`; `?` for a part it cannot write.
def shown(node: Json) -> String
  bare = Flow.see_through(node)
  parts = Ast.children(bare)
  case Ast.kind(bare)
    "DeclRefExpr" -> return Ast.referenced_name(bare)
    "MemberExpr" ->
      if Ast.flag?(bare, "isArrow")
        return "#{shown(parts.first)}->#{Ast.text(bare, "name")}"
      end

      return "#{shown(parts.first)}.#{Ast.text(bare, "name")}"
    "ArraySubscriptExpr" -> return "#{shown(parts[0])}[#{shown(parts[1])}]"
    "UnaryOperator" ->
      if Ast.flag?(bare, "isPostfix")
        return "#{shown(parts.first)}#{Ast.text(bare, "opcode")}"
      end

      return "#{Ast.text(bare, "opcode")}#{shown(parts.first)}"
    "IntegerLiteral" -> return Ast.text(bare, "value")
    _ -> return "?"
  end
end

# Whether a variable of the type is constant itself: `const value`, `const value [4]`, `value *const`, not `const
# value *` (a pointer that may change). Its initializer is all it ever holds, and that is no allocation.
def constant?(type: String) -> Bool
  name = type
  case name.index_of("[")
    some(at) -> name = name.slice(0, at)
    none -> name = name
  end

  stars = name.split("*")
  return stars.last.include?("const")
end

def type_of(node: Json) -> String
  return Ast.text(JSON.get(node, "type").unwrap_or(JSON.from("")), "qualType")
end

def desugared_type_of(node: Json) -> String
  return Ast.text(JSON.get(node, "type").unwrap_or(JSON.from("")), "desugaredQualType")
end

def at(place: Ast.Place, code: String, message: String, path: List[String]) -> Finding
  return Finding(
    code: code,
    tool: ToolKind.name(Tool.Rules),
    file: place.file,
    line: place.line,
    column: place.column,
    message: message,
    path: path,
  )
end
