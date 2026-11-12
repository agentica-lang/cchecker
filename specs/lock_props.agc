## The property tests of the lock walk: a generated function takes and releases one lock `m` under if/else, loops with
## break and continue, a switch with fallthrough, early returns and a goto to a cleanup label, all on conditions that
## cchecker cannot know. It also tries the lock into a variable `r` (`r = pthread_mutex_trylock(&m)`), which takes it
## where the call gave 0, tests `r` in the four ways C writes it, and sets `r` again, to a constant or to a value
## cchecker cannot know. An oracle runs the function over all its paths, counting the lock as docs/rules.md says (at
## most twice either way) with what each path knows of `r`, and cchecker must report a code of the lock rules if and
## only if a path breaks its rule. The law compares the codes only, not the path a finding shows.

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
# `r = pthread_mutex_trylock(&m);`, an if on `r` with an else like `IF`, and a new value of `r`.
TRY = 13
TEST = 14
SET = 15

# The tokens a body is drawn from, the lock calls and the blocks more often than the ways out. A token shrinks toward
# the first, a lock.
DRAWN = [
  LOCK, LOCK, LOCK, UNLOCK, UNLOCK, UNLOCK, WORK, IF, IF, ELSE, END, END, END, WHILE, SWITCH, CASE, CASE, BREAK,
  CONTINUE, RETURN, GOTO, TRY, TRY, TEST, TEST, SET,
]

# A lock taken more often than this on a path counts as taken this many times, and one released more often as released
# this many times: the limit of docs/rules.md, so that a loop ends.
CLAMP = 2

# What a path knows of `r`: nothing, that it is 0 (the trylock worked), or that it is not. The state of a path is the
# count of the lock and what it knows of `r`, as one number (`state_of`).
UNKNOWN = 0
ZERO = 1
NONZERO = 2
KNOWS = 3

# The codes of the two lock rules.
NOT_RELEASED = "CC-PATH-LOCK-NOT-RELEASED"
NOT_HELD = "CC-PATH-LOCK-NOT-HELD"

## A statement of a generated function. `kind` is the token that made it; `id` numbers its condition (`pick(id)`), so
## that no two conditions are the same, and picks the form of a test or a new value of `r`; `body` is the then branch
## or the loop body, `other` the else branch, `cases` the cases of a switch in order.
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

# Where each way out of a piece of code goes: the states (`state_of`) of the paths that go on, break, continue, return
# or jump to `out`.
struct Flow
  normal: List[Int] = []
  brk: List[Int] = []
  cont: List[Int] = []
  ret: List[Int] = []
  jump: List[Int] = []
end

## The generator of functions: up to 24 tokens of the body and 3 of the cleanup (lock, unlock, work, or a `return` or
## a `goto out` under a condition). `r` starts with a value that cchecker cannot know.
export def programs() -> Prop.Gen[Program]
  drawn = Prop.list(Prop.one_of(DRAWN), 24)
  tail = Prop.list(Prop.one_of([LOCK, UNLOCK, WORK, RETURN, GOTO]), 3)
  tokens = Prop.pair(drawn, tail)
  Prop.map(tokens, &program_of)
end

## Checks `runs` functions, from `seed` when it is given, with cchecker (the bytecode `program`, run in specs/): each
## rule that a path breaks is reported (no false negative), each code reported is a rule that a path breaks (no false
## positive), and the exit code is 1 with findings and 0 without.
export def walk_agrees(program: String, folder: String, runs: Int, seed: Optional[Int]) -> Result[Void]
  config = Prop.Config(runs: runs, seed: seed, shrinks: Props.SHRINKS)
  Prop.check(programs(), config) do |generated|
    source = c_file(generated)
    agrees(Props.run(program, folder, source), generated, source)
  end
end

## The C file of a generated function: `f` with the label `out:` before its cleanup.
export def c_file(generated: Program) -> String
  head = [
    "#include <pthread.h>", "", "pthread_mutex_t m;", "int pick(int k);", "void work(void);", "int f(void) {",
    "  int r = pick(0);",
  ]

  lines = head.concat(lines_of(generated.body, 1)).push("out:").concat(lines_of(generated.cleanup, 1))
  lines.push("  return 0;").push("}").join("\n") + "\n"
end

def program_of(tokens: Prop.Pair[List[Int], List[Int]]) -> Program
  body = block(tokens.first, 0, false, false, [])
  cleanup = block(tokens.second, 0, false, false, [])
  Program(body: body.stmts, cleanup: cleanup.stmts)
end

