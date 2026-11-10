## Suppressions: a finding that a comment or a CC_IGNORE marks as a false positive, with a reason, leaves the report.
##
## A comment (or a line of a block comment) that starts with `cchecker: ignore CODE[, CODE...]: reason` and trails
## code holds for the findings of its line; one alone on its line holds for its line and the line below. Strings are
## not read. `CC_IGNORE("CODE", "reason")` on a function holds for the findings of the rules at that function. A code
## that ends with `*` is a prefix, and every code names a tool (`CC-GCC-`, `CC-TIDY-`, `CC-EFFECT-`, `CC-PATH-` or
## `CC-OWN-`). When several hold for a finding, the nearest gives the reason and all are used. A code of a suppression
## that matches no finding of a tool that ran on its file gives a finding, CC-UNUSED-IGNORE, so a stale one shows.

import Baseline from "baseline"
import {Finding} from "findings"

## The code of a suppression that matched nothing.
export UNUSED = "CC-UNUSED-IGNORE"

MARKER = "cchecker:"
WORD = "ignore"
BLANKS = Set.new([" ", "\t", "\r"])
# What may stand before the marker in a comment: blanks, the `*` of a block comment's line, and the third `/`, the
# `!` and the `<` of a doc comment (`///`, `//!`, `/**`, `/*!`, `///<`).
LEADING = Set.new([" ", "\t", "\r", "*", "/", "!", "<"])
# The directives whose text is not made of tokens, so a `'` there opens no literal (`#error it's`); a `"` still does.
TEXT_DIRECTIVES = ["error", "warning"]
MARK_PREFIX = "ignore("
# What a line leaves open for the next (Lexed.carry): a block comment, or a `//` comment continued with `\`.
BLOCK = "*"
LINE = "/"
# The tool whose findings a CC_IGNORE holds for: only the rules know the function of a finding.
RULES = "rules"
USAGE = (
  "a suppression is `cchecker: ignore CODE[, CODE...]: reason`, " +
  "with codes that start with CC-GCC-, CC-TIDY-, CC-EFFECT-, CC-PATH- or CC-OWN-"
)
MARK_USAGE = "CC_IGNORE takes codes of the rules only (CC-EFFECT-, CC-PATH- or CC-OWN-)"

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

# The comments of one line, whether the line has code outside them, and what goes on past its end (`carry`): "" for
# nothing, BLOCK for a block comment, LINE for a `//` comment that ends with `\`, or the quote of a string or char
# literal that ends with `\`.
struct Lexed
  comments: List[Comment]
  code: Bool
  carry: String
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
  return ok(ignores) if not text.include?(MARKER)

  carry = ""
  lines = text.split("\n")
  for i in 0...lines.size
    lexed = lexed_line(lines[i], carry)
    carry = lexed.carry
    for comment in lexed.comments
      case body_of(comment.text)
        some(found) ->
          ignore = try parsed(file, i + 1, comment.start + found.start + 1, found.text, false)
          ignores = ignores.push(ignore.with(alone: not lexed.code))
        none -> next
      end
    end
  end

  ok(ignores)
end

## Returns the suppression of an annotation of a function (`ignore(CODE: reason)`, from CC_IGNORE), or none for any
## other annotation; an error for a code of another tool than the rules, which never report at a function.
export def of_mark(file: String, line: Int, column: Int, mark: String) -> Result[Optional[Ignore]]
  return ok(none) if not mark.start_with?(MARK_PREFIX) or not mark.end_with?(")")

  body = mark.slice(MARK_PREFIX.length, mark.length - MARK_PREFIX.length - 1)
  ignore = try parsed(file, line, column, body, true)
  return error("#{file}:#{line}: #{MARK_USAGE}") if not ignore.codes.all? do |code| tool_of(code) == RULES end

  ok(some(ignore))
end

