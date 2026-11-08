## The baseline: findings a project accepts, so that a run fails only on new ones.

import Files from "files"
import Findings from "findings"
import {Finding} from "findings"

# The version of the file format, for the day it changes.
VERSION = 1

# One accepted finding and how many of it the file holds. It has no line: a finding matches by code, file and message.
struct Entry
  code: String
  file: String
  message: String
  count: Int
end

struct Document
  version: Int
  findings: List[Entry]
end

## The findings of a run, split by the baseline.
export struct Split
  new_findings: List[Finding]
  accepted: Int
  fixed: Int
end

## Returns how many findings of each kind the file accepts, by `Findings.baseline_key`.
export def load(path: String) -> Result[Map[String, Int]]
  text = try Files.read_all(path)
  document = try decode(path, text)
  if document.version != VERSION
    return error("#{path}: version #{document.version} is not supported, expected #{VERSION}")
  end

  counts: Map[String, Int] = {}
  for entry in document.findings
    key = Findings.key(entry.code, entry.file, entry.message)
    counts = counts.put(key, counts.get(key, 0) + entry.count)
  end

  return ok(counts)
end

## Writes the baseline for the findings: one line for each kind of finding, in the order of the report.
export def write(path: String, findings: List[Finding]) -> Result[Void]
  groups = findings.group_by(&Findings.baseline_key)
  entries = groups.values.map do |group|
    first = group.first
    JSON.encode(Entry(code: first.code, file: first.file, message: first.message, count: group.size))
  end

  body = entries.map do |line| "    #{line}" end.join(",\n")
  text = "{\n  \"version\": #{VERSION},\n  \"findings\": [\n#{body}\n  ]\n}\n"
  return File.write_text(path, text)
end

## Takes the accepted findings out of `findings`. When a kind has more findings than the baseline holds, the last ones
## in the order of the report are the new ones. `fixed` counts the accepted findings that were not found again.
export def split(findings: List[Finding], accepted: Map[String, Int]) -> Split
  left = accepted
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

  return Split(new_findings: new_findings, accepted: matched, fixed: left.values.sum)
end

def decode(path: String, text: String) -> Result[Document]
  case JSON.decode(text, Document)
    ok(document) -> return ok(document)
    error(message) -> return error("#{path}: #{message}")
  end
end
