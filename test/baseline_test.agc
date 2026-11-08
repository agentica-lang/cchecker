import Baseline from "../src/baseline"
import {Finding} from "../src/findings"

def leak(file: String, line: Int) -> Finding
  return Finding(code: "CC-GCC-X", tool: "gcc", file: file, line: line, column: 3, message: "leak of 'p'")
end

def entry(file: String, count: Int) -> Baseline.Entry
  return Baseline.Entry(code: "CC-GCC-X", file: file, message: "leak of 'p'", count: count)
end

def everything() -> Baseline.Scope
  return Baseline.Scope(tools: Set.new(["gcc", "clang-tidy"]), files: Set.new([]), full: true)
end

def files(names: List[String]) -> Baseline.Scope
  return Baseline.Scope(tools: Set.new(["gcc"]), files: Set.new(names), full: false)
end

def test_a_finding_matches_at_any_line() -> Result[Void]
  split = Baseline.split([leak("a.c", 40)], [entry("a.c", 1)], everything())
  try Test.eq(split.new_findings, [])
  return Test.eq(split.accepted, 1)
end

def test_only_as_many_findings_as_the_baseline_holds_are_accepted() -> Result[Void]
  split = Baseline.split([leak("a.c", 10), leak("a.c", 20), leak("a.c", 30)], [entry("a.c", 2)], everything())
  try Test.eq(split.new_findings.map do |f| f.line end, [30])
  return Test.eq(split.accepted, 2)
end

def test_accepted_findings_not_found_again_are_fixed() -> Result[Void]
  return Test.eq(Baseline.split([], [entry("a.c", 3)], everything()).fixed, 3)
end

def test_entries_of_files_that_did_not_run_are_not_fixed() -> Result[Void]
  split = Baseline.split([], [entry("a.c", 1), entry("b.c", 2)], files(["a.c"]))
  return Test.eq(split.fixed, 1)
end

def test_entries_of_a_tool_that_did_not_run_are_not_fixed() -> Result[Void]
  other = Baseline.Entry(code: "CC-TIDY-X", file: "a.c", message: "m", count: 5)
  return Test.eq(Baseline.split([], [entry("a.c", 1), other], files(["a.c"])).fixed, 1)
end

def test_a_full_run_covers_the_headers_too() -> Result[Void]
  return Test.eq(Baseline.split([], [entry("shared.h", 1)], everything()).fixed, 1)
end

def test_an_update_keeps_the_entries_out_of_scope_and_replaces_the_others() -> Result[Void]
  kept = Baseline.merged([entry("a.c", 4), entry("b.c", 2)], files(["a.c"]), [leak("a.c", 7)])
  return Test.eq(kept, [entry("a.c", 1), entry("b.c", 2)])
end

def test_an_update_of_a_full_run_replaces_everything_of_its_tools() -> Result[Void]
  other = Baseline.Entry(code: "CC-TIDY-X", file: "a.c", message: "m", count: 5)
  kept = Baseline.merged([entry("old.h", 4), other], everything(), [leak("a.c", 7)])
  return Test.eq(kept, [entry("a.c", 1)])
end

def test_a_count_below_one_is_a_baseline_error() -> Result[Void]
  text = (
    "{\"version\": 1, \"findings\": [{\"code\": \"CC-GCC-X\", \"file\": \"a.c\", \"message\": \"m\", \"count\": -2}]}"
  )

  return Test.error?(Baseline.parse("base.json", text))
end

def test_a_baseline_of_another_version_is_a_baseline_error() -> Result[Void]
  return Test.error?(Baseline.parse("base.json", "{\"version\": 2, \"findings\": []}"))
end