## Takes the suppressed findings out. `ran` holds the pairs of a tool and a file (`Baseline.pair`) that the run covered
## (a job that ended well; for the rules, only in a full run): only there is a suppression that matched nothing unused,
## as a tool that did not run found nothing.
export def apply(findings: List[Finding], ignores: List[Ignore], ran: Set[String]) -> Applied
  kept: List[Finding] = []
  suppressed: List[Suppressed] = []
  used: Set[String] = Set.new([])
  for f in findings
    matching = (0...ignores.size).to_a.select do |i| holds?(ignores[i], f) end
    for i in matching
      for code in ignores[i].codes
        if matches?(code, f.code)
          used = used.add("#{i} #{code}")
        end
      end
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
    ignore = ignores[i]
    stale = ignore.codes.select do |code| not used.include?("#{i} #{code}") and checked?(ignore, code, ran) end
    if not stale.empty?
      kept = kept.concat(unused(ignore, stale))
    end
  end

  Applied(findings: kept, suppressed: suppressed)
end

# Splits one line into its comments and the rest, skipping string and character literals, so a marker in a string is
# not read. `carry` is what the line before left open (Lexed): a block comment, a `//` comment or a literal continued
# with `\`. A line of a continued comment is a comment line, as a line of a block comment is.
def lexed_line(line: String, carry: String) -> Lexed
  chars = line.split("")
  n = chars.size
  comments: List[Comment] = []
  return Lexed(comments: [Comment(start: 0, text: line)], code: false, carry: continued(line, LINE)) if carry == LINE

  code = false
  block = carry == BLOCK
  prose = carry == "" and text_directive?(line)
  i = 0
  if carry == "\"" or carry == "'"
    code = true
    i = literal_end(chars, 0, carry)
    return Lexed(comments: [], code: true, carry: continued(line, carry)) if i > n
  end

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
      return Lexed(comments: comments, code: code, carry: continued(line, LINE))
    elsif c == "/" and following == "*"
      block = true
      i += 2
    elsif c == "'" and (prose or separator?(chars, i))
      code = true
      i += 1
    elsif c == "\"" or c == "'"
      code = true
      i = literal_end(chars, i + 1, c)
      return Lexed(comments: comments, code: true, carry: continued(line, c)) if i > n
    else
      if not BLANKS.include?(c)
        code = true
      end

      i += 1
    end
  end

  carry_out = ""
  if block
    carry_out = BLOCK
  end

  Lexed(comments: comments, code: code, carry: carry_out)
end

# The index after the quote `quote` that closes a literal whose text starts at `from`, or past the end of the line
# (n + 1) when the line ends first.
def literal_end(chars: List[String], from: Int, quote: String) -> Int
  i = from
  while i < chars.size and chars[i] != quote
    if chars[i] == "\\"
      i += 1
    end

    i += 1
  end

  return chars.size + 1 if i >= chars.size

  i + 1
end

# `open` when the line ends with a `\` that continues it on the next line, else "".
def continued(line: String, open: String) -> String
  # gcc and clang also splice a `\` followed by blanks (with a warning), and a line of a CRLF file ends with `\r`.
  end_at = line.length
  while end_at > 0 and BLANKS.include?(line.at(end_at - 1))
    end_at -= 1
  end

  return open if end_at > 0 and line.at(end_at - 1) == "\\"

  ""
end

# Whether the `'` at `i` is a digit separator of C23 (`1'000`, `0xff'ff`, `0x1.f'fp0`): it stands inside a number, a
# token that starts with a digit (the dot of a floating number is part of it).
def separator?(chars: List[String], i: Int) -> Bool
  start = i
  while start > 0 and (identifier_char?(chars[start - 1]) or chars[start - 1] == "'" or chars[start - 1] == ".")
    start -= 1
  end

  start < i and "0123456789".include?(chars[start])
end

def identifier_char?(c: String) -> Bool
  c == "_" or "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".include?(c)
end

# Whether the line is an `#error` or `#warning` directive.
def text_directive?(line: String) -> Bool
  return false if not line.strip.start_with?("#")

  words = line.strip.replace("#", "# ").split(" ").select do |word| word != "" end
  words.size >= 2 and words[0] == "#" and TEXT_DIRECTIVES.include?(words[1])
