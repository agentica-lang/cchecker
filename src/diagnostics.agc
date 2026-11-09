## Reading the diagnostics of gcc and clang-tidy, which print `file:line:column: severity: message [tag]` lines.

import Regex from "std/regex"

HEADER = /^(.+?):(\d+):(\d+): (warning|error|fatal error|note): (.*)$/
TAG = /^(.*) \[([-\w.=,+]+)\]$/
# A diagnostic line as far as its severity, which `unparsed` looks for once the colours are out.
LOOSE = /^(.+?):(\d+):(\d+): (warning|error|fatal error|note):/
# An escape sequence of a terminal, such as the colours `ESC[1m` and `ESC[0;1;35m`.
ESCAPE = /\x1B\[[0-9;]*[A-Za-z]/

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

## Returns the diagnostics of a tool's output, in order. The notes, the source lines and the carets are skipped.
export def parse(text: String) -> List[Diagnostic]
  found: List[Diagnostic] = []
  for line in text.split("\n")
    case Regex.match(line, HEADER)
      ok(m) -> found = found.push(build(m))
      error(_) -> next
    end
  end

  return found.select do |d| d.severity != "note" end
end

## Returns the lines of a tool's output that look like a diagnostic once the escape sequences are out, but that
## `parse` does not read (a tool that prints colours), without their escape sequences. A finding in such a line would
## be lost without a word, so the caller makes them a tool error.
export def unparsed(text: String) -> List[String]
  found: List[String] = []
  for line in text.split("\n")
    if not Regex.match(line, HEADER).ok?
      plain = Regex.replace(line, ESCAPE, "").unwrap_or(line)
      if Regex.match(plain, LOOSE).ok?
        found = found.push(plain)
      end
    end
  end

  return found
end

## Returns the option name of a diagnostic: the first tag that is not a CWE number, or none.
export def option(d: Diagnostic) -> Optional[String]
  names = d.tags.select do |tag| not tag.start_with?("CWE-") end
  if names.empty?
    return none
  end

  return some(names.first.split(",").first)
end

def build(m: Regex.Match) -> Diagnostic
  tagged = split_tags(m.groups[5].text.strip, [])
  return Diagnostic(
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
    ok(m) -> return split_tags(m.groups[1].text, [m.groups[2].text].concat(tags))
    error(_) -> return Tagged(message: message, tags: tags)
  end
end
