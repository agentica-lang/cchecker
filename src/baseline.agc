## The baseline: findings a project accepts, so that a run fails only on new ones.

import Files from "files"
import Findings from "findings"
import {Finding} from "findings"

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

struct Document
  version: Int
  findings: List[Entry]
end

## What a run covered: the tools it ran and the files. `full` is a run of a whole compile database, which covers every
## file, the headers included.
export struct Scope
  tools: Set[String]
  files: Set[String]
  full: Bool
end

## The findings of a run, split by the baseline.
export struct Split
  new_findings: List[Finding]
  accepted: Int
  fixed: Int
end

## Returns the entries of the baseline file, or an error when it cannot be read or is not a baseline.
export def load(path: String) -> Result[List[Entry]]
  text = try Files.read_all(path)
  return parse(path, text)
end

## Returns the entries of the text of a baseline file.
export def parse(path: String, text: String) -> Result[List[Entry]]
  document = try decode(path, text)
  if document.version != VERSION
    return error("#{path}: version #{document.version} is not supported, expected #{VERSION}")
  end

  for entry in document.findings
    if entry.count < 1
      return error("#{path}: the count of #{entry.code} in #{entry.file} is #{entry.count}, expected 1 or more")
    end
  end

  return ok(document.findings)
end

## Returns the entries for the findings: one for each kind, in the order of the report.
export def entries_of(findings: List[Finding]) -> List[Entry]
  groups = findings.group_by(&Findings.baseline_key)
  return groups.values.map do |group|
    first = group.first
    Entry(code: first.code, file: first.file, message: first.message, count: group.size)
  end
end

## Returns the entries of an updated baseline: those of `entries` that the run did not cover, and one for each kind of
## the findings of the run.
export def merged(entries: List[Entry], scope: Scope, findings: List[Finding]) -> List[Entry]
  kept = entries.select do |entry| not covered?(scope, entry) end
  return kept.concat(entries_of(findings)).sort_by do |entry| "#{entry.file}\n#{entry.code}\n#{entry.message}" end
end

## Writes the baseline, one line for each entry. A file that exists is swapped for the new one in a single rename, so a
## reader never sees half of it.
export def write(path: String, entries: List[Entry]) -> Result[Void]
  body = entries.map do |entry| "    #{JSON.encode(entry)}" end.join(",\n")
  text = "{\n  \"version\": #{VERSION},\n  \"findings\": [\n#{body}\n  ]\n}\n"
  if File.stat(path).ok?
    return File.replace(path, text.bytes)
  end

  temporary = path + ".tmp"
  try File.write_text(temporary, text)
  return Path.rename(temporary, path)
end

## Takes the accepted findings out of `findings`. When a kind has more findings than the baseline holds, the last ones
## in the order of the report are the new ones. `fixed` counts the accepted findings of the scope of the run that were
## not found again.
export def split(findings: List[Finding], entries: List[Entry], scope: Scope) -> Split
  left: Map[String, Int] = {}
  scoped: Set[String] = Set.new([])
  for entry in entries
    key = Findings.key(entry.code, entry.file, entry.message)
    left = left.put(key, left.get(key, 0) + entry.count)
    if covered?(scope, entry)
      scoped = scoped.add(key)
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

  fixed = 0
  for key in scoped.to_a
    fixed += left.get(key, 0)
  end

  return Split(new_findings: new_findings, accepted: matched, fixed: fixed)
end

# Whether the run covered the entry: it ran the tool of the code, on the file or on all of them.
def covered?(scope: Scope, entry: Entry) -> Bool
  tool = tool_of(entry.code)
  return scope.tools.include?(tool) and (scope.full or scope.files.include?(entry.file))
end

# The tool that makes the codes with this prefix; a code of a later phase has no tool and is never covered.
def tool_of(code: String) -> String
  if code.start_with?("CC-GCC-")
    return "gcc"
  end

  if code.start_with?("CC-TIDY-")
    return "clang-tidy"
  end

  return ""
end

def decode(path: String, text: String) -> Result[Document]
  case JSON.decode(text, Document)
    ok(document) -> return ok(document)
    error(message) -> return error("#{path}: #{message}")
  end
end
