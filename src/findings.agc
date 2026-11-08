## The findings that every tool is normalized to, and the failures of the tools.

## One problem found by a tool. `file` is relative to the working directory. `path` is the call path of a finding of
## the rules, from the function at `file`, `line` and `column` to the call that breaks the rule. `source` is the
## `[library]` flag of the settings that made the finding, when one did. `root` says where an inferred root comes from
## (`callback of uv_read_start at file:line`); it is not part of the message, so the baseline holds when the call
## moves.
export struct Finding
  code: String
  tool: String
  file: String
  line: Int
  column: Int
  message: String
  path: List[String] = []
  source: String = ""
  root: String = ""
end

## A callback of a libuv call that the rules could not follow to a function: `argument` is its place (from 0) in the
## call at `file` and `line`.
export struct UnresolvedCallback
  call: String
  argument: Int
  file: String
  line: Int
end

## A tool that could not do its work on a file: it did not start, ran out of time or could not compile the file.
export struct ToolError
  tool: String
  file: String
  message: String
end

## Returns the findings in the order of the report: by file, line, column, code and message.
export def sort(findings: List[Finding]) -> List[Finding]
  return findings.sort_by do |f| "#{f.file}\n#{pad(f.line)}:#{pad(f.column)}\n#{f.code}\n#{f.message}" end
end

## Returns the findings without the repeats of one place: a header reached by several files is reported by each.
export def unique(findings: List[Finding]) -> List[Finding]
  seen: Set[String] = Set.new([])
  kept: List[Finding] = []
  for f in findings
    place = JSON.encode([f.code, f.file, "#{f.line}", "#{f.column}", f.message])
    if not seen.include?(place)
      seen = seen.add(place)
      kept = kept.push(f)
    end
  end

  return kept
end

## Returns what the baseline matches on: the code, the file and the message, never the line, so a finding that moved
## with its code is still the same finding.
export def baseline_key(f: Finding) -> String
  return key(f.code, f.file, f.message)
end

## Returns the baseline key of a finding that is given by its parts.
export def key(code: String, file: String, message: String) -> String
  return JSON.encode([code, file, message])
end

# Zero-padded so that the text order of the sort key is the numeric order.
def pad(n: Int) -> String
  digits = n.to_s
  return "0" * (9 - digits.length) + digits
end
