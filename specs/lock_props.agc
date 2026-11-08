## The property tests of the lock walk: a generated function takes and releases one lock `m` under if/else, loops with
## break and continue, a switch with fallthrough, early returns and a goto to a cleanup label, all on conditions that
## cchecker cannot know. An oracle runs the function over all its paths, and its result is compared with cchecker's.

import Prop from "pkg/prop/prop"
import Props from "props"

# The tokens of a program: a list of them is read as a structured function (`program_of`), so any list is one, and a
# shorter list a smaller function. A way out (`return`, `goto out`, `break`, `continue`) is taken under a condition of
# its own, so the code after it is not dead. A token that does not fit where it is (an `else` outside an `if`, a
# `break` outside a loop or a switch) is left out.
LOCK = 0
UNLOCK = 1
WORK = 2
IF = 3
ELSE = 4
END = 5
WHILE = 6
BREAK = 7
CONTINUE = 8
RETURN = 9
GOTO = 10
SWITCH = 11
CASE = 12

# The tokens a body is drawn from, the lock calls and the blocks more often than the ways out. A token shrinks toward
# the first, a lock.
DRAWN = [
  LOCK, LOCK, LOCK, UNLOCK, UNLOCK, UNLOCK, WORK, IF, IF, ELSE, END, END, END, WHILE, SWITCH, CASE, CASE, BREAK,
  CONTINUE, RETURN, GOTO,
]

# The counts of the lock that cchecker keeps exactly: it counts a lock taken more often as taken this many times
# (MAX_COUNT of src/locking.agc), a documented limit.
EXACT = 2

# The counts the oracle follows when it looks for any path; a path that goes past it is not followed.
WIDE = 6

# The codes of the two lock rules.
NOT_RELEASED = "CC-PATH-LOCK-NOT-RELEASED"
NOT_HELD = "CC-PATH-LOCK-NOT-HELD"

## A statement of a generated function. `kind` is the token that made it; `id` numbers its condition (`pick(id)`), so
## that no two conditions are the same; `body` is the then branch or the loop body, `other` the else branch, `cases`
## the cases of a switch in order.
export struct Stmt
  kind: Int
  id: Int = 0
  body: List[Stmt] = []
  other: List[Stmt] = []
  cases: List[List[Stmt]] = []
end

## A generated function: its body, and what runs after the label `out:` that `goto out` reaches.
export struct Program
  body: List[Stmt]
  cleanup: List[Stmt]
end

# The statements of a block, the token after it and the token that ended it (-1 for the end of the list).
struct Parsed
  stmts: List[Stmt]
  at: Int
  stop: Int
end

# Where each way out of a piece of code goes: the counts of the lock on the paths that go on, break, continue, return
# or jump to `out`, and the largest count (in absolute value) that any path reached.
struct Flow
  normal: List[Int] = []
  brk: List[Int] = []
  cont: List[Int] = []
  ret: List[Int] = []
  jump: List[Int] = []
  peak: Int = 0
end

## The generator of functions: up to 24 tokens of the body and 3 of the cleanup (lock, unlock or work).
export def programs() -> Prop.Gen[Program]
  tokens = Prop.pair(Prop.list(Prop.one_of(DRAWN), 24), Prop.list(Prop.int(0, WORK), 3))
  return Prop.map(tokens, &program_of)
end

## Checks `runs` functions, from `seed` when it is given, with cchecker (the bytecode `program`, run in specs/). Every
## rule that a path within the exact counts breaks is reported (no false negative), and every finding is one that some
## path breaks, unless a path counts the lock past what cchecker keeps exactly (the documented limit).
export def walk_agrees(program: String, folder: String, runs: Int, seed: Optional[Int]) -> Result[Void]
  config = Prop.Config(runs: runs, seed: seed, shrinks: Props.SHRINKS)
  return Prop.check(programs(), config) do |generated|
    source = c_file(generated)
    agrees(Props.run(program, folder, source), generated, source)
  end
end

## The C file of a generated function: `f` with the label `out:` before its cleanup.
export def c_file(generated: Program) -> String
  head = ["#include <pthread.h>", "", "pthread_mutex_t m;", "int pick(int k);", "void work(void);", "int f(void) {"]
  lines = head.concat(lines_of(generated.body, 1)).push("out:").concat(lines_of(generated.cleanup, 1))
  return lines.push("  return 0;").push("}").join("\n") + "\n"
end

