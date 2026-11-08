## Cutting the declarations of the project out of clang's JSON AST, line by line.
##
## The AST of one C file is tens of MiB, nearly all of it from the system headers, and `JSON.parse` of all of it would
## hold it all in memory. A declaration is kept when the place it is written (where a macro was expanded, for one that
## a macro made) is under the project; a table of numbers is not: an array whose type is plain numbers or characters,
## or whose first item is a number, even of a typedef that clang does not desugar (`const uint8_t[30000]`).
## clang writes the dump with a fixed indent, one key per line, so a top-level declaration is the lines from `    {` to
## `    }`. clang also leaves the file and the line out of a location when they are those of the location written
## before it, so a declaration alone does not say where it is: the scan follows every location in order, and writes
## the file and the line into each location it keeps, as `cc_file` (absolute) and `cc_line`.

import Paths from "paths"

# The longest line the scan reads. A line of the dump is short, except a string literal of the source, which is one.
LINE_BYTES = 16_777_216

# The most lines the scan keeps of one declaration, so that a generated table cannot take all the memory. The largest
# function of the Agentica VM has 190 thousand. A declaration over it is an error when it names a function, before the
# cap or past it, since its calls are lost; one that names none (a table of enum values or of structs of numbers) is
# skipped and counted. Past the cap the scan keeps no line and reads on only for a function.
MAX_DECL_LINES = 1_000_000

DECL_START = "    {"
DECL_ENDS = Set.new(["    }", "    },"])
DUMP_END = "}"

# The keys of a top-level declaration, at its indent, and of its type, one level deeper.
VAR_KIND = "      \"kind\": \"VarDecl\","
NAME_KEY = "      \"name\": "
DESUGARED_KEY = "        \"desugaredQualType\": "
TYPE_KEY = "        \"qualType\": "

# The kind of the initializer of a top-level variable, and the kinds of an item in it: a cast or a zero fill is looked
# through, and a literal number tells a table of numbers, unless a cast made it a pointer: a null pointer
# (`{0, f}`), or an integer under `-Wno-int-conversion` (`{1, f}`).
INIT_LIST = "          \"kind\": \"InitListExpr\","
KIND_KEY = "\"kind\": "
SEEN_THROUGH = Set.new(["\"ImplicitCastExpr\"", "\"ImplicitValueInitExpr\""])
LITERALS = Set.new(["\"IntegerLiteral\"", "\"FloatingLiteral\"", "\"CharacterLiteral\""])
CAST_KEY = "\"castKind\": "
# The cast kinds whose result is a pointer from a number: `NullToPointer` and `IntegralToPointer`.
TO_POINTER = "ToPointer\""

# A function that a declaration names, at any depth: a `referencedDecl`, or the declaration itself.
FUNCTION_KIND = "\"kind\": \"FunctionDecl\","

# The words of a type of numbers and characters, which no function pointer is in. `void` is not one: a `void *` can
# hold a function through a cast.
PLAIN_WORDS = Set.new([
  "char", "short", "int", "long", "unsigned", "signed", "float", "double", "_Bool", "bool", "__int128", "const",
  "volatile", "static",
])

# Where the scan is: between two top-level declarations, in one whose place it does not know yet, in one it keeps or
# drops, or in one too large to keep that has named no function so far.
enum Phase
  Between
  Open
  Kept
  Dropped
  Oversized
end

## The state of a scan. `directory` is where clang ran (its paths are relative to it) and `cwd` the root of the
## project: a declaration is kept when its first location is under it.
export struct State
  directory: String
  cwd: String
  encoded: String = "\"\""
  line: Int = 0
  inside: Bool = false
  included: Bool = false
  phase: Phase = Phase.Between
  spelling: Bool = false
  variable: Bool = false
  array: Bool = false
  items: Bool = false
  functions: Bool = false
  desugared: String = ""
  name: String = ""
  lines: List[String] = []
  decls: List[String] = []
  oversized: List[String] = []
  skipped: Int = 0
  ended: Bool = false
end