# Reads statements from `at` to a token of `stops`. `loop` says whether a `continue` fits, `breakable` a `break`.
def block(tokens: List[Int], at: Int, loop: Bool, breakable: Bool, stops: List[Int]) -> Parsed
  stmts: List[Stmt] = []
  i = at
  while i < tokens.size
    token = tokens[i]
    return Parsed(stmts: stmts, at: i + 1, stop: token) if stops.include?(token)

    i += 1
    if [LOCK, UNLOCK, WORK, TRY, SET].include?(token)
      stmts = stmts.push(Stmt(kind: token, id: i))
    elsif [RETURN, GOTO].include?(token) or (token == BREAK and breakable) or (token == CONTINUE and loop)
      stmts = stmts.push(Stmt(kind: IF, id: i, body: [Stmt(kind: token)]))
    elsif token == IF or token == TEST
      taken = block(tokens, i, loop, breakable, [END, ELSE])
      other = Parsed(stmts: [], at: taken.at, stop: END)
      if taken.stop == ELSE
        other = block(tokens, taken.at, loop, breakable, [END])
      end

      stmts = stmts.push(Stmt(kind: token, id: i, body: taken.stmts, other: other.stmts))
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

  Parsed(stmts: stmts, at: i, stop: -1)
end

# Compares what cchecker reported with the oracle: a code is reported if and only if a path breaks its rule.
def agrees(ran: Result[Props.Output], generated: Program, source: String) -> Result[Void]
  output = try ran
  reported = [NOT_RELEASED, NOT_HELD].select do |code| output.stdout.include?("\"code\":\"#{code}\"") end
  expected = broken(exits(generated))
  if reported != expected
    got = "exit code #{output.code}, reported [#{reported.join(", ")}]"
    return error("expected [#{expected.join(", ")}], #{got}, in:\n#{source}\n#{output.stdout}#{output.stderr}")
  end

  expected_code = 0
  if not reported.empty?
    expected_code = 1
  end

  if output.code != expected_code
    return error("exit code #{output.code} with #{reported.size} findings, in:\n#{source}\n#{output.stderr}")
  end

  ok()
end

# The rules that the states at the returns break: a lock held, or released more than taken.
def broken(states: List[Int]) -> List[String]
  counts = states.map(&count_of)
  codes: List[String] = []
  if counts.any? do |count| count > 0 end
    codes = codes.push(NOT_RELEASED)
  end

  if counts.any? do |count| count < 0 end
    codes = codes.push(NOT_HELD)
  end

  codes
end

# The oracle: the states at the returns of the function, on every path. The label `out:` is reached from the end of
# the body and from each `goto out`, also one in the cleanup, until no new state comes; the end of the cleanup and each
# `return` return.
def exits(generated: Program) -> List[Int]
  body = run_block(generated.body, [state_of(0, UNKNOWN)])
  entry = merged(body.normal, body.jump)
  cleanup = run_block(generated.cleanup, entry)
  label = merged(entry, cleanup.jump)
  while label != entry
    entry = label
    cleanup = run_block(generated.cleanup, entry)
    label = merged(entry, cleanup.jump)
  end

  merged(body.ret, merged(cleanup.ret, cleanup.normal))
end

def run_block(stmts: List[Stmt], states: List[Int]) -> Flow
  flow = Flow(normal: states)
  for stmt in stmts
    one = run_stmt(stmt, flow.normal)
    flow = joined(flow.with(normal: []), one)
  end

  flow
end

def run_stmt(stmt: Stmt, states: List[Int]) -> Flow
  kind = stmt.kind
  if kind == LOCK or kind == UNLOCK
    return Flow(normal: moved(states, kind == LOCK))
  elsif kind == TRY
    # The lock is taken where the call gave 0, and `r` says which way it went.
    worked = moved(states, true).map do |state| state_of(count_of(state), ZERO) end
    failed = states.map do |state| state_of(count_of(state), NONZERO) end
    return Flow(normal: merged(worked, failed))
  elsif kind == SET
    return Flow(normal: merged([], states.map do |state| state_of(count_of(state), set_value(stmt.id)) end))
  elsif kind == TEST
    # A path goes to the side that what it knows of `r` allows, and knows `r` from then on.
    yes = tested_zero(stmt.id)
    no = not yes
    return joined(run_block(stmt.body, knowing(states, yes)), run_block(stmt.other, knowing(states, no)))
  elsif kind == IF
    return joined(run_block(stmt.body, states), run_block(stmt.other, states))
  elsif kind == WHILE
    return run_loop(stmt.body, states)
  elsif kind == BREAK
    return Flow(brk: states)
  elsif kind == CONTINUE
    return Flow(cont: states)
  elsif kind == RETURN
    return Flow(ret: states)
  elsif kind == GOTO
    return Flow(jump: states)
  elsif kind == SWITCH
    return run_switch(stmt.cases, states)
  end

  Flow(normal: states)
end

# One number for a count of the lock (from -CLAMP to CLAMP) and what a path knows of `r`.
def state_of(count: Int, knows: Int) -> Int = (count + CLAMP) * KNOWS + knows