def program_of(tokens: Prop.Pair[List[Int], List[Int]]) -> Program
  body = block(tokens.first, 0, false, false, [])
  cleanup = block(tokens.second, 0, false, false, [])
  return Program(body: body.stmts, cleanup: cleanup.stmts)
end

# Reads statements from `at` to a token of `stops`. `loop` says whether a `continue` fits, `breakable` a `break`.
def block(tokens: List[Int], at: Int, loop: Bool, breakable: Bool, stops: List[Int]) -> Parsed
  stmts: List[Stmt] = []
  i = at
  while i < tokens.size
    token = tokens[i]
    if stops.include?(token)
      return Parsed(stmts: stmts, at: i + 1, stop: token)
    end

    i += 1
    if [LOCK, UNLOCK, WORK].include?(token)
      stmts = stmts.push(Stmt(kind: token))
    elsif [RETURN, GOTO].include?(token) or (token == BREAK and breakable) or (token == CONTINUE and loop)
      stmts = stmts.push(Stmt(kind: IF, id: i, body: [Stmt(kind: token)]))
    elsif token == IF
      taken = block(tokens, i, loop, breakable, [END, ELSE])
      other = Parsed(stmts: [], at: taken.at, stop: END)
      if taken.stop == ELSE
        other = block(tokens, taken.at, loop, breakable, [END])
      end

      stmts = stmts.push(Stmt(kind: IF, id: i, body: taken.stmts, other: other.stmts))
      i = other.at
    elsif token == WHILE
      body = block(tokens, i, true, true, [END])
      stmts = stmts.push(Stmt(kind: WHILE, id: i, body: body.stmts))
      i = body.at
    elsif token == SWITCH
      cases: List[List[Stmt]] = []
      start = i
      going = true
      while going
        one = block(tokens, i, loop, true, [END, CASE])
        cases = cases.push(one.stmts)
        i = one.at
        going = one.stop == CASE
      end

      stmts = stmts.push(Stmt(kind: SWITCH, id: start, cases: cases))
    end
  end

  return Parsed(stmts: stmts, at: i, stop: -1)
end

# Compares what cchecker reported with the oracle.
def agrees(ran: Result[Props.Output], generated: Program, source: String) -> Result[Void]
  output = try ran
  reported = [NOT_RELEASED, NOT_HELD].select do |code| output.stdout.include?("\"code\":\"#{code}\"") end
  sure = broken(exits(generated, EXACT).ret)
  wide = exits(generated, WIDE)
  possible = broken(wide.ret)
  missing = sure.select do |code| not reported.include?(code) end
  if not missing.empty?
    return error("missed #{missing.join(", ")} (#{exit_of(output.code, reported)}), in:\n#{source}\n#{output.stdout}")
  end

  extra = reported.select do |code| not possible.include?(code) end
  if wide.peak <= EXACT and not extra.empty?
    return error("no path breaks #{extra.join(", ")}, in:\n#{source}\n#{output.stdout}")
  end

  expected_code = 0
  if not reported.empty?
    expected_code = 1
  end

  if output.code != expected_code
    return error("exit code #{output.code} with #{reported.size} findings, in:\n#{source}\n#{output.stderr}")
  end

  return ok()
end

def exit_of(code: Int, reported: List[String]) -> String
  return "exit code #{code}, reported [#{reported.join(", ")}]"
end

# The rules that the counts at the returns break: a lock held, or released more than taken.
def broken(counts: List[Int]) -> List[String]
  codes: List[String] = []
  if counts.any? do |count| count > 0 end
    codes = codes.push(NOT_RELEASED)
  end

  if counts.any? do |count| count < 0 end
    codes = codes.push(NOT_HELD)
  end

  return codes
end

# The oracle: the counts of the lock at the returns of the function, on every path whose counts stay within `bound`
# (in `ret`), and the largest count reached (in `peak`). A `goto out` and the end of the body run the cleanup, then
# return; a `return` returns at once.
def exits(generated: Program, bound: Int) -> Flow
  body = run_block(generated.body, [0], bound)
  cleanup = run_block(generated.cleanup, merged(body.normal, body.jump), bound)
  return Flow(ret: merged(body.ret, cleanup.normal), peak: [body.peak, cleanup.peak].max.unwrap_or(0))
end

def run_block(stmts: List[Stmt], counts: List[Int], bound: Int) -> Flow
  flow = Flow(normal: counts)
  for stmt in stmts
    one = run_stmt(stmt, flow.normal, bound)
    flow = joined(flow.with(normal: []), one)
  end

  return flow
