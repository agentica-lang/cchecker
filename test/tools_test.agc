import Tools from "../src/tools"
import {Tool} from "../src/tool_kind"

def test_a_gcc_option_is_the_code() -> Result[Void]
  return Test.eq(Tools.code_of(Tool.Gcc, some("-Wanalyzer-malloc-leak")), "CC-GCC-ANALYZER-MALLOC-LEAK")
end

def test_werror_does_not_change_the_code() -> Result[Void]
  try Test.eq(Tools.code_of(Tool.Gcc, some("-Werror=analyzer-malloc-leak")), "CC-GCC-ANALYZER-MALLOC-LEAK")
  return Test.eq(Tools.code_of(Tool.Gcc, some("-Wno-error=analyzer-malloc-leak")), "CC-GCC-ANALYZER-MALLOC-LEAK")
end

def test_a_gcc_diagnostic_without_a_name_has_a_code() -> Result[Void]
  return Test.eq(Tools.code_of(Tool.Gcc, none), "CC-GCC-WARNING")
end

def test_a_check_of_clang_tidy_is_the_code() -> Result[Void]
  try Test.eq(Tools.code_of(Tool.ClangTidy, some("clang-analyzer-unix.Malloc")), "CC-TIDY-CLANG-ANALYZER-UNIX-MALLOC")
  return Test.eq(Tools.code_of(Tool.ClangTidy, none), "CC-TIDY-WARNING")
end

def test_a_stop_by_timeout_is_not_told_as_a_plain_exit() -> Result[Void]
  try Test.assert(Tools.failure(true, 5, "", 124) != Tools.failure(false, 5, "", 124), "124")
  return Test.assert(Tools.failure(true, 5, "", 137) != Tools.failure(false, 5, "", 137), "137")
end

def test_a_kill_is_not_told_as_a_timeout() -> Result[Void]
  return Test.assert(Tools.failure(true, 5, "", 137) != Tools.failure(true, 5, "", 124), "137 and 124")
end

def test_the_reason_of_a_killed_cc1_is_the_fatal_error() -> Result[Void]
  text = (
    "a.c:1:1: error: leak of 'p' [-Werror=analyzer-malloc-leak]\n" +
    "gcc: fatal error: Killed signal terminated program cc1\ncompilation terminated.\n"
  )

  return Test.eq(Tools.first_line(text), "gcc: fatal error: Killed signal terminated program cc1")
end

def test_the_reason_without_a_fatal_error_is_the_first_error() -> Result[Void]
  text = "In function 'f':\na.c:3:5: error: unknown name 'x'\na.c:4:5: error: unknown name 'y'\n"
  return Test.eq(Tools.first_line(text), "a.c:3:5: error: unknown name 'x'")
end
