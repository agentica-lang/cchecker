import Suppressions from "../src/suppressions"

LEAK = "CC-GCC-ANALYZER-MALLOC-LEAK"

# The line, the codes and whether it is alone, of each suppression of a text, or the error.
def read(text: String) -> Result[List[String]]
  ignores = try Suppressions.in_text("a.c", text)
  return ok(ignores.map do |ignore| "#{ignore.line} #{ignore.codes.join(",")} #{ignore.alone}" end)
end

def usage_error?(text: String) -> Bool
  return not Suppressions.in_text("a.c", text).ok?
end

def test_doc_comment_openers_hold_a_suppression() -> Result[Void]
  text = "/// cchecker: ignore #{LEAK}: doc\nint a;\n//! cchecker: ignore #{LEAK}: inner doc\n"
  return Test.eq(try read(text), ["1 #{LEAK} true", "3 #{LEAK} true"])
end

def test_codes_split_on_tabs_as_on_spaces() -> Result[Void]
  text = "int a; // cchecker: ignore CC-GCC-ANALYZER-*,\tCC-TIDY-X: a tab after the comma\n"
  return Test.eq(try read(text), ["1 CC-GCC-ANALYZER-*,CC-TIDY-X false"])
end

def test_a_word_that_only_starts_with_ignore_is_a_usage_error() -> Result[Void]
  try Test.assert(usage_error?("// cchecker: ignore: a reason\n"), "ignore:")
  try Test.assert(usage_error?("// cchecker: ignore,#{LEAK}: a reason\n"), "ignore,")
  return Test.assert(usage_error?("// cchecker: ignored #{LEAK}: a reason\n"), "ignored")
end

def test_a_star_inside_a_code_or_the_unused_code_is_a_usage_error() -> Result[Void]
  try Test.assert(usage_error?("// cchecker: ignore CC-GCC-*-LEAK: a reason\n"), "a star inside")
  return Test.assert(usage_error?("// cchecker: ignore CC-UNUSED-IGNORE: a reason\n"), "CC-UNUSED-IGNORE")
end

def test_quotes_in_literals_do_not_hide_a_trailing_comment() -> Result[Void]
  text = [
    "char q = '\"'; // cchecker: ignore #{LEAK}: a quote in a char",
    "char *s = \"a \\\" b\"; // cchecker: ignore #{LEAK}: an escaped quote",
    "char c = '\\''; // cchecker: ignore #{LEAK}: an escaped char",
    "int n = 1'000'000; // cchecker: ignore #{LEAK}: digit separators",
    "long h = 0xff'ff; // cchecker: ignore #{LEAK}: hex separators",
    "char w = L'x'; // cchecker: ignore #{LEAK}: a wide char",
  ].join("\n")

  return Test.eq((try read(text)).size, 6)
end

def test_an_error_directive_opens_no_literal() -> Result[Void]
  text = "#error it's not built here // cchecker: ignore #{LEAK}: in the directive\n"
  return Test.eq(try read(text), ["1 #{LEAK} false"])
end

def test_a_block_comment_carries_across_lines_and_hides_what_is_inside() -> Result[Void]
  text = "/* a block \"with a quote\n   // cchecker: ignore #{LEAK}: inside the block */\nint a;\n"
  inside = try read(text)
  try Test.eq(inside, ["2 #{LEAK} true"])
  quoted = "/* \" */ int a; // cchecker: ignore #{LEAK}: after a block with a quote\n"
  return Test.eq(try read(quoted), ["1 #{LEAK} false"])
end

def test_the_marker_in_a_string_or_a_mention_is_no_suppression() -> Result[Void]
  text = "puts(\"// cchecker: ignore #{LEAK}: in a string\");\n/* see cchecker: ignore #{LEAK}: a mention */\n"
  return Test.eq(try read(text), [])
end

def test_of_mark_reads_a_cc_ignore_and_leaves_other_marks() -> Result[Void]
  found = try Suppressions.of_mark("a.c", 3, 5, "ignore(CC-EFFECT-SHORT-BLOCKS: warm)")
  try Test.eq(found.map do |ignore| ignore.codes end, some(["CC-EFFECT-SHORT-BLOCKS"]))
  other = try Suppressions.of_mark("a.c", 3, 5, "cc_short")
  try Test.assert(not other.some?, "a mark of another kind")
  return Test.assert(not Suppressions.of_mark("a.c", 3, 5, "ignore(CC-EFFECT-SHORT-BLOCKS: )").ok?, "no reason")
end
