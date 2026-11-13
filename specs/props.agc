## The property tests of the features, with the `prop` package: each generates small C files, runs cchecker on them
## and checks a law of the rules. A falsified law gives the shrunk case and the C file it makes.

import Prop from "pkg/prop/prop"

# The most runs of cchecker that shrinking a miss may take: at about 0.25 s a run, a miss found late in a scenario
# still prints its shrunk C file and seed before the 30 s of the scenario.
SHRINKS = 30

## A table that stores a function among filler items, and the call through it. `shape` is the kind of table: an array
## of function pointers, of structs, of nested structs, a struct with an array of function pointers in it, or an array
## of a typedef'd struct. `ref` is how the function is written (by name, `&`, casts through `fn`, an integer or
## `void *`), `deref` whether the call is `(*T[i])(i)`, `fillers` the other items, `at` where the function goes among
## them and `style` how the items are written: in order, all designated in reverse, the function alone designated, or
## the function last with a chained designator (`[k].op.run = f`, `.ops[k] = f`). Each part shrinks toward 0, the
## plainest form.
struct Table
  shape: Int
  ref: Int
  deref: Int
  fillers: List[Int]
  at: Int
  style: Int
end

## What one run of cchecker gave.
struct Output
  code: Int
  stdout: String
  stderr: String
end

## The generator of tables, with up to 6 fillers.
def tables() -> Prop.Gen[Table]
  sizes = Prop.pair(Prop.int(0, 4), Prop.int(0, 5))
  kind = Prop.pair(sizes, Prop.int(0, 1))
  ranges = Prop.pair(Prop.int(0, 6), Prop.int(0, 3))
  fillers = Prop.list(Prop.int(0, 4), 6)
  items = Prop.pair(fillers, ranges)
  pair = Prop.pair(kind, items)
  Prop.map(pair, &table_of)
end

## Checks `runs` tables, from `seed` when it is given: cchecker (the bytecode `program`, run in specs/) reports that
## the CC_SHORT `entry` reaches `sleep` through `slow`, stored in the table, with CC-EFFECT-SHORT-BLOCKS. `folder` is
## the folder of the scenario, under specs/, where the C files go.
def scanner_keeps_paths(program: String, folder: String, runs: Int, seed: Optional[Int]) -> Result[Void]
  Prop.check(tables(), Prop.Config(runs: runs, seed: seed, shrinks: SHRINKS)) do |table|
    source = c_file(table, "slow")
    found(run(program, folder, source), source)
  end
end

## The negative twin of `scanner_keeps_paths`: the table stores `quick`, which does not block, in place of `slow`, and
## cchecker exits 0 with no CC-EFFECT-SHORT-BLOCKS.
def scanner_blames_nothing(program: String, folder: String, runs: Int, seed: Optional[Int]) -> Result[Void]
  Prop.check(tables(), Prop.Config(runs: runs, seed: seed, shrinks: SHRINKS)) do |table|
    source = c_file(table, "quick")
    clean(run(program, folder, source), source)
  end
end

## One run of cchecker (the bytecode `program`) on the C file `source`, written in the folder of the scenario.
def run(program: String, folder: String, source: String) -> Result[Output]
  path = "#{folder}/case.c"
  try File.write_text("specs/#{path}", source)
  run_with(program, ["--tools", "rules", "--json", path, "--", "-I../include"])
end

## One run of cchecker (the bytecode `program`) in specs/ with the options `options`.
def run_with(program: String, options: List[String]) -> Result[Output]
  args = ["run", "--", program].concat(options)
  process = try Process.spawn_captured("agentica", args, Process.Options(timeout_ms: RUN_MS, chdir: "specs"))
  output = try Process.output(process, RUN_MS)
  code = try Process.wait(process, RUN_MS)
  Process.close(process)
  ok(Output(code: code, stdout: output.stdout, stderr: output.stderr))
end

private

# The longest one run of cchecker on a generated file may take.
RUN_MS = 30_000

def table_of(parts: Prop.Pair[Prop.Pair[Prop.Pair[Int, Int], Int], Prop.Pair[List[Int], Prop.Pair[Int, Int]]]) -> Table
  Table(
    shape: parts.first.first.first,
    ref: parts.first.first.second,
    deref: parts.first.second,
    fillers: parts.second.first,
    at: parts.second.second.first,
    style: parts.second.second.second,
  )
end

# The finding of `slow`: its code and its path, in the same finding.
def blamed?(stdout: String) -> Bool
  finding = "{\"code\":\"CC-EFFECT-SHORT-BLOCKS\","
  path = "\"path\":[\"entry\",\"slow\",\"sleep\"]"
  stdout.split(finding).drop(1).any? do |part| part.split("}").first.include?(path) end
