## The steps of the features. A scenario runs cchecker, more than once when it needs to, then checks the exit code
## and the output.

import BDD from "std/bdd"
import Paths from "../src/paths"

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
    BDD.step("the C file {string} holds, with ITEMS as {int} times {string}:", &write_generated),
    BDD.step("there is a private folder {string} holding {string}", &make_private_folder),
    BDD.step("there is a folder {string} holding {string}", &make_open_folder),
    BDD.step("I run cchecker with {string}", &run_cchecker),
    BDD.step("I run cchecker with {string} and TMPDIR {string}", &run_with_tmpdir),
    BDD.step("the folder {string} is empty", &folder_empty),
    BDD.step("clang dumps the AST of {string}", &dump_ast),
    BDD.step("clang dumps the JSON AST of {string}", &dump_json_ast),
    BDD.step("the dump is larger than 1 MiB", &dump_is_large),
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
  return write_text(ctx, args[0], BDD.doc_string(ctx))
end

# A large file, which a doc string would not hold: ITEMS in the doc string is the text repeated.
def write_generated(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return write_text(ctx, args[0], BDD.doc_string(ctx).replace("ITEMS", args[2] * args[1].to_i!))
end

# The file is in the folder of the scenario, in a subfolder of it when the name has one.
def write_text(ctx: BDD.Context, name: String, text: String) -> BDD.Context
  started = ensure_folder(ctx)
  path = Path.join([SPECS, folder_of(started), name]).unwrap!
  made = check(started, Dir.mkdir(Paths.parent(path)))
  return check(made, File.write_text(path, text))
end

# A folder made as cchecker makes its folder of dumps (mode 0700), or with the usual mode, with one empty file in it.
def make_private_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return make_folder_with(ctx, args, true)
end

def make_open_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return make_folder_with(ctx, args, false)
end

def make_folder_with(ctx: BDD.Context, args: List[String], private: Bool) -> BDD.Context
  started = ensure_folder(ctx)
  path = host_path(started, args[0])
  made = check(started, Dir.mkdir(Paths.parent(path)))
  if private
    made = check(made, Dir.mkdir_private(path))
  else
    made = check(made, Dir.mkdir(path))
  end

  return check(made, File.write_text("#{path}/#{args[1]}", ""))
end

# $DIR in the words is the folder of the scenario. The words are split at spaces: no argument here has one.
def run_cchecker(ctx: BDD.Context, args: List[String]) -> BDD.Context
  words = args[0].replace("$DIR", folder_of(ctx)).split(" ").select do |word| word != "" end
  return run_program(ctx, "agentica", [PROGRAM].concat(words))
end

# TMPDIR is the folder, made empty first, where the run writes its AST dumps.
def run_with_tmpdir(ctx: BDD.Context, args: List[String]) -> BDD.Context
  started = ensure_folder(ctx)
  folder = args[1].replace("$DIR", folder_of(started))
  made = check(started, Dir.mkdir("#{SPECS}/#{folder}"))
  words = args[0].replace("$DIR", folder_of(made)).split(" ").select do |word| word != "" end
  return run_program(made, "agentica", [PROGRAM].concat(words), {"TMPDIR": folder})
end

def folder_empty(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = host_path(ctx, args[0])
  case Dir.list(path)
    ok(names) -> return BDD.assert(ctx, names.empty?, "#{path} holds #{names.join(", ")}")
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

# The text dump, because the JSON dump of clang 19 leaves out the string of an annotate attribute.
def dump_ast(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return run_program(ctx, "clang", ["-Xclang", "-ast-dump", "-fsyntax-only", "-I../include", args[0]])
end

# The JSON dump as the rules tool asks for it, to show that a fixture is larger than what `Process.output` holds.
def dump_json_ast(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return run_program(ctx, "clang", ["-Xclang", "-ast-dump=json", "-fsyntax-only", "-I../include", args[0]])
end

def dump_is_large(ctx: BDD.Context, args: List[String]) -> BDD.Context
  truncated = JSON.bool(BDD.get(ctx, "truncated").unwrap!).unwrap!
  return BDD.assert(ctx, truncated, "the output of the dump is 1 MiB or less")
end

# Runs a program in specs/ and keeps its exit code and output for the steps that check them.
def run_program(ctx: BDD.Context, program: String, args: List[String], env: Map[String, String] = {}) -> BDD.Context
  process = Process.spawn_captured(program, args, SPECS, RUN_MS, env).unwrap!
  output = Process.output(process, RUN_MS).unwrap!
  code = Process.wait(process, RUN_MS).unwrap!
  Process.close(process)
  return (
    ctx
    |> BDD.set("code", JSON.from(code))
    |> BDD.set("stdout", JSON.from(output.stdout))
    |> BDD.set("stderr", JSON.from(output.stderr))
    |> BDD.set("truncated", JSON.from(output.truncated))
  )
end

def exit_code_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  code = JSON.int(BDD.get(ctx, "code").unwrap!).unwrap!
  return BDD.assert(ctx, code == args[0].to_i!, "exit code #{code}, stderr: #{text(ctx, "stderr")}")
end

# $DIR in the text is the folder of the scenario, as the report shows it.
def output_includes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  expected = BDD.doc_string(ctx).strip.replace("$DIR", folder_of(ctx))
  shown = text(ctx, "stdout")
  return BDD.assert(ctx, shown.include?(expected), "the output does not include #{expected}: #{shown}")
end

def output_excludes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  unwanted = BDD.doc_string(ctx).strip.replace("$DIR", folder_of(ctx))
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

# The file holds the pid of a process the tool started, so it must be there and hold a number: a missing or stale file
# would pass for a process that ended. A killed process is gone from /proc once its parent or init has reaped it; in a
# container nothing may reap it, and it stays as a zombie, which has ended too.
def process_ended(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = host_path(ctx, args[0])
  text = File.read_text(path).unwrap_or("").strip
  found = BDD.assert(ctx, text.to_i.ok?, "#{path} does not hold a pid: #{text}")
  Task.sleep(500)
  return BDD.assert(found, ended?(text), "process #{text} is still running")
end

def ended?(pid: String) -> Bool
  case File.read_text("/proc/#{pid}/status")
    ok(status) -> return status.include?("State:\tZ")
    error(_) -> return true
  end
end

# A path of a step is relative to specs/, $DIR is the folder of the scenario and $PID the pid of the steps, a process
# that runs as long as the scenario.
def host_path(ctx: BDD.Context, path: String) -> String
  return "#{SPECS}/#{path.replace("$DIR", folder_of(ctx)).replace("$PID", "#{System.pid()}")}"
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
