## Cutting the declarations of the project out of clang's JSON AST, line by line.
##
## The AST of one C file is tens of MiB, nearly all of it from the system headers, and `JSON.parse` of all of it would
## hold it all in memory. clang writes it with a fixed indent, one key per line, so a top-level declaration is the
## lines from `    {` to `    }`. clang also leaves the file and the line out of a location when they are those of the
## location written before it, so a declaration alone does not say where it is: the scan follows every location in
## order, and writes the file and the line into each location it keeps, as `cc_file` (absolute) and `cc_line`.

import Paths from "paths"

# The longest line the scan reads. A line of the dump is short, except a string literal of the source, which is one.
LINE_BYTES = 16_777_216

DECL_START = "    {"
DECL_ENDS = Set.new(["    }", "    },"])

# Where the scan is: between two top-level declarations, in one whose place it does not know yet, or in one it keeps
# or drops.
enum Phase
  Between
  Open
  Kept
  Dropped
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
  lines: List[String] = []
  decls: List[String] = []
end

## Returns the declarations of the project in the dump at `path`, as the text of a JSON array.
export def project_decls(path: String, directory: String, cwd: String) -> Result[String]
  state = try File.foreach(path, LINE_BYTES).reduce(start(directory, cwd), &step)
  return ok(finish(state))
end

## Returns the state before the first line.
export def start(directory: String, cwd: String) -> State
  return State(directory: directory, cwd: cwd)
end

## Returns the state after one line of the dump.
export def step(state: State, line: String) -> State
  if line == DECL_START
    return state.with(phase: Phase.Open, lines: [line])
  end

  if DECL_ENDS.include?(line) and state.phase != Phase.Between
    return close(state)
  end

  if state.phase == Phase.Between
    return state
  end

  text = line.strip
  # The file of `includedFrom` is the file that included this one: the location is still in this one.
  if state.included
    return keep(state.with(included: false), line)
  end

  if text.start_with?("\"includedFrom\": {")
    return keep(state.with(included: true), line)
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

## Returns the kept declarations as the text of a JSON array.
export def finish(state: State) -> String
  return "[#{state.decls.join(",\n")}]"
end

# The `col` of a location comes after its file and line, so they are known here. The first location of a declaration
# decides whether it is kept.
def located(state: State, line: String, text: String) -> State
  indent = " " * (line.length - line.strip.length)
  marked = "#{indent}\"cc_file\": #{state.encoded}, \"cc_line\": #{state.line}, #{text}"
  if state.phase == Phase.Open
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
