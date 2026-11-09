import Baseline from "../src/baseline"
import {Finding} from "../src/findings"

def leak(file: String, line: Int) -> Finding
  return Finding(code: "CC-GCC-X", tool: "gcc", file: file, line: line, column: 3, message: "leak of 'p'")
end

def entry(file: String, count: Int) -> Baseline.Entry
  return Baseline.Entry(code: "CC-GCC-X", file: file, message: "leak of 'p'", count: count)
end

def everything() -> Baseline.Scope
  return Baseline.Scope(tools: Set.new(["gcc", "clang-tidy"]), pairs: Set.new([]), full: true)
end

# A run of gcc on these files, all of which ended well.
def files(names: List[String]) -> Baseline.Scope
  pairs = names.map do |name| Baseline.pair("gcc", name) end
  return Baseline.Scope(tools: Set.new(["gcc"]), pairs: Set.new(pairs), full: false)
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

def test_a_header_entry_of_a_partial_update_keeps_the_larger_count() -> Result[Void]
  more = Baseline.merged([entry("shared.h", 1)], files(["a.c"]), [leak("shared.h", 7), leak("shared.h", 9)])
  try Test.eq(more, [entry("shared.h", 2)])
  less = Baseline.merged([entry("shared.h", 3)], files(["a.c"]), [leak("shared.h", 7)])
  return Test.eq(less, [entry("shared.h", 3)])
end

def test_a_header_entry_is_not_fixed_by_a_partial_run() -> Result[Void]
  return Test.eq(Baseline.split([], [entry("shared.h", 2)], files(["a.c"])).fixed, 0)
end

def test_what_is_rendered_reads_back_with_its_versions() -> Result[Void]
  versions = {"clang": "clang 19", "gcc": "gcc 14"}
  loaded = try Baseline.parse("base.json", Baseline.render([entry("a.c", 2)], versions))
  try Test.eq(loaded.entries, [entry("a.c", 2)])
  return Test.eq(loaded.tools, versions)
end

def test_a_baseline_without_versions_reads_with_none() -> Result[Void]
  loaded = try Baseline.parse("base.json", "{\"version\": 1, \"findings\": []}")
  return Test.eq(loaded.tools.size, 0)
end

def test_only_a_tool_in_both_with_another_version_is_a_change() -> Result[Void]
  stored = {"clang": "clang 19", "gcc": "gcc 13", "clang-tidy": "tidy 19"}
  current = {"gcc": "gcc 14", "clang-tidy": "tidy 19", "other": "x"}
  return Test.eq(
    Baseline.changes(stored, current),
    [Baseline.VersionChange(tool: "gcc", baseline: "gcc 13", current: "gcc 14")],
  )
end

def test_a_version_is_compared_by_its_number() -> Result[Void]
  debian = {"gcc": "gcc (Debian 14.2.0-19) 14.2.0"}
  try Test.eq(Baseline.changes(debian, {"gcc": "gcc (Ubuntu 14.2.0-4ubuntu2) 14.2.0"}), [])
  later = "gcc (Debian 14.3.0-1) 14.3.0"
  try Test.eq(Baseline.changes(debian, {"gcc": later}).map do |c| c.current end, [later])
  return Test.eq(Baseline.changes({"gcc": "tip"}, {"gcc": "tip of tree"}).size, 1)
end

def test_an_update_of_every_file_replaces_the_versions_of_the_tools_that_ran() -> Result[Void]
  stored = {"gcc": "gcc 13", "clang": "clang 19", "clang-tidy": "tidy 19"}
  merged = Baseline.updated_tools(stored, {"gcc": "gcc 14"}, ["gcc", "clang-tidy"], true)
  return Test.eq(merged, {"clang": "clang 19", "gcc": "gcc 14"})
end

def test_an_update_of_some_files_keeps_the_stored_versions() -> Result[Void]
  stored = {"gcc": "gcc 13"}
  try Test.eq(Baseline.updated_tools(stored, {"gcc": "gcc 14", "clang": "clang 19"}, ["gcc", "clang"], false), stored)
  return Test.eq(Baseline.updated_tools({}, {"gcc": "gcc 14"}, ["gcc"], false).size, 0)
end
