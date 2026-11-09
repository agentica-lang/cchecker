## The baseline: findings a project accepts, so that a run fails only on new ones.

import Files from "files"
import Findings from "findings"
import {Finding} from "findings"
import Regex from "std/regex"

# The version of the file format, for the day it changes.
VERSION = 1

## One accepted kind of finding and how many of it the file holds. It has no line: a finding matches by code, file and
## message.
export struct Entry
  code: String
  file: String
  message: String
  count: Int
end

# The file as it is read. `tools` are the versions of the tools that made it, by name (`gcc`, `clang`, `clang-tidy`);
# a baseline of 0.1.0 has none, and the format stays version 1 because a reader that ignores `tools` loses nothing.
struct Document
  version: Int
  findings: List[Entry]
  tools: Optional[Map[String, String]]
end

## A baseline file: its entries, and the versions of the tools that made it (none for a file of 0.1.0).
export struct Loaded
  entries: List[Entry]
  tools: Map[String, String] = {}
end

## A tool whose version is not the one that made the baseline.
export struct VersionChange
  tool: String
  baseline: String
  current: String
end

## What a run covered: the tools it ran, and the pairs of a tool and a file whose job ended well (see `pair`).
## `full` is a run of every file of a compile database where every job ended well; only it covers the headers, which
## the run did not name.
export struct Scope
  tools: Set[String]
  pairs: Set[String]
  full: Bool
end

## The findings of a run, split by the baseline. `stale` are the entries behind `fixed`, each with the count that was
## not found again, in the order of the file.
export struct Split
  new_findings: List[Finding]
  accepted: Int
  fixed: Int
  stale: List[Entry] = []
end

## Returns the baseline file, or an error when it cannot be read or is not a baseline.
export def load(path: String) -> Result[Loaded]
  text = try Files.read_all(path)
  return parse(path, text)
end

## Returns the baseline in the text of a baseline file.
export def parse(path: String, text: String) -> Result[Loaded]
  document = try decode(path, text)
  if document.version != VERSION
    return error("#{path}: version #{document.version} is not supported, expected #{VERSION}")
  end

  for entry in document.findings
    if entry.count < 1
      return error("#{path}: the count of #{entry.code} in #{entry.file} is #{entry.count}, expected 1 or more")
    end
  end

  return ok(Loaded(entries: document.findings, tools: document.tools.unwrap_or({})))
end

## Returns the entries for the findings: one for each kind, in the order of the report.
export def entries_of(findings: List[Finding]) -> List[Entry]
  groups = findings.group_by(&Findings.baseline_key)
  return groups.values.map do |group|
    first = group.first
    Entry(code: first.code, file: first.file, message: first.message, count: group.size)
  end
end

## Returns the key of a tool on a file, the unit that a scope covers.
export def pair(tool: String, file: String) -> String
  return "#{tool}\n#{file}"
end

## Returns the entries of an updated baseline: those of `entries` that the run did not cover, and one for each kind of
## the findings of the run. A finding in a file that the run did not cover (a header seen through the flags of one
## file) never lowers the count of its entry: a header can show other findings with other flags, so the larger count
## stays.
export def merged(entries: List[Entry], scope: Scope, findings: List[Finding]) -> List[Entry]
  kept = entries.select do |entry| not covered?(scope, entry) end
  held: Map[String, Int] = {}
  for entry in kept
    held = held.put(Findings.key(entry.code, entry.file, entry.message), entry.count)
  end

  found = entries_of(findings).map do |entry|
    count = larger(entry.count, held.get(Findings.key(entry.code, entry.file, entry.message), 0))
    Entry(code: entry.code, file: entry.file, message: entry.message, count: count)
  end

  replaced = Set.new(found.map do |entry| Findings.key(entry.code, entry.file, entry.message) end)
  combined = kept.select do |entry| not replaced.include?(Findings.key(entry.code, entry.file, entry.message)) end
  combined = combined.concat(found)
  return combined.sort_by do |entry| "#{entry.file}\n#{entry.code}\n#{entry.message}" end
end

## Returns the versions for an updated baseline, by name in order. Only a `whole` run (every file of its tools) writes
## versions: it drops those of the tools in `ran` and adds those of `current` (a tool that printed none loses its
## version, as its entries were just rewritten by an unknown one). A run of some files returns `stored`, as the entries
## of the other files are still those of the old versions.
export def updated_tools(
  stored: Map[String, String],
  current: Map[String, String],
  ran: List[String],
  whole: Bool,
) -> Map[String, String]
  if not whole
    return stored
  end

  merged: Map[String, String] = {}
  for tool in stored.keys
    if not ran.include?(tool)
      merged = merged.put(tool, stored[tool])
    end
  end

  for tool in current.keys
    merged = merged.put(tool, current[tool])
  end

  ordered: Map[String, String] = {}
  for tool in merged.keys.sort
    ordered = ordered.put(tool, merged[tool])
  end

  return ordered
