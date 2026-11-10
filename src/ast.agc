## Reading the nodes of clang's JSON AST. A missing key reads as "", 0, false or no children: the dump leaves out what
## a node does not have, and an empty node (`{}`, a part of a `for` that is not there) has the kind "".

# How clang starts a group of attributes in a type.
ATTRIBUTE = " __attribute__(("

## A place in a file: the file is absolute (`cc_file` of the scan).
export struct Place
  file: String
  line: Int
  column: Int
end

## Returns the kind of a node (`IfStmt`), or "" for an empty one.
export def kind(node: Json) -> String = text(node, "kind")

## Returns the nodes inside a node. clang 19 writes the items of an array initializer with a filler (designated items,
## or fewer items than the array holds) under `array_filler` instead of `inner`, as one list: the filler first, then
## the items.
export def children(node: Json) -> List[Json]
  # Most nodes have no filler: their `inner` is given as it is, with no new list.
  inner = list_at(node, "inner")
  case JSON.get(node, "array_filler")
    ok(filler) -> inner.concat(JSON.list(filler).unwrap_or([]))
    error(_) -> inner
  end
end

## Returns the items of an initializer list, in order, without the filler that `children` gives first for an array.
export def items(node: Json) -> List[Json] = list_at(node, "inner").concat(list_at(node, "array_filler").drop(1))

## Returns a string of a node, or "".
export def text(node: Json, key: String) -> String
  case JSON.get(node, key)
    ok(value) -> JSON.string(value).unwrap_or("")
    error(_) -> ""
  end
end

## Returns a number of a node, or 0.
export def number(node: Json, key: String) -> Int
  case JSON.get(node, key)
    ok(value) -> JSON.int(value).unwrap_or(0)
    error(_) -> 0
  end
end

## Returns a flag of a node, or false.
export def flag?(node: Json, key: String) -> Bool
  case JSON.get(node, key)
    ok(value) -> JSON.bool(value).unwrap_or(false)
    error(_) -> false
  end
end

## Returns how many nodes the tree of `node` has, counting no further than `limit` + 1.
export def size_of(node: Json, limit: Int) -> Int = counted(node, limit + 1)

## Returns the kind of the declaration that a reference names (`FunctionDecl`, `ParmVarDecl`), or "".
export def referenced_kind(node: Json) -> String
  text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "kind")
end

## Returns the name of the declaration that a reference names, or "".
export def referenced_name(node: Json) -> String
  text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "name")
end

## Returns the id of the declaration that a reference names, or "".
export def referenced_id(node: Json) -> String = text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "id")

## Returns the place of a declaration: where its macro was expanded, when it comes from one.
export def place_of(node: Json) -> Place
  case JSON.get(node, "cc_loc")
    ok(short) -> short_place(short)
    error(_) -> expanded(JSON.get(node, "loc").unwrap_or(JSON.from("")))
  end
end

## Returns where a statement or an expression starts in the code as written (where a macro was expanded).
export def start_of(node: Json) -> Place
  case JSON.get(node, "cc_begin")
    ok(short) -> short_place(short)
    error(_) -> expanded(JSON.get(JSON.get(node, "range").unwrap_or(JSON.from("")), "begin").unwrap_or(JSON.from("")))
  end
end

## Returns where a statement or an expression ends in the code as written.
export def end_of(node: Json) -> Place
  case JSON.get(node, "cc_end")
    ok(short) -> short_place(short)
    error(_) -> expanded(JSON.get(JSON.get(node, "range").unwrap_or(JSON.from("")), "end").unwrap_or(JSON.from("")))
  end
end

## Returns whether the type of a node (a function, or a pointer to one) says that it never returns, as clang writes it
## or without its typedefs, so a `noreturn` behind a typedef shows. clang writes the attribute at the end of the type
## it belongs to, so one inside (a parameter that points to a function that does not return) does not count.
export def noreturn_type?(node: Json) -> Bool
  type = JSON.get(node, "type").unwrap_or(JSON.from(""))
  noreturn_attribute?(text(type, "qualType")) or noreturn_attribute?(text(type, "desugaredQualType"))
end

def expanded(loc: Json) -> Place
  case JSON.get(loc, "expansionLoc")
    ok(expansion) -> place_in(expansion)
    error(_) -> place_in(loc)
  end
end

# A place as the scan writes it in short (`cc_loc`, `cc_begin`, `cc_end`): `[FILE, LINE, COL]`, expanded already.
def short_place(short: Json) -> Place
  parts: List[Json] = JSON.list(short).unwrap_or([])
  return Place(file: "", line: 0, column: 0) if parts.size != 3

  Place(
    file: JSON.string(parts[0]).unwrap_or(""),
    line: JSON.int(parts[1]).unwrap_or(0),
    column: JSON.int(parts[2]).unwrap_or(0),
  )
end

def place_in(loc: Json) -> Place
  Place(file: text(loc, "cc_file"), line: number(loc, "cc_line"), column: number(loc, "col"))
end

def list_at(node: Json, key: String) -> List[Json]
  empty: List[Json] = []
  case JSON.get(node, key)
    ok(nodes) -> JSON.list(nodes).unwrap_or(empty)
    error(_) -> empty
  end
end

# The nodes of a tree, depth first, counting no further than `budget` (at least 1). The nodes still to visit are on a
# stack of their own, not the call stack, so a deep tree cannot pass the VM's call depth; each node is pushed once, so
# the count is linear in the nodes it reaches. `stack[0...depth]` holds them, and the slots past `depth` are reused.
def counted(node: Json, budget: Int) -> Int
  stack = [node]
  depth = 1
  n = 0
  while depth > 0 and n < budget
    depth -= 1
    current = stack[depth]
    n += 1
    for child in children(current)
      if depth < stack.size
        stack = stack.set(depth, child)
      else
        stack = stack.push(child)
      end

      depth += 1
    end
  end

  n
end

# Whether a type ends with `__attribute__((noreturn))`, maybe followed by other groups of attributes: clang writes
# `noreturn` first and a calling convention after it (`__attribute__((noreturn)) __attribute__((regparm (1)))`). A
# group is one only when its parentheses close at the end of the type, which a parameter list does not.
def noreturn_attribute?(type: String) -> Bool
  groups = type.split(ATTRIBUTE)
  i = groups.size - 1
  while i > 0
    group = groups[i]
    return true if group == "noreturn))"

    return false if not group.end_with?("))") or group.split("(").size + 2 != group.split(")").size

    i -= 1
  end

  false
end
