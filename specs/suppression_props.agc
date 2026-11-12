## The property tests of suppressions: a generated file holds CC_SHORT functions that block or not, and ignore comments
## and CC_IGNORE marks in random places, with the right code, a prefix, a wrong code, or no reason. An oracle applies
## the rule of docs/suppressions.md (a trailing comment holds for its line, one alone for its line and the next, a
## CC_IGNORE for its function) and cchecker must agree on the findings left, the findings suppressed, the unused
## suppressions (CC-UNUSED-IGNORE) and the exit code.

import Prop from "pkg/prop/prop"
import Props from "props"

# The kinds of a line.
BLOCKING = 0
CLEAN = 1
ALONE = 2
BLANK = 3
OTHER = 4
CALLER = 5

# What a line of code carries: nothing, a trailing comment, or a CC_IGNORE (on a function only).
NOTHING = 0
TRAILING = 1
MARK = 2

# A reason of this value is left out: a usage error.
NO_REASON = 19

# The codes a suppression names: the finding's, a prefix of it, one of the same tool that never matches here, and two
# codes, of which the second never matches (each code of a suppression is used on its own).
CODES = [
  "CC-EFFECT-SHORT-BLOCKS", "CC-EFFECT-*", "CC-EFFECT-HOT-SYSCALL", "CC-EFFECT-SHORT-BLOCKS, CC-EFFECT-HOT-SYSCALL",
]
SHORT_BLOCKS = "CC-EFFECT-SHORT-BLOCKS"
UNUSED = "CC-UNUSED-IGNORE"

# The compile command of the generated file, in the folder of the scenario under specs/scratch/.
ARGUMENTS = "[\"cc\", \"-I../../../include\", \"-c\", \"case.c\"]"

# The lines before the generated ones.
HEADER = ["#include \"cchecker.h\"", "unsigned int sleep(unsigned int seconds);"]

## A line of the generated file. `kind` is a function that blocks or not, a comment alone, a blank line, an
## unrelated line of code (with more code after a trailing `/* */`), or a function that calls the function before
## it; `attach` what a line of code carries; `code` the index in CODES of the code of its suppression; `reason` is
## NO_REASON for a comment with no reason.
export struct Line
  kind: Int
  code: Int
  attach: Int
  reason: Int
end

# A suppression as the oracle sees it: its line, its codes, and whether it is alone on its line or a CC_IGNORE.
struct Ignore
  line: Int
  codes: List[String]
  alone: Bool
  mark: Bool
end

# What a run gives: the findings (`CODE@LINE`), the suppressed findings (`CODE@LINE`) and the exit code.
struct Outcome
  findings: List[String]
  suppressed: List[String]
  code: Int
end

## The generator of files: up to 8 lines.
export def files() -> Prop.Gen[List[Line]]
  kind_and_code = Prop.pair(Prop.int(0, CALLER), Prop.int(0, CODES.size - 1))
  attach_and_reason = Prop.pair(Prop.int(0, MARK), Prop.int(0, NO_REASON))
  (
    Prop.pair(kind_and_code, attach_and_reason)
    |> Prop.map(&line_of)
    |> Prop.list(8)
  )
end

## Checks `runs` files, from `seed` when it is given, with cchecker (the bytecode `program`, run in specs/ on a compile
## database in `folder`): its findings, suppressed findings and exit code are the oracle's.
export def suppressions_agree(program: String, folder: String, runs: Int, seed: Optional[Int]) -> Result[Void]
  check(program, folder, runs, seed, false)
end

## The negative control: the same files with no function that blocks. Nothing is suppressed, and every suppression
## with a reason is unused.
export def nothing_to_suppress(program: String, folder: String, runs: Int, seed: Optional[Int]) -> Result[Void]
  check(program, folder, runs, seed, true)
end

