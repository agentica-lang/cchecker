## Reading the diagnostics of gcc and clang-tidy, which print `file:line:column: severity: message [tag]` lines.

import Regex from "std/regex"

HEADER = /^(.+?):(\d+):(\d+): (warning|error|fatal error|note): (.*)$/
TAG = /^(.*) \[([-\w.=,+]+)\]$/
# A diagnostic line as far as its severity, which `unparsed` looks for once the escape sequences are out.
LOOSE = /^(.+?):(\d+):(\d+): (warning|error|fatal error|note):/
# The escape sequences of a terminal: colours (`ESC[0;1;35m`) and the links of OSC 8 (`ESC]8;;URL BEL`, which gcc
# prints around a tag with `-fdiagnostics-urls=always`), ended by BEL or by `ESC\`.
ESCAPE = /\x1B\[[0-9;]*[A-Za-z]|\x1B\]8;[^\x07\x1B]*(?:\x07|\x1B\\)/

## One diagnostic line. `tags` are the bracketed names at the end of the message: `[CWE-401] [-Wanalyzer-malloc-leak]`
## for gcc, `[clang-analyzer-unix.Malloc]` for clang-tidy.
export struct Diagnostic
  file: String
  line: Int
  column: Int
  severity: String
  message: String
  tags: List[String]
end

# A message without its tags, and the tags.
struct Tagged
  message: String
  tags: List[String]
end

## Returns the diagnostics of a tool's output, in order. The notes, the source lines and the carets are skipped, and
## so are the lines with an escape sequence, which `unparsed` returns.
export def parse(text: String) -> List[Diagnostic]
  esc = escape_char()
  found: List[Diagnostic] = []
  for line in text.split("\n")
    next if line.include?(esc)

    case Regex.match(line, HEADER)
      ok(m) -> found = found.push(build(m))
      error(_) -> next
    end
  end

  found.select do |d| d.severity != "note" end
end

## Returns the lines of a tool's output that look like a diagnostic but that `parse` does not read: a line with an
## escape sequence (a tool that prints colours or links), without its escape sequences, or a line that does not have
## the whole form. A finding in such a line would be lost without a word, so the caller makes them a tool error.
export def unparsed(text: String) -> List[String]
  esc = escape_char()
  found: List[String] = []
  for line in text.split("\n")
    if line.include?(esc)
      plain = Regex.replace(line, ESCAPE, "").unwrap_or(line)
      if Regex.match?(plain, LOOSE)
        found = found.push(plain)
      end
    elsif Regex.match?(line, LOOSE) and not Regex.match?(line, HEADER)
      found = found.push(line)
    end
  end

  found
end

## Returns the option name of a diagnostic: the first tag that is not a CWE number, or none.
export def option(d: Diagnostic) -> Optional[String]
  names = d.tags.select do |tag| not tag.start_with?("CWE-") end
  return none if names.empty?

  some(names.first.split(",").first)
end

# The escape character, ESC, which starts every escape sequence of a terminal.
def escape_char() -> String = String.from_bytes(Bytes.from_list([27]).unwrap!).unwrap!

def build(m: Regex.Match) -> Diagnostic
  tagged = split_tags(m.groups[5].text.strip, [])
  Diagnostic(
    file: m.groups[1].text,
    line: m.groups[2].text.to_i.unwrap_or(0),
    column: m.groups[3].text.to_i.unwrap_or(0),
    severity: m.groups[4].text,
    message: tagged.message,
    tags: tagged.tags,
  )
end

# Takes the bracketed names off the end of the message, last one first, so the tags keep their order in the line.
def split_tags(message: String, tags: List[String]) -> Tagged
  case Regex.match(message, TAG)
    ok(m) -> split_tags(m.groups[1].text, [m.groups[2].text].concat(tags))
    error(_) -> Tagged(message: message, tags: tags)
  end
end