end

# The kinds are the tokens above: 0 LOCK, 1 UNLOCK, 3 IF, 6 WHILE, 7 BREAK, 8 CONTINUE, 9 RETURN, 10 GOTO, 11 SWITCH.
def run_stmt(stmt: Stmt, counts: List[Int], bound: Int) -> Flow
  case stmt.kind
    0 -> return moved(counts, 1, bound)
    1 -> return moved(counts, -1, bound)
    3 -> return joined(run_block(stmt.body, counts, bound), run_block(stmt.other, counts, bound))
    6 -> return run_loop(stmt.body, counts, bound)
    7 -> return Flow(brk: counts)
    8 -> return Flow(cont: counts)
    9 -> return Flow(ret: counts)
    10 -> return Flow(jump: counts)
    11 -> return run_switch(stmt.cases, counts, bound)
    _ -> return Flow(normal: counts)
  end
end

# Each count moved by `by`; a count past `bound` is a path the oracle does not follow, and only raises the peak.
def moved(counts: List[Int], by: Int, bound: Int) -> Flow
  next_counts = counts.map do |count| count + by end
  peak = next_counts.map do |count| count.abs end.max.unwrap_or(0)
  return Flow(normal: next_counts.select do |count| count.abs <= bound end, peak: peak)
end

# The head of the loop is reached from before it and after each turn (the end of the body or a `continue`), until no
# new count comes. The loop ends at the head (its condition false) or at a `break`.
def run_loop(body: List[Stmt], counts: List[Int], bound: Int) -> Flow
  head = counts
  turn = run_block(body, head, bound)
  next_head = merged(head, merged(turn.normal, turn.cont))
  while next_head != head
    head = next_head
    turn = run_block(body, head, bound)
    next_head = merged(head, merged(turn.normal, turn.cont))
  end

  return Flow(normal: merged(head, turn.brk), ret: turn.ret, jump: turn.jump, peak: turn.peak)
end

# Each case is entered from the switch and from the case before it that does not break; with no `default`, the switch
# also goes on after it.
def run_switch(cases: List[List[Stmt]], counts: List[Int], bound: Int) -> Flow
  flow = Flow(normal: [])
  falling: List[Int] = []
  breaks = counts
  for one in cases
    ran = run_block(one, merged(counts, falling), bound)
    falling = ran.normal
    breaks = merged(breaks, ran.brk)
    flow = joined(flow, ran.with(normal: [], brk: []))
  end

  return flow.with(normal: merged(breaks, falling))
end

def joined(a: Flow, b: Flow) -> Flow
  return Flow(
    normal: merged(a.normal, b.normal),
    brk: merged(a.brk, b.brk),
    cont: merged(a.cont, b.cont),
    ret: merged(a.ret, b.ret),
    jump: merged(a.jump, b.jump),
    peak: [a.peak, b.peak].max.unwrap_or(0),
  )
end

def merged(a: List[Int], b: List[Int]) -> List[Int]
  return a.concat(b).uniq.sort
end

def lines_of(stmts: List[Stmt], depth: Int) -> List[String]
  return stmts.flat_map do |stmt| stmt_lines(stmt, depth) end
end

def stmt_lines(stmt: Stmt, depth: Int) -> List[String]
  pad = "  " * depth
  case stmt.kind
    0 -> return ["#{pad}pthread_mutex_lock(&m);"]
    1 -> return ["#{pad}pthread_mutex_unlock(&m);"]
    3 ->
      lines = ["#{pad}if (pick(#{stmt.id})) {"].concat(lines_of(stmt.body, depth + 1))
      if not stmt.other.empty?
        lines = lines.push("#{pad}} else {").concat(lines_of(stmt.other, depth + 1))
      end

      return lines.push("#{pad}}")

    6 -> return ["#{pad}while (pick(#{stmt.id})) {"].concat(lines_of(stmt.body, depth + 1)).push("#{pad}}")
    7 -> return ["#{pad}break;"]
    8 -> return ["#{pad}continue;"]
    9 -> return ["#{pad}return 0;"]
    10 -> return ["#{pad}goto out;"]
    11 ->
      lines = ["#{pad}switch (pick(#{stmt.id})) {"]
      i = 0
      for one in stmt.cases
        lines = lines.push("#{pad}case #{i}: ;").concat(lines_of(one, depth + 1))
        i += 1
      end

      return lines.push("#{pad}}")

    _ -> return ["#{pad}work();"]
  end
end
