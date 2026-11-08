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
