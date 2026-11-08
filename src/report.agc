## What a run prints.

import {Finding, ToolError} from "findings"
import {Suppressed} from "suppressions"

## The result of a run. `findings` are the new ones; `baselined` were accepted by the baseline, and `fixed` are
## accepted findings of the tools and files of the run that no tool found this time. `skipped` counts the files that
## were left out because they are outside the working directory. `suppressed` are the findings that a suppression took
## out.
export struct Report
  findings: List[Finding]
  baselined: Int
  fixed: Int
  errors: List[ToolError]
  skipped: Int
  suppressed: List[Suppressed] = []
end

# The JSON form of a report, which says in `clean` whether the run is clean.
struct Encoded
  clean: Bool
  findings: List[Finding]
  baselined: Int
  fixed: Int
  errors: List[ToolError]
  skipped: Int
  suppressed: List[Suppressed]
end

## Returns the report for people: one line for each finding, then a summary line.
export def text(report: Report) -> String
  lines = report.findings.map do |f| "#{f.file}:#{f.line}:#{f.column} #{f.code} #{f.message}#{path_text(f)}" end
  return lines.push(summary(report)).join("\n")
end

## Returns the report as one JSON object for tools and agents.
export def json(report: Report) -> String
  return JSON.encode(
    Encoded(
      clean: report.findings.empty? and report.errors.empty?,
      findings: report.findings,
      baselined: report.baselined,
      fixed: report.fixed,
      errors: report.errors,
      skipped: report.skipped,
      suppressed: report.suppressed,
    ),
  )
end

## Returns the lines for standard error: one for each tool error.
export def error_lines(report: Report) -> List[String]
  return report.errors.map do |e| "cchecker: error: #{e.tool} on #{e.file}: #{e.message}" end
end

# The call path of a finding of the rules, which the message leaves out.
def path_text(f: Finding) -> String
  if f.path.empty?
    return ""
  end

  return ": #{f.path.join(" -> ")}"
end

def summary(report: Report) -> String
  count = report.findings.size
  files = report.findings.map do |f| f.file end.uniq.size
  notes: List[String] = []
  if report.baselined > 0
    notes = notes.push("#{report.baselined} baselined")
  end

  if report.fixed > 0
    notes = notes.push("#{report.fixed} fixed since the baseline")
  end

  if not report.suppressed.empty?
    notes = notes.push("#{report.suppressed.size} suppressed")
  end

  tail = ""
  if not notes.empty?
    tail = " (#{notes.join(", ")})"
  end

  if count == 0 and not report.errors.empty?
    return (
      "cchecker: #{report.errors.size} tool #{plural(report.errors.size, "error")}, the findings are incomplete#{tail}"
    )
  end

  if count == 0
    return "cchecker: no new findings#{tail}"
  end

  return "cchecker: #{count} new #{plural(count, "finding")} in #{files} #{plural(files, "file")}#{tail}"
end

def plural(n: Int, word: String) -> String
  if n == 1
    return word
  end

  return word + "s"
end