## The declarations of the project in a dump, as the text of a JSON array, the names of those too large to keep whose
## calls are lost, and the count of those too large to keep that name no function.
export struct Dump
  decls: String
  oversized: List[String]
  skipped: Int
end

## Returns the declarations of the project in the dump at `path`, or an error when the dump ends early.
export def project_decls(path: String, directory: String, cwd: String) -> Result[Dump]
  state = try File.foreach(path, LINE_BYTES).reduce(start(directory, cwd), &step)
  if not state.ended
    return error("the AST dump ends early")
  end

  return ok(Dump(decls: finish(state), oversized: state.oversized, skipped: state.skipped))
end

## Returns the state before the first line.
export def start(directory: String, cwd: String) -> State
  return State(directory: directory, cwd: cwd)
end

## Returns the state after one line of the dump.
export def step(state: State, line: String) -> State
  if line == DECL_START
    return state.with(
      phase: Phase.Open,
      lines: [line],
      variable: false,
      array: false,
      items: false,
      functions: false,
      desugared: "",
      name: "",
    )
  end

  if DECL_ENDS.include?(line) and state.phase != Phase.Between
    return close(state)
  end

  if state.phase == Phase.Between
    return state.with(ended: line == DUMP_END)
  end

  if state.phase == Phase.Kept and state.lines.size >= MAX_DECL_LINES
    return oversized(state)
  end

  if state.phase == Phase.Oversized
    return past_the_cap(state, line)
  end

  current = state
  if line.start_with?("      \"") or line.start_with?("        \"")
    current = top_key(state, line)
  else
    current = deeper_key(state, line)
  end

  if current.phase == Phase.Dropped
    return current
  end

  return located_or_kept(current, line)
end

## Returns the kept declarations as the text of a JSON array.
export def finish(state: State) -> String
  return "[#{state.decls.join(",\n")}]"
end

## Whether a type, as clang writes it (`"const unsigned char[300]"`), is an array of numbers or characters. A scalar or
## a pointer, `void *` among them, can hold a function through a cast, and a typedef is not known here.
export def plain_array?(type: String) -> Bool
  if not type.include?("[") or type.include?("(") or type.include?("*")
    return false
  end

  words = type.replace("\"", " ").replace("[", " [").split(" ")
  return words.select do |word| word != "" and not word.start_with?("[") end
    .all? do |word| PLAIN_WORDS.include?(word) end
end

# The lines of a location move the file and the line; every other line is kept or dropped with its declaration.
def located_or_kept(state: State, line: String) -> State
  text = line.strip
  # The file of `includedFrom` is the file that included this one: the location is still in this one.
  if state.included
    return keep(state.with(included: false), line)
  end

  if text.start_with?("\"includedFrom\": {")
    return keep(state.with(included: true), line)
  end

  if text.start_with?("\"spellingLoc\": {")
    return keep(state.with(spelling: true), line)
  end

  if text.start_with?("\"expansionLoc\": {")
    return keep(state.with(spelling: false), line)
  end

  if text.start_with?("\"file\": ")
    return keep(with_file(state, value_of(text, "\"file\": ")), line)
  end

  if text.start_with?("\"line\": ")
    return keep(state.with(line: value_of(text, "\"line\": ").to_i.unwrap_or(state.line)), line)
  end

  if text.start_with?("\"col\": ")
    return located(state, line, text)
  end

  return keep(state, line)
end

# A declaration too large to keep: an error when it named a function, as its calls are lost. One that has named none so
# far is read on without its lines, since it may name one past the cap.
def oversized(state: State) -> State
  if state.functions
    return state.with(phase: Phase.Dropped, lines: [], oversized: state.oversized.push(state.name))
  end

  return state.with(phase: Phase.Oversized, lines: [])
end

# A line past the cap of a declaration that has named no function so far: a function makes it an error.
def past_the_cap(state: State, line: String) -> State
  if line.end_with?(FUNCTION_KIND)
    return state.with(phase: Phase.Dropped, oversized: state.oversized.push(state.name))
  end

  return state
end

