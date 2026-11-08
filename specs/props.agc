## The property tests of the features, with the `prop` package: each generates small C files, runs cchecker on them
## and checks a law of the rules. A falsified law gives the shrunk case and the C file it makes.

import Prop from "pkg/prop/prop"

# The longest one run of cchecker on a generated file may take.
RUN_MS = 30_000

## A table that stores the blocking function `slow` among filler items, and the call through it. `shape` is the kind of
## table (an array of function pointers, of structs, of nested structs, or one nested struct), `ref` how `slow` is
## written (`slow`, `&slow`, a cast), `fillers` the other items, `at` where `slow` goes among them and `style` how the
## items are written (in order, all designated in reverse, or `slow` alone designated). Each part shrinks toward 0, the
## plainest form.
export struct Table
  shape: Int
  ref: Int
  fillers: List[Int]
  at: Int
  style: Int
end

## The generator of tables, with up to 6 fillers.
export def tables() -> Prop.Gen[Table]
  kind = Prop.pair(Prop.int(0, 3), Prop.int(0, 3))
  items = Prop.pair(Prop.list(Prop.int(0, 3), 6), Prop.pair(Prop.int(0, 6), Prop.int(0, 2)))
  return Prop.map(Prop.pair(kind, items), &table_of)
end

## Checks `runs` tables: cchecker (the bytecode `program`, run in specs/) finds that the CC_SHORT `entry` reaches
## `sleep` through `slow` in each. `folder` is the folder of the scenario, under specs/, where the C files go.
export def scanner_keeps_paths(program: String, folder: String, runs: Int) -> Result[Void]
  return Prop.check(tables(), Prop.Config(runs: runs)) do |table|
    source = c_file(table)
    path = "#{folder}/case.c"
    case File.write_text("specs/#{path}", source)
      ok(_) -> found_path(program, path, source)
      error(message) -> error(message)
    end
  end
end

def table_of(parts: Prop.Pair[Prop.Pair[Int, Int], Prop.Pair[List[Int], Prop.Pair[Int, Int]]]) -> Table
  return Table(
    shape: parts.first.first,
    ref: parts.first.second,
    fillers: parts.second.first,
    at: parts.second.second.first,
    style: parts.second.second.second,
  )
end

def found_path(program: String, path: String, source: String) -> Result[Void]
  args = ["run", "--", program, "--tools", "rules", "--json", path, "--", "-I../include"]
  process = try Process.spawn_captured("agentica", args, "specs", RUN_MS, {})
  output = try Process.output(process, RUN_MS)
  code = try Process.wait(process, RUN_MS)
  Process.close(process)
  if code == 1 and output.stdout.include?("\"path\":[\"entry\",\"slow\",\"sleep\"]")
    return ok()
  end

  return error("exit code #{code}, no path entry -> slow -> sleep in:\n#{source}\n#{output.stdout}#{output.stderr}")
end

# The C file of a table.
def c_file(table: Table) -> String
  head = [
    "#include \"cchecker.h\"",
    "",
    "unsigned int sleep(unsigned int seconds);",
    "typedef int (*fn)(int);",
    "static int quick(int x) { return x; }",
    "static int slow(int x) { sleep(1); return x; }",
    "struct op { int n; fn run; };",
    "struct box { struct op op; fn alt; };",
  ]

  return head.push(declaration(table)).push("CC_SHORT int entry(int i) { return #{call(table)}; }").join("\n") + "\n"
end

def declaration(table: Table) -> String
  case table.shape
    0 -> return "static fn T[#{size(table)}] = {#{items(table)}};"
    1 -> return "static const struct op T[#{size(table)}] = {#{items(table)}};"
    2 -> return "static struct box T[#{size(table)}] = {#{items(table)}};"
    _ -> return "static struct box T = #{item(table, ref_text(table.ref))};"
  end
end

def call(table: Table) -> String
  case table.shape
    0 -> return "T[i](i)"
    1 -> return "T[i].run(i)"
    2 -> return "T[i].op.run(i)"
    _ -> return "T.op.run(i)"
  end
end

# An array written in order has the size of its items; one with designators has room left, which clang writes as a
# filler.
def size(table: Table) -> String
  if table.style == 0
    return ""
  end

  return "16"
end

def ref_text(ref: Int) -> String
  return ["slow", "&slow", "(fn)slow", "(fn)&slow"][ref]
end

def filler_text(filler: Int) -> String
  return ["0", "quick", "(fn)0", "&quick"][filler]
end

# The items of an array, `slow` at `at` (or last) among the fillers.
def items(table: Table) -> String
  at = table.at
  if at > table.fillers.size
    at = table.fillers.size
  end

  values = table.fillers.map do |filler| item(table, filler_text(filler)) end
  values = values.take(at).push(item(table, ref_text(table.ref))).concat(values.drop(at))
  written: List[String] = []
  i = 0
  for value in values
    if table.style == 1 or (table.style == 2 and i == at)
      written = written.push("[#{i}] = #{value}")
    else
      written = written.push(value)
    end

    i += 1
  end

  if table.style == 1
    return written.reverse.join(", ")
  end

  return written.join(", ")
end

# One item of the table holding the function `value`, written in order or with designated fields.
def item(table: Table, value: String) -> String
  case table.shape
    0 -> return value
    1 -> return op(table.style, value)
    _ ->
      if table.style == 0
        return "{#{op(0, value)}, quick}"
      end

      return "{.alt = quick, .op = #{op(table.style, value)}}"
  end
end

def op(style: Int, value: String) -> String
  case style
    0 -> return "{1, #{value}}"
    1 -> return "{.run = #{value}, .n = 1}"
    _ -> return "{.n = 1, .run = #{value}}"
  end
end
