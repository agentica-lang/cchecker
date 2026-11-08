## Suppressions: a finding that a comment or a CC_IGNORE marks as a false positive, with a reason, leaves the report.
##
## A comment that starts with `cchecker: ignore CODE[, CODE...]: reason` and trails code holds for the findings of its
## line; one alone on its line holds for its line and the line below. Strings are not read. `CC_IGNORE("CODE",
## "reason")` on a function holds for the findings of the rules at that function. A code that ends with `*` is a prefix,
## and every code names a tool (`CC-GCC-`, `CC-TIDY-`, `CC-EFFECT-` or `CC-PATH-`). When several hold for a finding,
## the nearest gives the reason and all are used. A suppression that matches no finding of a tool that ran on its file
## is a finding, CC-UNUSED-IGNORE, so a stale one shows.

import Baseline from "baseline"
import {Finding} from "findings"

## The code of a suppression that matched nothing.
export UNUSED = "CC-UNUSED-IGNORE"

MARKER = "cchecker:"
WORD = "ignore"
BLANKS = Set.new([" ", "\t", "\r"])
LEADING = Set.new([" ", "\t", "\r", "*"])
MARK_PREFIX = "ignore("
USAGE = (
  "a suppression is `cchecker: ignore CODE[, CODE...]: reason`, " +
  "with codes that start with CC-GCC-, CC-TIDY-, CC-EFFECT- or CC-PATH-"
)

## One suppression. `file` is relative to the working directory. A comment holds for `line`, and for the line below
## when it is `alone` on its line; a CC_IGNORE (`function`) for the findings of the rules at `line` and `column`, the
## place of the function.
export struct Ignore
  file: String
  line: Int
  column: Int
  codes: List[String]
  reason: String
  function: Bool
  alone: Bool = false
end

# The text of a comment on one line, from `start` (0-based), without its `//`, `/*` or `*/`.
struct Comment
  start: Int
  text: String
end

# The comments of one line, whether the line has code outside them, and whether a block comment goes on past it.
struct Lexed
  comments: List[Comment]
  code: Bool
  in_block: Bool
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

## Returns the suppressions in the comments of a file, or an error for one without codes or a reason, or with a code of
## no tool.
export def in_text(file: String, text: String) -> Result[List[Ignore]]
  ignores: List[Ignore] = []
  if not text.include?(MARKER)
    return ok(ignores)
  end

  in_block = false
  lines = text.split("\n")
  for i in 0...lines.size
    lexed = lexed_line(lines[i], in_block)
    in_block = lexed.in_block
    for comment in lexed.comments
      case body_of(comment.text)
        some(found) ->
          ignore = try parsed(file, i + 1, comment.start + found.start + 1, found.text, false)
          ignores = ignores.push(ignore.with(alone: not lexed.code))
        none -> next
      end
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
    matching = (0...ignores.size).to_a.select do |i| holds?(ignores[i], f) end
    for i in matching
      used = used.add(i)
    end

    case nearest(f, ignores, matching)
      some(i) ->
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

# Splits one line into its comments and the rest, skipping string and character literals, so a marker in a string is
# not read. `in_block` says that the line starts inside a block comment.
def lexed_line(line: String, in_block: Bool) -> Lexed
  chars = line.split("")
  n = chars.size
  comments: List[Comment] = []
  code = false
  block = in_block
  i = 0
  while i < n
    if block
      j = i
      while j < n and not (chars[j] == "*" and j + 1 < n and chars[j + 1] == "/")
        j += 1
      end

      comments = comments.push(Comment(start: i, text: line.slice(i, j - i)))
      if j < n
        block = false
        i = j + 2
      else
        i = n
      end

      next
    end

    c = chars[i]
    following = ""
    if i + 1 < n
      following = chars[i + 1]
    end

    if c == "/" and following == "/"
      comments = comments.push(Comment(start: i + 2, text: line.slice(i + 2, n - i - 2)))
      i = n
    elsif c == "/" and following == "*"
      block = true
      i += 2
    elsif c == "\"" or c == "'"
      code = true
      i += 1
      while i < n and chars[i] != c
        if chars[i] == "\\"
          i += 1
        end

        i += 1
      end

      i += 1
    else
      if not BLANKS.include?(c)
        code = true
      end

      i += 1
    end
  end

  return Lexed(comments: comments, code: code, in_block: block)
end

# The text after `cchecker: ignore` in a comment, and where the marker starts in it; none when the comment does not
# start with the marker (after blanks, and the `*` of a doc comment), so a comment that only mentions it is no
# suppression. Any blanks may stand between `cchecker:`, `ignore` and the codes, but at least one after `ignore`.
def body_of(text: String) -> Optional[Comment]
  at = skipped(text, LEADING)
  if not text.slice(at, text.length - at).start_with?(MARKER)
    return none
  end

  word = at + MARKER.length
  word += skipped(text.slice(word, text.length - word), BLANKS)
  if not text.slice(word, text.length - word).start_with?(WORD)
    return none
  end

  codes = word + WORD.length
  blanks = skipped(text.slice(codes, text.length - codes), BLANKS)
  if blanks == 0 and codes < text.length
    return none
  end

  return some(Comment(start: at, text: text.slice(codes + blanks, text.length - codes - blanks)))
end

# The number of characters at the start of `text` that are in `set`.
def skipped(text: String, set: Set[String]) -> Int
  i = 0
  while i < text.length and set.include?(text.at(i))
    i += 1
  end

  return i
end

# The codes and the reason of `CODE[, CODE...]: reason`.
def parsed(file: String, line: Int, column: Int, text: String, function: Bool) -> Result[Ignore]
  case text.index_of(":")
    some(at) ->
      codes = text.slice(0, at).replace(",", " ").split(" ").select do |code| code != "" end
      reason = text.slice(at + 1, text.length - at - 1).strip
      if codes.empty? or reason == "" or not codes.all? do |code| tool_of(code) != "" end
        return error("#{file}:#{line}: #{USAGE}")
      end

      return ok(Ignore(file: file, line: line, column: column, codes: codes, reason: reason, function: function))
    none -> return error("#{file}:#{line}: #{USAGE}")
  end
end

# The suppression among `matching` nearest to the finding: one on its line before one on the line above.
def nearest(f: Finding, ignores: List[Ignore], matching: List[Int]) -> Optional[Int]
  best: Optional[Int] = none
  for i in matching
    case best
      some(b) ->
        if f.line - ignores[i].line < f.line - ignores[b].line
          best = some(i)
        end

      none -> best = some(i)
    end
  end

  return best
end

def holds?(ignore: Ignore, f: Finding) -> Bool
  if ignore.file != f.file or not ignore.codes.any? do |code| matches?(code, f.code) end
    return false
  end

  if ignore.function
    return f.line == ignore.line and f.column == ignore.column
  end

  return f.line == ignore.line or (ignore.alone and f.line == ignore.line + 1)
end

def matches?(pattern: String, code: String) -> Bool
  if pattern.end_with?("*")
    return code.start_with?(pattern.slice(0, pattern.length - 1))
  end

  return code == pattern
end

# Whether every tool of the codes ran on the file and ended well, so a suppression that matched nothing is stale.
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
