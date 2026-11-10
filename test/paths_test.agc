import Paths from "../src/paths"

def test_a_path_inside_the_folder_is_relative() -> Result[Void]
  Test.eq(Paths.inside("/p/proj", "/p/proj/src/a.c"), some("src/a.c"))
end

def test_a_path_outside_the_folder_is_dropped() -> Result[Void]
  try Test.eq(Paths.inside("/p/proj", "/usr/include/stdio.h"), none)
  Test.eq(Paths.inside("/p/proj", "/p/project/a.c"), none)
end

def test_dots_are_taken_out_of_an_absolute_path() -> Result[Void]
  Test.eq(Paths.absolute("/p/proj", "../other/./a.c"), ok("/p/other/a.c"))
end

def test_an_exclusion_is_a_file_or_a_folder() -> Result[Void]
  try Test.assert(Paths.excluded?("/p/proj", "src/a.c", ["src"]), "folder")
  try Test.assert(Paths.excluded?("/p/proj", "src/a.c", ["src/a.c"]), "file")
  try Test.assert(Paths.excluded?("/p/proj", "src/a.c", ["other", "src/"]), "trailing slash")
  Test.assert(Paths.excluded?("/p/proj", "src/a.c", ["."]), "the folder itself")
end

def test_an_exclusion_may_be_written_with_dots_or_absolute() -> Result[Void]
  try Test.assert(Paths.excluded?("/p/proj", "src/a.c", ["./src"]), "dot")
  try Test.assert(Paths.excluded?("/p/proj", "src/a.c", ["x/../src"]), "dot dot")
  Test.assert(Paths.excluded?("/p/proj", "src/a.c", ["/p/proj/src"]), "absolute")
end

def test_an_exclusion_never_matches_a_part_of_a_name() -> Result[Void]
  try Test.assert(not Paths.excluded?("/p/proj", "src/a.c", ["sr"]), "folder prefix")
  try Test.assert(not Paths.excluded?("/p/proj", "src/a.c", ["src/a"]), "file prefix")
  Test.assert(not Paths.excluded?("/p/proj", "src/a.c", ["/p/other/src"]), "another tree")
end
