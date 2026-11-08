## Suppressions: a finding that a comment or a CC_IGNORE marks as a false positive, with a reason, leaves the report.
##
## A comment `cchecker: ignore CODE[, CODE...]: reason` holds for the findings of its line and of the line below it.
## `CC_IGNORE("CODE", "reason")` on a function holds for the findings of the rules at that function. A code that ends
## with `*` is a prefix. A suppression that matches no finding of a tool that ran on its file is a finding,
## CC-UNUSED-IGNORE, so a stale one shows.

import Baseline from "baseline"
import {Finding} from "findings"

## The code of a suppression that matched nothing.
export UNUSED = "CC-UNUSED-IGNORE"

MARKER = "cchecker: ignore"
MARK_PREFIX = "ignore("
USAGE = "a suppression is `cchecker: ignore CODE[, CODE...]: reason`, with codes that start with CC-"

## One suppression. `file` is relative to the working directory. A comment holds for `line` and the line below; a
## CC_IGNORE (`function`) for the findings of the rules at `line` and `column`, the place of the function.
export struct Ignore
  file: String
  line: Int
  column: Int
  codes: List[String]
  reason: String
  function: Bool
end

## A finding that a suppression took out, with its reason.
export struct Suppressed
  code: String
  tool: String
  file: String
  line: Int
  column: Int
  message: String
  reason: String
end

## The findings after the suppressions: those that stay, the unused suppressions among them, and those taken out.
export struct Applied
  findings: List[Finding]
  suppressed: List[Suppressed]
end

## Returns the suppressions in the comments of a file, or an error for one without codes or a reason.
export def in_text(file: String, text: String) -> Result[List[Ignore]]
  ignores: List[Ignore] = []
  lines = text.split("\n")
  for i in 0...lines.size
    case lines[i].index_of(MARKER)
      some(at) ->
        rest = lines[i].slice(at + MARKER.length, lines[i].length - at - MARKER.length)
        ignore = try parsed(file, i + 1, at + 1, rest.split("*/").first, false)
        ignores = ignores.push(ignore)
      none -> next
    end
  end

  return ok(ignores)
end

## Returns the suppression of an annotation of a function (`ignore(CODE: reason)`, from CC_IGNORE), or none for any
## other annotation.
export def of_mark(file: String, line: Int, column: Int, mark: String) -> Result[Optional[Ignore]]
  if not mark.start_with?(MARK_PREFIX) or not mark.end_with?(")")
    return ok(none)
  end

  body = mark.slice(MARK_PREFIX.length, mark.length - MARK_PREFIX.length - 1)
  ignore = try parsed(file, line, column, body, true)
  return ok(some(ignore))
end

## Takes the suppressed findings out. `ran` holds the pairs of a tool and a file (`Baseline.pair`) that the run covered
## (a job that ended well; for the rules, only in a full run): only there is a suppression that matched nothing unused,
## as a tool that did not run found nothing.
export def apply(findings: List[Finding], ignores: List[Ignore], ran: Set[String]) -> Applied
  kept: List[Finding] = []
  suppressed: List[Suppressed] = []
  used: Set[Int] = Set.new([])
  for f in findings
    case first_match(f, ignores)
      some(i) ->
        used = used.add(i)
        suppressed = suppressed.push(
          Suppressed(
            code: f.code,
            tool: f.tool,
            file: f.file,
            line: f.line,
            column: f.column,
            message: f.message,
            reason: ignores[i].reason,
          ),
        )
      none -> kept = kept.push(f)
    end
  end

  for i in 0...ignores.size
    if not used.include?(i) and checked?(ignores[i], ran)
      kept = kept.push(unused(ignores[i]))
    end
  end

  return Applied(findings: kept, suppressed: suppressed)
end

# The codes and the reason of `CODE[, CODE...]: reason`.
def parsed(file: String, line: Int, column: Int, text: String, function: Bool) -> Result[Ignore]
  case text.index_of(":")
    some(at) ->
      codes = text.slice(0, at).replace(",", " ").split(" ").select do |code| code != "" end
      reason = text.slice(at + 1, text.length - at - 1).strip
      if codes.empty? or reason == "" or not codes.all? do |code| code.start_with?("CC-") end
        return error("#{file}:#{line}: #{USAGE}")
      end

      return ok(Ignore(file: file, line: line, column: column, codes: codes, reason: reason, function: function))
    none -> return error("#{file}:#{line}: #{USAGE}")
  end
end

# The index of the first suppression that holds for the finding.
def first_match(f: Finding, ignores: List[Ignore]) -> Optional[Int]
  for i in 0...ignores.size
    if holds?(ignores[i], f)
      return some(i)
    end
  end

  return none
end

def holds?(ignore: Ignore, f: Finding) -> Bool
  if ignore.file != f.file or not ignore.codes.any? do |code| matches?(code, f.code) end
    return false
  end

  if ignore.function
    return f.line == ignore.line and f.column == ignore.column
  end

  return f.line == ignore.line or f.line == ignore.line + 1
end

def matches?(pattern: String, code: String) -> Bool
  if pattern.end_with?("*")
    return code.start_with?(pattern.slice(0, pattern.length - 1))
  end

  return code == pattern
end

# Whether every tool of the codes ran on the file and ended well, so a suppression that matched nothing is stale. A
# code of no known tool (a prefix such as `CC-*`) is never reported.
def checked?(ignore: Ignore, ran: Set[String]) -> Bool
  return ignore.codes.all? do |code| ran.include?(Baseline.pair(tool_of(code), ignore.file)) end
end

# The tool of a code or of a prefix; "" for none, which no pair of a run has.
def tool_of(code: String) -> String
  return Baseline.tool_of(code.replace("*", ""))
end

def unused(ignore: Ignore) -> Finding
  return Finding(
    code: UNUSED,
    tool: tool_of(ignore.codes.first),
    file: ignore.file,
    line: ignore.line,
    column: ignore.column,
    message: "the suppression of #{ignore.codes.join(", ")} matches no finding: #{ignore.reason}",
  )
end
