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
