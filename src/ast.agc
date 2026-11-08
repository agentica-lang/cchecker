## Reading the nodes of clang's JSON AST. A missing key reads as "", 0, false or no children: the dump leaves out what
## a node does not have, and an empty node (`{}`, a part of a `for` that is not there) has the kind "".

## A place in a file: the file is absolute (`cc_file` of the scan).
export struct Place
  file: String
  line: Int
  column: Int
end

## Returns the kind of a node (`IfStmt`), or "" for an empty one.
export def kind(node: Json) -> String
  return text(node, "kind")
end

## Returns the nodes inside a node. clang 19 writes the items of an array initializer with a filler (designated items,
## or fewer items than the array holds) under `array_filler` instead of `inner`, as one list: the filler first, then
## the items.
export def children(node: Json) -> List[Json]
  # Most nodes have no filler: their `inner` is given as it is, with no new list.
  inner = list_at(node, "inner")
  case JSON.get(node, "array_filler")
    ok(filler) -> return inner.concat(JSON.list(filler).unwrap_or([]))
    error(_) -> return inner
  end
end

## Returns a string of a node, or "".
export def text(node: Json, key: String) -> String
  case JSON.get(node, key)
    ok(value) -> return JSON.string(value).unwrap_or("")
    error(_) -> return ""
  end
end

## Returns a number of a node, or 0.
export def number(node: Json, key: String) -> Int
  case JSON.get(node, key)
    ok(value) -> return JSON.int(value).unwrap_or(0)
    error(_) -> return 0
  end
end

## Returns a flag of a node, or false.
export def flag?(node: Json, key: String) -> Bool
  case JSON.get(node, key)
    ok(value) -> return JSON.bool(value).unwrap_or(false)
    error(_) -> return false
  end
end

## Returns the kind of the declaration that a reference names (`FunctionDecl`, `ParmVarDecl`), or "".
## Returns how many nodes the tree of `node` has, counting no further than `limit` + 1.
export def size_of(node: Json, limit: Int) -> Int
  queue = [node]
  i = 0
  while i < queue.size and i <= limit
    queue = queue.concat(children(queue[i]))
    i += 1
  end

  return i
end

export def referenced_kind(node: Json) -> String
  return text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "kind")
end

## Returns the name of the declaration that a reference names, or "".
export def referenced_name(node: Json) -> String
  return text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "name")
end

## Returns the id of the declaration that a reference names, or "".
export def referenced_id(node: Json) -> String
  return text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "id")
end

## Returns the place of a declaration: where its macro was expanded, when it comes from one.
export def place_of(node: Json) -> Place
  case JSON.get(node, "cc_loc")
    ok(short) -> return short_place(short)
    error(_) -> return expanded(JSON.get(node, "loc").unwrap_or(JSON.from("")))
  end
end

## Returns where a statement or an expression starts in the code as written (where a macro was expanded).
export def start_of(node: Json) -> Place
  case JSON.get(node, "cc_begin")
    ok(short) -> return short_place(short)
    error(_) ->
      return expanded(JSON.get(JSON.get(node, "range").unwrap_or(JSON.from("")), "begin").unwrap_or(JSON.from("")))
  end
end

## Returns where a statement or an expression ends in the code as written.
export def end_of(node: Json) -> Place
  case JSON.get(node, "cc_end")
    ok(short) -> return short_place(short)
    error(_) ->
      return expanded(JSON.get(JSON.get(node, "range").unwrap_or(JSON.from("")), "end").unwrap_or(JSON.from("")))
  end
end

def expanded(loc: Json) -> Place
  case JSON.get(loc, "expansionLoc")
    ok(expansion) -> return place_in(expansion)
    error(_) -> return place_in(loc)
  end
end

# A place as the scan writes it in short (`cc_loc`, `cc_begin`, `cc_end`): `[FILE, LINE, COL]`, expanded already.
def short_place(short: Json) -> Place
  parts: List[Json] = JSON.list(short).unwrap_or([])
  if parts.size != 3
    return Place(file: "", line: 0, column: 0)
  end

  return Place(
    file: JSON.string(parts[0]).unwrap_or(""),
    line: JSON.int(parts[1]).unwrap_or(0),
    column: JSON.int(parts[2]).unwrap_or(0),
  )
end

def place_in(loc: Json) -> Place
  return Place(file: text(loc, "cc_file"), line: number(loc, "cc_line"), column: number(loc, "col"))
end

def list_at(node: Json, key: String) -> List[Json]
  empty: List[Json] = []
  case JSON.get(node, key)
    ok(nodes) -> return JSON.list(nodes).unwrap_or(empty)
    error(_) -> return empty
  end
end
