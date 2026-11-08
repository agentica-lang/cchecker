## The steps of the features: each scenario runs cchecker (more than once when it needs to) on C files, then asserts the
## exit code and what the output holds.

import BDD from "std/bdd"

# The steps run from the folder where `agentica test` runs (the root of the repository), and cchecker runs in
# specs/, as
# a user would run it in a project. Scenarios that write C files do it in a folder of their own, specs/scratch/NAME
# (gitignored; cchecker shows only the files under its working directory). The scenario removes it when it ends.
SPECS = "specs"
SCRATCH = "scratch"
PROGRAM = "../cchecker.agc"
RUN_MS = 120_000

def main() -> Void
  BDD.run([
    BDD.step("the C file {string} holds:", &write_file),
    BDD.step("I run cchecker with {string}", &run_cchecker),
    BDD.step("clang dumps the AST of {string}", &dump_ast),
    BDD.step("the exit code is {int}", &exit_code_is),
    BDD.step("the output includes:", &output_includes),
    BDD.step("the output does not include:", &output_excludes),
  ])
end

def write_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  started = ensure_folder(ctx)
  path = Path.join([SPECS, folder_of(started), args[0]]).unwrap!
  return check(started, File.write_text(path, BDD.doc_string(started)))
end

# $DIR in the words is the folder of the scenario. The words are split at spaces: no argument here has one.
def run_cchecker(ctx: BDD.Context, args: List[String]) -> BDD.Context
  words = args[0].replace("$DIR", folder_of(ctx)).split(" ").select do |word| word != "" end
  return run_program(ctx, "agentica", [PROGRAM].concat(words))
end

# The text dump, because the JSON dump of clang 19 leaves out the string of an annotate attribute.
def dump_ast(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return run_program(ctx, "clang", ["-Xclang", "-ast-dump", "-fsyntax-only", "-I../include", args[0]])
end

# Runs a program in specs/ and keeps its exit code and output for the steps that check them.
def run_program(ctx: BDD.Context, program: String, args: List[String]) -> BDD.Context
  process = Process.spawn_captured(program, args, SPECS, RUN_MS).unwrap!
  output = Process.output(process, RUN_MS).unwrap!
  code = Process.wait(process, RUN_MS).unwrap!
  Process.close(process)
  return (
    ctx
    |> BDD.set("code", JSON.from(code))
    |> BDD.set("stdout", JSON.from(output.stdout))
    |> BDD.set("stderr", JSON.from(output.stderr))
  )
end

def exit_code_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  code = JSON.int(BDD.get(ctx, "code").unwrap!).unwrap!
  return BDD.assert(ctx, code == args[0].to_i!, "exit code #{code}, stderr: #{text(ctx, "stderr")}")
end

def output_includes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  expected = BDD.doc_string(ctx).strip
  shown = text(ctx, "stdout")
  return BDD.assert(ctx, shown.include?(expected), "the output does not include #{expected}: #{shown}")
end

def output_excludes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  unwanted = BDD.doc_string(ctx).strip
  shown = text(ctx, "stdout")
  return BDD.assert(ctx, not shown.include?(unwanted), "the output includes #{unwanted}: #{shown}")
end

def text(ctx: BDD.Context, name: String) -> String
  return JSON.string(BDD.get(ctx, name).unwrap!).unwrap!
end

def folder_of(ctx: BDD.Context) -> String
  case BDD.get(ctx, "folder")
    ok(value) -> return JSON.string(value).unwrap!
    error(_) -> return SCRATCH
  end
end

def ensure_folder(ctx: BDD.Context) -> BDD.Context
  if BDD.get(ctx, "folder").ok?
    return ctx
  end

  folder = "#{SCRATCH}/#{System.pid()}-#{Time.now_ms()}"
  made = check(ctx, Dir.mkdir("#{SPECS}/#{folder}"))
  return (
    made
    |> BDD.set("folder", JSON.from(folder))
    |> BDD.after(&remove_folder)
  )
end

def remove_folder(ctx: BDD.Context) -> Result[Void]
  return Path.remove("#{SPECS}/#{folder_of(ctx)}")
end

# Fails the step with the error of a file operation.
def check(ctx: BDD.Context, result: Result[Void]) -> BDD.Context
  case result
    ok(_) -> return ctx
    error(message) -> return BDD.assert(ctx, false, message)
  end
end