def count_of(state: Int) -> Int = state / KNOWS - CLAMP

def knows_of(state: Int) -> Int = state % KNOWS

# Whether the then branch of the test of `r` of this id is the side where `r` is 0: `r == 0` and `!r` are, `r != 0`
# and `r` are not.
def tested_zero(id: Int) -> Bool = id % 4 == 0 or id % 4 == 2

# What a path knows of `r` after the new value of this id: `pick(id)`, `0` or `1`.
def set_value(id: Int) -> Int = [UNKNOWN, ZERO, NONZERO][id % 3]

# The states that can have `r` 0 (`zero`) or not, knowing it from then on.
def knowing(states: List[Int], zero: Bool) -> List[Int]
  knows = NONZERO
  if zero
    knows = ZERO
  end

  allowed = states.select do |state| knows_of(state) == UNKNOWN or knows_of(state) == knows end
  merged([], allowed.map do |state| state_of(count_of(state), knows) end)
end

# Each state after a take (or a release), its count held within CLAMP.
def moved(states: List[Int], take: Bool) -> List[Int]
  by = -1
  if take
    by = 1
  end

  merged(
    [],
    states.map do |state|
      count = [[count_of(state) + by, CLAMP].min.unwrap_or(0), -CLAMP].max.unwrap_or(0)
      state_of(count, knows_of(state))
    end,
  )
end

# The head of the loop is reached from before it and after each turn (the end of the body or a `continue`), until no
# new state comes. The loop ends at the head (its condition false) or at a `break`.
def run_loop(body: List[Stmt], states: List[Int]) -> Flow
  head = states
  turn = run_block(body, head)
  next_head = merged(head, merged(turn.normal, turn.cont))
  while next_head != head
    head = next_head
    turn = run_block(body, head)
    next_head = merged(head, merged(turn.normal, turn.cont))
  end

  Flow(normal: merged(head, turn.brk), ret: turn.ret, jump: turn.jump)
end

# Each case is entered from the switch and from the case before it that does not break; with no `default`, the switch
# also goes on after it.
def run_switch(cases: List[List[Stmt]], states: List[Int]) -> Flow
  flow = Flow(normal: [])
  falling: List[Int] = []
  breaks = states
  for one in cases
    ran = run_block(one, merged(states, falling))
    falling = ran.normal
    breaks = merged(breaks, ran.brk)
    flow = joined(flow, ran.with(normal: [], brk: []))
  end

  flow.with(normal: merged(breaks, falling))
end

def joined(a: Flow, b: Flow) -> Flow
  Flow(
    normal: merged(a.normal, b.normal),
    brk: merged(a.brk, b.brk),
    cont: merged(a.cont, b.cont),
    ret: merged(a.ret, b.ret),
    jump: merged(a.jump, b.jump),
  )
end

def merged(a: List[Int], b: List[Int]) -> List[Int] = a.concat(b).uniq.sort

def lines_of(stmts: List[Stmt], depth: Int) -> List[String] = stmts.flat_map do |stmt| stmt_lines(stmt, depth) end

def stmt_lines(stmt: Stmt, depth: Int) -> List[String]
  pad = "  " * depth
  kind = stmt.kind
  simple = {
    LOCK: "pthread_mutex_lock(&m);",
    UNLOCK: "pthread_mutex_unlock(&m);",
    BREAK: "break;",
    CONTINUE: "continue;",
    RETURN: "return 0;",
    GOTO: "goto out;",
  }

  if kind == TRY
    return ["#{pad}r = pthread_mutex_trylock(&m);"]
  elsif kind == SET
    return ["#{pad}r = #{["pick(#{stmt.id})", "0", "1"][stmt.id % 3]};"]
  elsif kind == IF or kind == TEST
    test = "pick(#{stmt.id})"
    if kind == TEST
      test = ["r == 0", "r != 0", "!r", "r"][stmt.id % 4]
    end

    lines = ["#{pad}if (#{test}) {"].concat(lines_of(stmt.body, depth + 1))
    if not stmt.other.empty?
      lines = lines.push("#{pad}} else {").concat(lines_of(stmt.other, depth + 1))
    end

    return lines.push("#{pad}}")
  elsif kind == WHILE
    return ["#{pad}while (pick(#{stmt.id})) {"].concat(lines_of(stmt.body, depth + 1)).push("#{pad}}")
  elsif kind == SWITCH
    lines = ["#{pad}switch (pick(#{stmt.id})) {"]
    i = 0
    for one in stmt.cases
      lines = lines.push("#{pad}case #{i}: ;").concat(lines_of(one, depth + 1))
      i += 1
    end

    return lines.push("#{pad}}")
  end

  ["#{pad}#{simple.get(kind).unwrap_or("work();")}"]
end
