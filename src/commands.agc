## The files to check and the compiler flags of each, from a compile database or from the command line.

import Files from "files"
import Paths from "paths"

## One translation unit. `directory` is absolute and is where the tools run; `file` is as the database spells it.
struct Entry
  directory: String
  file: String
  args: List[String]
end

## The entries of a run with each file once for each set of flags that can change what the tools find, and the
## count of the entries that were left out for it.
struct Folded
  entries: List[Entry]
  folded: Int
end

## Returns the entries of a compile database: `path` is the file or the folder that holds `compile_commands.json`.
## A relative `directory` is taken from the folder of the database.
def load(path: String) -> Result[List[Entry]]
  file = path
  info = try File.stat(path)
  if info.kind == "directory"
    file = try Path.join([path, "compile_commands.json"])
  end

  text = try Files.read_all(file)
  items = try JSON.list(try JSON.parse(text))
  folder = Paths.parent(try Path.resolve(file))
  entries: List[Entry] = []
  for item in items
    row = try JSON.decode(item, Raw)
    entries = entries.push(try entry(folder, row))
  end

  ok(entries)
end

## Returns the entries of the C files given on the command line, all built with the same flags.
def from_files(files: List[String], flags: List[String]) -> Result[List[Entry]]
  cwd = try Paths.working_directory()
  ok(files.map do |file| Entry(directory: cwd, file: file, args: flags) end)
end

## Returns the entries with the repeats of a file left out, the first one kept: CMake lists a source file once for
## each library it goes in (static and shared), and each tool would check it as many times. Two entries are one when
## they run in the same folder on the same file with the same flags, leaving out those that only a shared library adds
## (`UNFOLDED`, `-D<target>_EXPORTS`) and the defines named in `ignored` (`[database] fold_ignoring`), with any value.
## Other defines or include paths may change what the tools find: such entries are each kept.
def fold(entries: List[Entry], ignored: List[String]) -> Folded
  names = Set.new(ignored)
  seen: Set[String] = Set.new([])
  kept: List[Entry] = []
  for entry in entries
    path = Paths.absolute(entry.directory, entry.file).unwrap_or(entry.file)
    flags = folding_flags(entry.args, names)
    key = [entry.directory, path].concat(flags).join("\n")
    if not seen.include?(key)
      seen = seen.add(key)
      kept = kept.push(entry)
    end
  end

  Folded(entries: kept, folded: entries.size - kept.size)
end

## Returns the words of a shell command line: spaces separate them, quotes and backslashes group and escape.
def split_words(text: String) -> List[String]
  words: List[String] = []
  current: List[String] = []
  started = false
  quote = ""
  escaped = false
  for ch in text.split("")
    if escaped
      current = current.push(ch)
      escaped = false
      next
    end

    if ch == "\\" and quote != "'"
      escaped = true
      started = true
      next
    end

    if quote != ""
      if ch == quote
        quote = ""
      else
        current = current.push(ch)
      end

      next
    end

    if ch == "'" or ch == "\""
      quote = ch
      started = true
    elsif ch == " " or ch == "\t" or ch == "\n"
      if started
        words = words.push(current.join(""))
        current = []
        started = false
      end
    else
      current = current.push(ch)
      started = true
    end
  end

  if started
    words = words.push(current.join(""))
  end

  words
end

## Returns the flags of a compiler command: it leaves out the compiler, the source file (however the command spells it
## against `directory`) and the flags that name an output.
def flags_of(words: List[String], source: String, directory: String) -> List[String]
  kept: List[String] = []
  skip = false
  for word in words.drop(1)
    if skip
      skip = false
      next
    end

    if DROPPED_WITH_VALUE.include?(word)
      skip = true
    elsif not DROPPED.include?(word) and not names?(word, source, directory)
      kept = kept.push(word)
    end
  end

  kept
end

private

# Flags that a build system adds to the entry of a file for a shared library and not for the static one. They change
# the code that the compiler makes (position independent), not the C that the tools read: their one trace in the C is
# the `__PIC__` and `__PIE__` macros, which code reads to pick assembly. So two entries that differ only in them are
# one. CMake adds `-D<target>_EXPORTS` too (see `export_define?`).
UNFOLDED = Set.new(["-fPIC", "-fpic", "-fPIE", "-fpie"])

# Flags of a build that mean nothing to an analysis and would write files or stop the tools: the object file, the
# dependency files. Those in the second set take a value in the next word.
DROPPED = Set.new(["-c", "-MD", "-MMD", "-MP", "-MG"])
DROPPED_WITH_VALUE = Set.new(["-o", "-MF", "-MT", "-MQ", "-MJ"])

# A line of compile_commands.json: `arguments` or `command`, one of them.
struct Raw
  directory: String
  file: String
  command: Optional[String] = none
  arguments: Optional[List[String]] = none
end

def entry(folder: String, row: Raw) -> Result[Entry]
  words = case row.arguments
    some(arguments) -> arguments
    none -> split_words(row.command.unwrap_or(""))
  end

  return error("the entry of #{row.file} has no command or arguments") if words.empty?

  directory = try Paths.absolute(folder, row.directory)
  source = try Paths.absolute(directory, row.file)
  ok(Entry(directory: directory, file: row.file, args: flags_of(words, source, directory)))
end

# Whether the word is a path to the source file. A flag is not, and a word that cannot be made a path is not either.
def names?(word: String, source: String, directory: String) -> Bool
  return false if word.start_with?("-")

  Paths.absolute(directory, word).unwrap_or("") == source
end

# The flags of an entry that tell it from another for folding: without those of a shared library, and without the
# defines of `ignored`, written `-DNAME`, `-DNAME=value` or as two words, `-D NAME`.
def folding_flags(args: List[String], ignored: Set[String]) -> List[String]
  flags: List[String] = []
  skip = false
  for i in 0...args.size
    flag = args[i]
    if skip
      skip = false
      next
    end

    if flag == "-D" and i + 1 < args.size and ignored.include?(define_name(args[i + 1]))
      skip = true
    elsif not UNFOLDED.include?(flag) and not export_define?(flag) and not ignored_define?(flag, ignored)
      flags = flags.push(flag)
    end
  end

  flags
end

# Whether the flag is a define of a name in `ignored`.
def ignored_define?(flag: String, ignored: Set[String]) -> Bool
  flag.start_with?("-D") and flag.length > 2 and ignored.include?(define_name(flag.slice(2, flag.length - 2)))
end

# The name of a define written `NAME` or `NAME=value`.
def define_name(text: String) -> String
  case text.index_of("=")
    some(at) -> text.slice(0, at)
    none -> text
  end
end

# Whether the flag is the define that CMake adds to each file of a shared library, `-D<target>_EXPORTS`, which code
# reads only to mark what the library exports.
def export_define?(flag: String) -> Bool
  flag.start_with?("-D") and flag.end_with?("_EXPORTS") and not flag.include?("=")
end