end

## Returns the tools of `current` whose version is not the one in `stored`, in the order of the names. A tool of only
## one of them is not compared: it did not run, or it did not name its version. Versions are compared by their number
## (`14.2.0` of `gcc (Debian 14.2.0-19) 14.2.0`), so the build of another distribution of the same version is no
## change; a line with no number is compared whole. The changes keep the full lines.
export def changes(stored: Map[String, String], current: Map[String, String]) -> List[VersionChange]
  names = stored.keys.select do |tool| current.key?(tool) and number(current[tool]) != number(stored[tool]) end
  return names.sort.map do |tool| VersionChange(tool: tool, baseline: stored[tool], current: current[tool]) end
end

## Returns the text of the baseline file, one line for each entry. `tools` are written as they come: see
## `updated_tools`.
export def render(entries: List[Entry], tools: Map[String, String]) -> String
  body = entries.map do |entry| "    #{JSON.encode(entry)}" end.join(",\n")
  return "{\n  \"version\": #{VERSION},\n  \"tools\": #{JSON.encode(tools)},\n  \"findings\": [\n#{body}\n  ]\n}\n"
end

## Writes the baseline. A file that exists is swapped for the new one in a single rename, so a reader never sees half
## of it.
export def write(path: String, entries: List[Entry], tools: Map[String, String]) -> Result[Void]
  text = render(entries, tools)
  if File.stat(path).ok?
    return File.replace(path, text.bytes)
  end

  temporary = path + ".tmp"
  try File.write_text(temporary, text)
  return Path.rename(temporary, path)
end

## Takes the accepted findings out of `findings`. When a kind has more findings than the baseline holds, the last ones
## in the order of the report are the new ones. `fixed` counts the accepted findings of the scope of the run that were
## not found again, and `stale` names their entries.
export def split(findings: List[Finding], entries: List[Entry], scope: Scope) -> Split
  left: Map[String, Int] = {}
  scoped: Set[String] = Set.new([])
  firsts: Map[String, Entry] = {}
  order: List[String] = []
  for entry in entries
    key = Findings.key(entry.code, entry.file, entry.message)
    left = left.put(key, left.get(key, 0) + entry.count)
    if covered?(scope, entry) and not scoped.include?(key)
      scoped = scoped.add(key)
      firsts = firsts.put(key, entry)
      order = order.push(key)
    end
  end

  new_findings: List[Finding] = []
  matched = 0
  for f in findings
    key = Findings.baseline_key(f)
    if left.get(key, 0) > 0
      left = left.put(key, left[key] - 1)
      matched += 1
    else
      new_findings = new_findings.push(f)
    end
  end

  stale: List[Entry] = []
  for key in order
    count = left.get(key, 0)
    if count > 0
      stale = stale.push(firsts[key].with(count: count))
    end
  end

  fixed = stale.reduce(0) do |total, entry| total + entry.count end
  return Split(new_findings: new_findings, accepted: matched, fixed: fixed, stale: stale)
end

## Returns the tool that makes the codes with the prefix of `code`, or "" for none; an entry of no tool is never
## covered.
export def tool_of(code: String) -> String
  if code.start_with?("CC-GCC-")
    return "gcc"
  end

  if code.start_with?("CC-TIDY-")
    return "clang-tidy"
  end

  if code.start_with?("CC-EFFECT-") or code.start_with?("CC-PATH-") or code.start_with?("CC-OWN-")
    return "rules"
  end

  return ""
end

# The first dotted number of a version line, or the line.
def number(line: String) -> String
  case Regex.match(line, /\d+(\.\d+)+/)
    ok(found) -> return found.text
    error(_) -> return line
  end
end

def larger(a: Int, b: Int) -> Int
  if a > b
    return a
  end

  return b
end

# Whether the run covered the entry: its tool ran on the file and ended well, or the run was full.
def covered?(scope: Scope, entry: Entry) -> Bool
  tool = tool_of(entry.code)
  if scope.full
    return scope.tools.include?(tool)
  end

  return scope.pairs.include?(pair(tool, entry.file))
end

def decode(path: String, text: String) -> Result[Document]
  case JSON.decode(text, Document)
    ok(document) -> return ok(document)
    error(message) -> return error("#{path}: #{message}")
  end
end
