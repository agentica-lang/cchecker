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

## Returns the nodes inside a node.
export def children(node: Json) -> List[Json]
  empty: List[Json] = []
  case JSON.get(node, "inner")
    ok(inner) -> return JSON.list(inner).unwrap_or(empty)
    error(_) -> return empty
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
export def referenced_kind(node: Json) -> String
  return text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "kind")
end

## Returns the name of the declaration that a reference names, or "".
export def referenced_name(node: Json) -> String
  return text(JSON.get(node, "referencedDecl").unwrap_or(JSON.from("")), "name")
end

## Returns the place of a declaration: where its macro was expanded, when it comes from one.
export def place_of(node: Json) -> Place
  return expanded(JSON.get(node, "loc").unwrap_or(JSON.from("")))
end

## Returns where a statement or an expression starts in the code as written (where a macro was expanded).
export def start_of(node: Json) -> Place
  return expanded(JSON.get(JSON.get(node, "range").unwrap_or(JSON.from("")), "begin").unwrap_or(JSON.from("")))
end

## Returns where a statement or an expression ends in the code as written.
export def end_of(node: Json) -> Place
  return expanded(JSON.get(JSON.get(node, "range").unwrap_or(JSON.from("")), "end").unwrap_or(JSON.from("")))
end

def expanded(loc: Json) -> Place
  case JSON.get(loc, "expansionLoc")
    ok(expansion) -> return place_in(expansion)
    error(_) -> return place_in(loc)
  end
end

def place_in(loc: Json) -> Place
  return Place(file: text(loc, "cc_file"), line: number(loc, "cc_line"), column: number(loc, "col"))
end