# The keys of the declaration itself and of its type: whether it is a variable, its name, and, at its type, whether a
# variable of that type can hold a function pointer.
def top_key(state: State, line: String) -> State
  if line == VAR_KIND
    return state.with(variable: true)
  end

  if line.end_with?(FUNCTION_KIND)
    return state.with(functions: true)
  end

  if line.start_with?(NAME_KEY)
    name = value_of(line.strip, "\"name\": ")
    return state.with(name: JSON.string(JSON.parse(name).unwrap_or(JSON.from(name))).unwrap_or(name))
  end

  if line.start_with?(DESUGARED_KEY)
    return state.with(desugared: value_of(line, DESUGARED_KEY))
  end

  if line.start_with?(TYPE_KEY) and state.variable and state.phase == Phase.Kept
    type = state.desugared
    if type == ""
      type = value_of(line, TYPE_KEY)
    end

    if plain_array?(type)
      return state.with(phase: Phase.Dropped, lines: [])
    end

    return state.with(array: type.include?("["))
  end

  return state
end

# The lines below the keys of the declaration: whether it names a function, and, for an array whose type does not tell
# (a typedef), whether its first item is a number. A number cast to a pointer (`0`, or `1` under `-Wno-int-conversion`)
# is not one: the array holds pointers.
def deeper_key(state: State, line: String) -> State
  if state.phase != Phase.Kept
    return state
  end

  if not state.functions and line.end_with?(FUNCTION_KIND)
    return state.with(functions: true, array: false)
  end

  if not state.array
    return state
  end

  if line == INIT_LIST
    return state.with(items: true)
  end

  if not state.items
    return state
  end

  text = line.strip
  if text.start_with?(CAST_KEY) and value_of(text, CAST_KEY).end_with?(TO_POINTER)
    return state.with(array: false)
  end

  if not text.start_with?(KIND_KEY)
    return state
  end

  kind = value_of(text, KIND_KEY)
  if SEEN_THROUGH.include?(kind)
    return state
  end

  if LITERALS.include?(kind)
    return state.with(phase: Phase.Dropped, lines: [])
  end

  return state.with(array: false)
end

# The `col` of a location comes after its file and line, so they are known here. The first location of a declaration
# decides whether it is kept; for one that a macro wrote, the place where the macro was expanded decides, not the
# place of its spelling (a header of a library, or clang's scratch space for a pasted name).
def located(state: State, line: String, text: String) -> State
  indent = " " * (line.length - line.strip.length)
  marked = "#{indent}\"cc_file\": #{state.encoded}, \"cc_line\": #{state.line}, #{text}"
  if state.phase == Phase.Open and not state.spelling
    phase = Phase.Dropped
    if state.inside
      phase = Phase.Kept
    end

    return keep(state.with(phase: phase), marked)
  end

  return keep(state, marked)
end

def close(state: State) -> State
  if state.phase == Phase.Kept
    decl = state.lines.push("    }").join("\n")
    return state.with(phase: Phase.Between, lines: [], decls: state.decls.push(decl))
  end

  # It ended without naming a function: it is skipped.
  if state.phase == Phase.Oversized
    return state.with(phase: Phase.Between, skipped: state.skipped + 1)
  end

  return state.with(phase: Phase.Between, lines: [])
end

def keep(state: State, line: String) -> State
  if state.phase == Phase.Open or state.phase == Phase.Kept
    return state.with(lines: state.lines.push(line))
  end

  return state
end

# A file of the dump is relative to where clang ran. `<built-in>` and `<scratch space>` are no files.
def with_file(state: State, value: String) -> State
  name = JSON.string(JSON.parse(value).unwrap_or(JSON.from(""))).unwrap_or("")
  if name == "" or name.start_with?("<")
    return state.with(encoded: JSON.encode(name), inside: false)
  end

  path = Paths.absolute(state.directory, name).unwrap_or(name)
  return state.with(encoded: JSON.encode(path), inside: Paths.inside(state.cwd, path).some?)
end

# The value of a `"key": value,` line, without the comma.
def value_of(text: String, key: String) -> String
  value = text.slice(key.length, text.length - key.length)
  if value.end_with?(",")
    return value.slice(0, value.length - 1)
  end

  return value
end
