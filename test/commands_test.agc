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

def test_a_file_listed_again_for_a_shared_library_is_folded() -> Result[Void]
  entries = [
    Commands.Entry(directory: "/p", file: "x.c", args: ["-DA", "-I."]),
    Commands.Entry(directory: "/p", file: "./x.c", args: ["-DA", "-Dx_EXPORTS", "-I.", "-fPIC"]),
    Commands.Entry(directory: "/p", file: "x.c", args: ["-DA", "-Iother"]),
  ]

  folded = Commands.fold(entries, [])
  try Test.eq(folded.folded, 1)
  return Test.eq(folded.entries.map do |e| e.args end, [["-DA", "-I."], ["-DA", "-Iother"]])
end

def test_entries_that_may_find_other_things_are_not_folded() -> Result[Void]
  entries = [
    Commands.Entry(directory: "/p", file: "/p/x.c", args: ["-I."]),
    # Another folder: `-I.` names another folder.
    Commands.Entry(directory: "/q", file: "/p/x.c", args: ["-I."]),
    # A value for the define: code may read it.
    Commands.Entry(directory: "/p", file: "/p/x.c", args: ["-I.", "-Dfoo_EXPORTS=1"]),
    # One word of `arguments` with a space is not the two words of a `command`.
    Commands.Entry(directory: "/p", file: "/p/x.c", args: ["-DA B"]),
    Commands.Entry(directory: "/p", file: "/p/x.c", args: ["-DA", "B"]),
  ]

  return Test.eq(Commands.fold(entries, []).folded, 0)
end

def test_the_defines_named_in_the_setting_do_not_tell_entries_apart() -> Result[Void]
  entries = [
    Commands.Entry(directory: "/p", file: "x.c", args: ["-DA", "-I."]),
    Commands.Entry(directory: "/p", file: "x.c", args: ["-DA", "-DSHARED=1", "-I."]),
    Commands.Entry(directory: "/p", file: "x.c", args: ["-DSHARED", "-DA", "-I."]),
    Commands.Entry(directory: "/p", file: "x.c", args: ["-D", "SHARED=2", "-DA", "-I."]),
    # Another define, or a name that only starts with the listed one, still tells the entry apart.
    Commands.Entry(directory: "/p", file: "x.c", args: ["-DA", "-DB", "-DSHARED", "-I."]),
    Commands.Entry(directory: "/p", file: "x.c", args: ["-DA", "-DSHARED_MORE", "-I."]),
    Commands.Entry(directory: "/p", file: "x.c", args: ["-D", "OTHER", "-DA", "-I."]),
  ]

  folded = Commands.fold(entries, ["SHARED"])
  try Test.eq(folded.folded, 3)
  return Test.eq(folded.entries.size, 4)
end