def check(program: String, folder: String, runs: Int, seed: Optional[Int], clean: Bool) -> Result[Void]
  config = Prop.Config(runs: runs, seed: seed, shrinks: Props.SHRINKS)
  Prop.check(files(), config) do |generated|
    lines = generated
    if clean
      lines = generated.map do |line| without_blocking(line) end
    end

    agrees(program, folder, lines)
  end
end

def line_of(parts: Prop.Pair[Prop.Pair[Int, Int], Prop.Pair[Int, Int]]) -> Line
  Line(kind: parts.first.first, code: parts.first.second, attach: parts.second.first, reason: parts.second.second)
end

def without_blocking(line: Line) -> Line
  return line.with(kind: CLEAN) if line.kind == BLOCKING

  line
end

def agrees(program: String, folder: String, lines: List[Line]) -> Result[Void]
  source = c_file(lines)
  try File.write_text("specs/#{folder}/case.c", source)
  database = "[{\"directory\": \".\", \"file\": \"case.c\", \"arguments\": #{ARGUMENTS}}]"
  try File.write_text("specs/#{folder}/compile_commands.json", database)
  output = try Props.run_with(program, ["--tools", "rules", "--json", "-p", folder])
  expected = oracle(lines)
  if expected.code == 2 or output.code == 2
    return ok() if output.code == expected.code

    return error("expected exit code #{expected.code}, got #{output.code}, in:\n#{source}\n#{output.stderr}")
  end

  got = outcome_of(output)
  if got.findings != expected.findings or got.suppressed != expected.suppressed or got.code != expected.code
    return error("expected #{shown(expected)}, got #{shown(got)}, in:\n#{source}")
  end

  ok()
end

def shown(outcome: Outcome) -> String
  findings = outcome.findings.join(", ")
  "findings [#{findings}], suppressed [#{outcome.suppressed.join(", ")}], exit code #{outcome.code}"
end

# The findings and suppressed findings of cchecker's --json.
def outcome_of(output: Props.Output) -> Outcome
  parsed = JSON.parse(output.stdout).unwrap_or(JSON.from(""))
  Outcome(findings: listed(parsed, "findings"), suppressed: listed(parsed, "suppressed"), code: output.code)
end

def listed(parsed: Json, key: String) -> List[String]
  items: List[Json] = JSON.list(JSON.get(parsed, key).unwrap_or(JSON.from(""))).unwrap_or([])
  named = items.map do |item|
    code = JSON.string(JSON.get(item, "code").unwrap_or(JSON.from(""))).unwrap_or("")
    line = JSON.int(JSON.get(item, "line").unwrap_or(JSON.from(0))).unwrap_or(0)
    "#{code}@#{line}"
  end

  named.sort
end

# The oracle: the rule of docs/suppressions.md applied to the lines.
def oracle(lines: List[Line]) -> Outcome
  ignores: List[Ignore] = []
  blocking: List[Int] = []
  usage = false
  number = HEADER.size
  i = 0
  for line in lines
    number += 1
    code = CODES[line.code]
    if line.kind == BLOCKING or (line.kind == CALLER and calls_blocking?(lines, i))
      blocking = blocking.push(number)
    end

    i += 1

    if line.kind == ALONE
      ignores = ignores.push(Ignore(line: number, codes: code.split(", "), alone: true, mark: false))
      usage = usage or line.reason == NO_REASON
    elsif line.kind != BLANK and line.attach == TRAILING
      ignores = ignores.push(Ignore(line: number, codes: code.split(", "), alone: false, mark: false))
      usage = usage or line.reason == NO_REASON
    elsif function?(line) and line.attach == MARK
      ignores = ignores.push(Ignore(line: number, codes: code.split(", "), alone: false, mark: true))
    end
  end

  return Outcome(findings: [], suppressed: [], code: 2) if usage

  findings: List[String] = []
  suppressed: List[String] = []
  used: List[String] = []
  for at in blocking
    holding = ignores.select do |ignore| holds?(ignore, at) end
    if holding.empty?
      findings = findings.push("#{SHORT_BLOCKS}@#{at}")
    else
      suppressed = suppressed.push("#{SHORT_BLOCKS}@#{at}")
      for ignore in holding
        matching = ignore.codes.select do |code| matches?(code) end
        used = used.concat(matching.map do |code| "#{ignore.line} #{code}" end)
      end
    end
  end

  for ignore in ignores
    if ignore.codes.any? do |code| not used.include?("#{ignore.line} #{code}") end
      findings = findings.push("#{UNUSED}@#{ignore.line}")
    end
  end

  code = 0
  if not findings.empty?
    code = 1
  end

  Outcome(findings: findings.sort, suppressed: suppressed.sort, code: code)
