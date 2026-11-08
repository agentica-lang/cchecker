## The files to check and the compiler flags of each, from a compile database or from the command line.

import Files from "files"
import Paths from "paths"

# Flags of a build that mean nothing to an analysis and would write files or stop the tools: the object file, the
# dependency files. Those in the second set take a value in the next word.
DROPPED = Set.new(["-c", "-MD", "-MMD", "-MP", "-MG"])
DROPPED_WITH_VALUE = Set.new(["-o", "-MF", "-MT", "-MQ", "-MJ"])

## One translation unit. `directory` is absolute and is where the tools run; `file` is as the database spells it.
export struct Entry
  directory: String
  file: String
  args: List[String]
end

# A line of compile_commands.json: `arguments` or `command`, one of them.
struct Raw
  directory: String
  file: String
  command: Optional[String] = none
  arguments: Optional[List[String]] = none
end

## Returns the entries of a compile database: `path` is the file or the folder that holds `compile_commands.json`.
## A relative `directory` is taken from the folder of the database.
export def load(path: String) -> Result[List[Entry]]
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

  return ok(entries)
end

## Returns the entries of the C files given on the command line, all built with the same flags.
export def from_files(files: List[String], flags: List[String]) -> Result[List[Entry]]
  cwd = try Paths.working_directory()
  return ok(files.map do |file| Entry(directory: cwd, file: file, args: flags) end)
end

## Returns the words of a shell command line: spaces separate them, quotes and backslashes group and escape.
export def split_words(text: String) -> List[String]
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

  return words
end

## Returns the flags of a compiler command: it leaves out the compiler, the source file and the flags that name an output.
export def flags_of(words: List[String], file: String) -> List[String]
  kept: List[String] = []
  skip = false
  for word in words.drop(1)
    if skip
      skip = false
      next
    end

    if DROPPED_WITH_VALUE.include?(word)
      skip = true
    elsif not DROPPED.include?(word) and word != file
      kept = kept.push(word)
    end
  end

  return kept
end

def entry(folder: String, row: Raw) -> Result[Entry]
  words = case row.arguments
    some(arguments) -> arguments
    none -> split_words(row.command.unwrap_or(""))
  end

  if words.empty?
    return error("the entry of #{row.file} has no command or arguments")
  end

  directory = try Paths.absolute(folder, row.directory)
  return ok(Entry(directory: directory, file: row.file, args: flags_of(words, row.file)))
end