end

# The text after `cchecker: ignore` in a comment, and where the marker starts in it; none when the comment does not
# start with the marker (after blanks, the `*` of a block comment's line, or the `/` or `!` of a doc comment), so a
# comment that only mentions it is no suppression. Any blanks may stand between `cchecker:`, `ignore` and the codes,
# but at least one after `ignore`: a word that only starts with it (`ignore:`, `ignore,X`, `ignored`) gives an empty
# body, a usage error, so the marker the user meant is not dropped.
def body_of(text: String) -> Optional[Comment]
  at = skipped(text, LEADING)
  return none if not text.slice(at, text.length - at).start_with?(MARKER)

  word = at + MARKER.length
  word += skipped(text.slice(word, text.length - word), BLANKS)
  return none if not text.slice(word, text.length - word).start_with?(WORD)

  codes = word + WORD.length
  blanks = skipped(text.slice(codes, text.length - codes), BLANKS)
  return some(Comment(start: at, text: "")) if blanks == 0 and codes < text.length

  some(Comment(start: at, text: text.slice(codes + blanks, text.length - codes - blanks)))
end

# The number of characters at the start of `text` that are in `set`.
def skipped(text: String, set: Set[String]) -> Int
  i = 0
  while i < text.length and set.include?(text.at(i))
    i += 1
  end

  i
end

# The codes and the reason of `CODE[, CODE...]: reason`.
def parsed(file: String, line: Int, column: Int, text: String, function: Bool) -> Result[Ignore]
  case text.index_of(":")
    some(at) ->
      spaced = text.slice(0, at).replace(",", " ").replace("\t", " ").replace("\r", " ")
      codes = spaced.split(" ").select do |code| code != "" end.uniq
      reason = text.slice(at + 1, text.length - at - 1).strip
      if codes.empty? or reason == "" or not codes.all? do |code| known_code?(code) end
        return error("#{file}:#{line}: #{USAGE}")
      end

      ok(Ignore(file: file, line: line, column: column, codes: codes, reason: reason, function: function))
    none -> error("#{file}:#{line}: #{USAGE}")
  end
end

# A code of a tool, with a `*` only at its end.
def known_code?(code: String) -> Bool = tool_of(code) != "" and not code.slice(0, code.length - 1).include?("*")

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

  best
end

def holds?(ignore: Ignore, f: Finding) -> Bool
  return false if ignore.file != f.file or not ignore.codes.any? do |code| matches?(code, f.code) end

  return f.line == ignore.line and f.column == ignore.column if ignore.function

  f.line == ignore.line or (ignore.alone and f.line == ignore.line + 1)
end

def matches?(pattern: String, code: String) -> Bool
  return code.start_with?(pattern.slice(0, pattern.length - 1)) if pattern.end_with?("*")

  code == pattern
end

# Whether the tool of a code ran on the file of the suppression and ended well, so the code, if it matched nothing,
# is stale.
def checked?(ignore: Ignore, code: String, ran: Set[String]) -> Bool
  ran.include?(Baseline.pair(tool_of(code), ignore.file))
end

# The tool of a code or of a prefix; "" for none, which no pair of a run has.
def tool_of(code: String) -> String = Baseline.tool_of(code.replace("*", ""))

# The findings of a suppression with codes that matched nothing (`stale`), each code tracked on its own: one for each
# tool of those codes, so a baseline or a filter by tool sees it.
def unused(ignore: Ignore, stale: List[String]) -> List[Finding]
  stale.map do |code| tool_of(code) end.uniq.map do |tool|
    codes = stale.select do |code| tool_of(code) == tool end
    Finding(code: UNUSED, tool: tool, file: ignore.file, line: ignore.line, column: ignore.column, message: "the suppression of #{codes.join(", ")} matches no finding: #{ignore.reason}")
  end
end
