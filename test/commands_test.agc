import Commands from "../src/commands"

def test_words_split_at_spaces_and_keep_quotes_together() -> Result[Void]
  words = Commands.split_words("cc -DNAME=\"two words\" -I'a b' -c x.c")
  return Test.eq(words, ["cc", "-DNAME=two words", "-Ia b", "-c", "x.c"])
end

def test_a_backslash_escapes_the_next_character() -> Result[Void]
  return Test.eq(Commands.split_words("cc -DV=\\\"x\\\" a\\ b.c"), ["cc", "-DV=\"x\"", "a b.c"])
end

def test_flags_leave_out_the_compiler_the_file_and_the_outputs() -> Result[Void]
  words = ["cc", "-I.", "-MD", "-MF", "x.d", "-o", "x.o", "-c", "x.c", "-DA=1"]
  return Test.eq(Commands.flags_of(words, "/p/x.c", "/p"), ["-I.", "-DA=1"])
end

def test_the_source_file_is_left_out_however_it_is_spelled() -> Result[Void]
  words = ["cc", "-c", "./src/../a.c", "-DA=1", "b.c"]
  return Test.eq(Commands.flags_of(words, "/p/a.c", "/p"), ["-DA=1", "b.c"])
end
