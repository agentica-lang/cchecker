import {UnresolvedCallback} from "../src/findings"
import Report from "../src/report"

def test_the_first_unresolved_callback_shown_is_one_inside_the_working_directory() -> Result[Void]
  outside = UnresolvedCallback(call: "uv_timer_start", argument: 1, file: "/usr/include/x.inc", line: 1)
  inside = UnresolvedCallback(call: "uv_close", argument: 1, file: "src/a.c", line: 9)
  report = Report.Report(
    findings: [],
    baselined: 0,
    fixed: 0,
    errors: [],
    skipped: 0,
    unresolved_callbacks: [outside, inside],
  )

  line = Report.unresolved_line(report).unwrap_or("")
  return Test.assert(line.include?("first: uv_close at src/a.c:9"), line)
end
