## The steps of the features. A scenario runs cchecker, more than once when it needs to, then checks the exit code
## and the output.

import BDD from "std/bdd"

# The steps run from the folder where `agentica test` runs, the root of the repository.
# cchecker runs in specs/, as a user would run it in a project.
# A scenario that writes C files does it in a folder of its own, specs/scratch/NAME, removed at the end of
# the scenario.
# the end.
# The folder is under specs/ because cchecker shows only the files under its working directory.
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
    BDD.step("the errors include:", &errors_include),
    BDD.step("the file {string} is removed", &remove_file),
    BDD.step("the file {string} exists", &file_exists),
    BDD.step("the file {string} does not exist", &file_missing),
    BDD.step("the process written in {string} has ended", &process_ended),
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

def errors_include(ctx: BDD.Context, args: List[String]) -> BDD.Context
  expected = BDD.doc_string(ctx).strip
  shown = text(ctx, "stderr")
  return BDD.assert(ctx, shown.include?(expected), "the errors do not include #{expected}: #{shown}")
end

def remove_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return check(ctx, Path.remove(host_path(ctx, args[0])))
end

def file_exists(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = host_path(ctx, args[0])
  return BDD.assert(ctx, File.stat(path).ok?, "#{path} does not exist")
end

def file_missing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = host_path(ctx, args[0])
  return BDD.assert(ctx, not File.stat(path).ok?, "#{path} exists")
end

# The file holds the pid of a process the tool started. A killed process is gone from /proc once init has reaped it.
def process_ended(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pid = File.read_text(host_path(ctx, args[0])).unwrap!.strip
  Task.sleep(500)
  return BDD.assert(ctx, not File.stat("/proc/#{pid}").ok?, "process #{pid} is still running")
end

# A path of a step is relative to specs/, and $DIR is the folder of the scenario.
def host_path(ctx: BDD.Context, path: String) -> String
  return "#{SPECS}/#{path.replace("$DIR", folder_of(ctx))}"
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
