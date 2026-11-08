import Baseline from "../src/baseline"
import Findings from "../src/findings"
import {Finding} from "../src/findings"

def leak(line: Int) -> Finding
  return Finding(code: "CC-GCC-X", tool: "gcc", file: "a.c", line: line, column: 3, message: "leak of 'p'")
end

def accepted(count: Int) -> Map[String, Int]
  return {Findings.baseline_key(leak(1)): count}
end

def test_a_finding_matches_at_any_line() -> Result[Void]
  split = Baseline.split([leak(40)], accepted(1))
  try Test.eq(split.new_findings, [])
  return Test.eq(split.accepted, 1)
end

def test_only_as_many_findings_as_the_baseline_holds_are_accepted() -> Result[Void]
  split = Baseline.split([leak(10), leak(20), leak(30)], accepted(2))
  try Test.eq(split.new_findings.map do |f| f.line end, [30])
  return Test.eq(split.accepted, 2)
end

def test_accepted_findings_not_found_again_are_fixed() -> Result[Void]
  split = Baseline.split([], accepted(3))
  return Test.eq(split.fixed, 3)
end
