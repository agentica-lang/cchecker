import Paths from "../src/paths"

def test_a_path_inside_the_folder_is_relative() -> Result[Void]
  return Test.eq(Paths.inside("/p/proj", "/p/proj/src/a.c"), some("src/a.c"))
end

def test_a_path_outside_the_folder_is_dropped() -> Result[Void]
  try Test.eq(Paths.inside("/p/proj", "/usr/include/stdio.h"), none)
  return Test.eq(Paths.inside("/p/proj", "/p/project/a.c"), none)
end

def test_dots_are_taken_out_of_an_absolute_path() -> Result[Void]
  return Test.eq(Paths.absolute("/p/proj", "../other/./a.c"), ok("/p/other/a.c"))
end