end

# Whether a code matches the finding of a blocking function: it is its code or a prefix of it.
def matches?(code: String) -> Bool
  code == SHORT_BLOCKS or (code.end_with?("*") and SHORT_BLOCKS.start_with?(code.replace("*", "")))
end

# Whether a suppression holds for the finding at line `at`: a code of it matches, and it is on its line or alone on
# the line above.
def holds?(ignore: Ignore, at: Int) -> Bool
  return false if not ignore.codes.any? do |code| matches?(code) end

  at == ignore.line or (ignore.alone and at == ignore.line + 1)
end

def function?(line: Line) -> Bool = line.kind == BLOCKING or line.kind == CLEAN or line.kind == CALLER

# The line a CALLER at `i` calls: the nearest function before it that blocks or not, or -1 for none.
def callee(lines: List[Line], i: Int) -> Int
  j = i - 1
  while j >= 0
    return j if lines[j].kind == BLOCKING or lines[j].kind == CLEAN

    j -= 1
  end

  -1
end

# Whether a CALLER reaches `sleep`: its callee blocks. Its finding is at the caller, apart from the callee's own.
def calls_blocking?(lines: List[Line], i: Int) -> Bool
  j = callee(lines, i)
  j >= 0 and lines[j].kind == BLOCKING
end

# The C file of the lines.
def c_file(lines: List[Line]) -> String
  body: List[String] = []
  i = 0
  for line in lines
    body = body.push(text_of(line, i, callee(lines, i)))
    i += 1
  end

  HEADER.concat(body).join("\n") + "\n"
end

# The text of the line at `i`; `called` is the function a CALLER calls (-1 for none).
def text_of(line: Line, i: Int, called: Int) -> String
  comment = comment_of(line, i)
  if line.kind == ALONE
    return comment
  elsif line.kind == BLANK
    return ""
  end

  code = "static int v#{i} = 0;"
  if line.kind == BLOCKING
    code = "CC_SHORT int f#{i}(void) { return (int)sleep(1); }"
  elsif line.kind == CLEAN
    code = "CC_SHORT int f#{i}(void) { return 0; }"
  elsif line.kind == CALLER and called >= 0
    code = "CC_SHORT int g#{i}(void) { return f#{called}(); }"
  elsif line.kind == CALLER
    code = "CC_SHORT int g#{i}(void) { return 0; }"
  end

  if function?(line) and line.attach == MARK
    return "CC_IGNORE(\"#{CODES[line.code]}\", \"generated\") #{code}"
  elsif line.attach == TRAILING and line.kind == OTHER and i % 2 == 1
    return "#{code} #{comment} static int w#{i} = 0;"
  elsif line.attach == TRAILING
    return "#{code} #{comment}"
  end

  code
end

# A comment that suppresses the code of the line: `/* */` and a line comment (`//`, `///`, `//!`) by turns.
def comment_of(line: Line, i: Int) -> String
  reason = " generated"
  if line.reason == NO_REASON
    reason = ""
  end

  text = "cchecker: ignore #{CODES[line.code]}:#{reason}"
  return "/* #{text} */" if i % 2 == 1

  "#{["//", "///", "//!"][i / 2 % 3]} #{text}"
end
