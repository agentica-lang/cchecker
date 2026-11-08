import Findings from "../src/findings"
import {Finding} from "../src/findings"

def at(file: String, line: Int, column: Int, code: String) -> Finding
  return Finding(code: code, tool: "gcc", file: file, line: line, column: column, message: "m")
end

def test_findings_sort_by_file_then_numeric_line_then_column() -> Result[Void]
  sorted = Findings.sort([at("b.c", 2, 1, "X"), at("a.c", 10, 2, "X"), at("a.c", 9, 7, "X"), at("a.c", 10, 1, "X")])
  places = sorted.map do |f| "#{f.file}:#{f.line}:#{f.column}" end
  return Test.eq(places, ["a.c:9:7", "a.c:10:1", "a.c:10:2", "b.c:2:1"])
end

def test_a_finding_repeated_at_one_place_is_kept_once() -> Result[Void]
  kept = Findings.unique([at("a.c", 1, 1, "X"), at("a.c", 1, 1, "X"), at("a.c", 1, 1, "Y"), at("a.c", 2, 1, "X")])
  return Test.eq(kept.size, 3)
end