end

def found(ran: Result[Output], source: String) -> Result[Void]
  output = try ran
  return ok() if output.code == 1 and blamed?(output.stdout)

  missed("no CC-EFFECT-SHORT-BLOCKS on the path entry -> slow -> sleep", source, output)
end

def clean(ran: Result[Output], source: String) -> Result[Void]
  output = try ran
  return ok() if output.code == 0 and not output.stdout.include?("CC-EFFECT-SHORT-BLOCKS")

  missed("a finding where no function blocks", source, output)
end

def missed(what: String, source: String, output: Output) -> Result[Void]
  error("exit code #{output.code}, #{what}, in:\n#{source}\n#{output.stdout}#{output.stderr}")
end

# The C file of a table that stores `target`.
def c_file(table: Table, target: String) -> String
  head = [
    "#include \"cchecker.h\"",
    "",
    "unsigned int sleep(unsigned int seconds);",
    "typedef int (*fn)(int);",
    "static int quick(int x) { return x; }",
    "static int slow(int x) { sleep(1); return x; }",
    "struct op { int n; fn run; };",
    "struct box { struct op op; fn alt; };",
    "struct bank { int n; fn ops[16]; };",
    "typedef struct op op_t;",
  ]

  call = "CC_SHORT int entry(int i) { return #{call_of(table)}; }"
  head.push(declaration(table, ref_text(table.ref, target))).push(call).join("\n") + "\n"
end

def declaration(table: Table, value: String) -> String
  case table.shape
    0 -> "static fn T[#{size(table)}] = {#{items(table, value)}};"
    1 -> "static const struct op T[#{size(table)}] = {#{items(table, value)}};"
    2 -> "static struct box T[#{size(table)}] = {#{items(table, value)}};"
    3 ->
      if table.style == 3
        fillers = table.fillers.map do |filler| filler_text(filler) end
        return "static struct bank T = {.ops = {#{fillers.join(", ")}}, .ops[#{last(table)}] = #{value}, .n = 1};"
      end

      "static struct bank T = {.n = 1, .ops = {#{items(table, value)}}};"

    _ -> "static op_t T[#{size(table)}] = {#{items(table, value)}};"
  end
end

def call_of(table: Table) -> String
  pointer = ["T[i]", "T[i].run", "T[i].op.run", "T.ops[i]", "T[i].run"][table.shape]
  return "(*#{pointer})(i)" if table.deref == 1

  "#{pointer}(i)"
end

# An array written in order has the size of its items; one with designators has room left, which clang writes as a
# filler.
def size(table: Table) -> String
  return "" if table.style == 0

  "16"
end

# The index of the function in the chained style: after the fillers, so that no item is written twice.
def last(table: Table) -> Int = table.fillers.size + table.at

def ref_text(ref: Int, target: String) -> String
  forms = [
    target,
    "&#{target}",
    "(fn)#{target}",
    "(fn)&#{target}",
    "(fn)(unsigned long)#{target}",
    "(void *)#{target}",
  ]

  forms[ref]
end

def filler_text(filler: Int) -> String = ["0", "quick", "(fn)0", "&quick", "(fn)1"][filler]

# The items of an array, `value` at `at` (or last) among the fillers.
def items(table: Table, value: String) -> String
  if table.style == 3
    fillers = table.fillers.map do |filler| item(table.shape, 0, filler_text(filler)) end
    chain = ["", ".run", ".op.run", "", ".run"][table.shape]
    return fillers.push("[#{last(table)}]#{chain} = #{value}").join(", ")
  end

  at = table.at
  if at > table.fillers.size
    at = table.fillers.size
  end

  values = table.fillers.map do |filler| item(table.shape, table.style, filler_text(filler)) end
  values = values.take(at).push(item(table.shape, table.style, value)).concat(values.drop(at))
  written: List[String] = []
  i = 0
  for text in values
    if table.style == 1 or (table.style == 2 and i == at)
      written = written.push("[#{i}] = #{text}")
    else
      written = written.push(text)
    end

    i += 1
  end

  return written.reverse.join(", ") if table.style == 1

  written.join(", ")
end

# One item of the table holding the function `value`, written in order or with designated fields.
def item(shape: Int, style: Int, value: String) -> String
  case shape
    0 -> value
    3 -> value
    2 ->
      return "{#{op(0, value)}, quick}" if style == 0

      "{.alt = quick, .op = #{op(style, value)}}"

    _ -> op(style, value)
  end
end

def op(style: Int, value: String) -> String
  case style
    0 -> "{1, #{value}}"
    1 -> "{.run = #{value}, .n = 1}"
    _ -> "{.n = 1, .run = #{value}}"
  end
end
