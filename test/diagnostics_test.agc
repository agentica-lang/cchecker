import Diagnostics from "../src/diagnostics"

def test_gcc_line_with_a_cwe_and_an_option() -> Result[Void]
  found = Diagnostics.parse("a.c:9:12: warning: leak of 'buf' [CWE-401] [-Wanalyzer-malloc-leak]")
  try Test.eq(found.size, 1)
  try Test.eq(found[0].message, "leak of 'buf'")
  try Test.eq(found[0].line, 9)
  try Test.eq(found[0].column, 12)
  return Test.eq(Diagnostics.option(found[0]), some("-Wanalyzer-malloc-leak"))
end

def test_clang_tidy_line_with_a_dotted_check() -> Result[Void]
  found = Diagnostics.parse("/p/a.c:3:5: warning: Attempt to free released memory [clang-analyzer-unix.Malloc]")
  try Test.eq(found[0].file, "/p/a.c")
  return Test.eq(Diagnostics.option(found[0]), some("clang-analyzer-unix.Malloc"))
end

def test_notes_and_source_lines_are_skipped() -> Result[Void]
  text = <<~OUT
    a.c: In function 'f':
    a.c:5:7: warning: leak [-Wanalyzer-malloc-leak]
        5 |   p = malloc(1);
          |       ^~~~~~~~~
    a.c:5:7: note: allocated here
  OUT
  found = Diagnostics.parse(text)
  try Test.eq(found.size, 1)
  return Test.eq(found[0].severity, "warning")
end

def test_an_error_without_a_name_has_no_option() -> Result[Void]
  found = Diagnostics.parse("a.c:1:10: fatal error: nothere.h: No such file or directory")
  try Test.eq(found[0].severity, "fatal error")
  return Test.eq(Diagnostics.option(found[0]), none)
end

def test_brackets_inside_the_message_are_kept() -> Result[Void]
  found = Diagnostics.parse("a.c:2:3: warning: index x[5] is out of bounds [-Warray-bounds]")
  return Test.eq(found[0].message, "index x[5] is out of bounds")
end

def test_a_coloured_diagnostic_is_unparsed_without_its_colours() -> Result[Void]
  esc = String.from_bytes(Bytes.from_list([27]).unwrap!).unwrap!
  text = (
    "a.c:1:2: warning: plain [x]\n#{esc}[1ma.c:2:3: #{esc}[0m#{esc}[0;1;35mwarning: #{esc}[0mcoloured [x]\n    2 | x;"
  )

  try Test.eq(Diagnostics.parse(text).size, 1)
  return Test.eq(Diagnostics.unparsed(text), ["a.c:2:3: warning: coloured [x]"])
end

def test_a_linked_tag_is_unparsed_without_its_links() -> Result[Void]
  esc = String.from_bytes(Bytes.from_list([27]).unwrap!).unwrap!
  bel = String.from_bytes(Bytes.from_list([7]).unwrap!).unwrap!
  text = "a.c:9:12: warning: leak [#{esc}]8;;https://gcc.gnu.org/x#{bel}-Wanalyzer-malloc-leak#{esc}]8;;#{bel}]"
  try Test.eq(Diagnostics.parse(text).size, 0)
  return Test.eq(Diagnostics.unparsed(text), ["a.c:9:12: warning: leak [-Wanalyzer-malloc-leak]"])
end

def test_plain_lines_are_never_unparsed() -> Result[Void]
  text = <<~OUT
    a.c: In function 'f':
    a.c:5:7: warning: leak [-Wanalyzer-malloc-leak]
        5 |   p = malloc(1);
          |       ^~~~~~~~~
    a.c:5:7: note: allocated here
  OUT
  return Test.eq(Diagnostics.unparsed(text), [])
end
