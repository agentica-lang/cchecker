## The property tests of the lock walk: a generated function takes and releases one lock `m` under if/else, loops with
## break and continue, a switch with fallthrough, early returns and a goto to a cleanup label, all on conditions that
## cchecker cannot know. It also keeps the result of a lock in a variable `r`: a trylock (`r = pthread_mutex_trylock(&m)`,
## in four forms, or at the declaration of `r`), which takes the lock where the call gave 0, and a lock that waits
## (`r = pthread_mutex_lock(&m)`), whose failure a path reaches only when the function tests `r`. It tests `r` in the
## ways C writes it (`r == 0`, `!r`, `r == EBUSY`, a switch), sets `r` to a constant or to a value cchecker cannot know,
## and sets a flag `q` whose address is taken (`*p = 1`), whose value written cchecker never knows: only its tests tell
## it, until the next write. An oracle runs the function over all its paths, counting the lock as docs/rules.md says
## (at most twice either way) with what each path knows of `r` and `q`, and cchecker must report a code of the lock
## rules if and only if a path breaks its rule. The law compares the codes only, not the path a finding shows.

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
# A trylock kept in `r` (`TRY`), an if on `r` with an else like `IF` (`TEST`), a new value of `r` (`SET`), a lock that
# waits kept in `r` (`KEEP`), a switch on `r` (`ON`: its `case 0` and its `default`, like the two sides of a `TEST`),
# a new value of `q` (`QSET`) and an if on `q` (`QTEST`).
TRY = 13
TEST = 14
SET = 15
KEEP = 16
ON = 17
QSET = 18
QTEST = 19

# The tokens a body is drawn from, the lock calls and the blocks more often than the ways out. A token shrinks toward
# the first, a lock. `KEEP`, `QSET` and `QTEST` come twice, so a function often writes `q` and tests it after, or
# keeps a lock that waits without a test of `r`.
DRAWN = [
  LOCK, LOCK, LOCK, UNLOCK, UNLOCK, UNLOCK, WORK, IF, IF, ELSE, END, END, END, WHILE, SWITCH, CASE, CASE, BREAK,
  CONTINUE, RETURN, GOTO, TRY, TRY, TEST, TEST, SET, KEEP, KEEP, ON, QSET, QSET, QTEST, QTEST,
]

# The tokens whose statement holds a call of the lock or a way out: a test around one of them guards a lock, and only
# then is a constant written to the variable it tests a fact (docs/rules.md).
GUARDING = [LOCK, UNLOCK, TRY, KEEP, ON, RETURN, GOTO, BREAK, CONTINUE]

# A lock taken more often than this on a path counts as taken this many times, and one released more often as released
# this many times: the limit of docs/rules.md, so that a loop ends.
CLAMP = 2

# What a path knows of `r` (`UNKNOWN`, `ZERO`: the trylock worked, `NONZERO`), of `r == EBUSY` (`UNKNOWN`, `YES`,
# `NO`) and of `q` from its tests (`UNKNOWN`, `ZERO`, `NONZERO`). The state of a path is the count of the lock and the
# three, as one number (`state_of`).
UNKNOWN = 0
ZERO = 1
NONZERO = 2
YES = 1
NO = 2
KNOWS = 3

# The codes of the two lock rules.
NOT_RELEASED = "CC-PATH-LOCK-NOT-RELEASED"
NOT_HELD = "CC-PATH-LOCK-NOT-HELD"

## A statement of a generated function. `kind` is the token that made it; `id` numbers its condition (`pick(id)`), so
## that no two conditions are the same, and picks the form of a statement on `r` or `q`; `body` is the then branch or
## the loop body, `other` the else branch, `cases` the cases of a switch in order.
export struct Stmt
  kind: Int
  id: Int = 0
  body: List[Stmt] = []
  other: List[Stmt] = []
  cases: List[List[Stmt]] = []
end

## A generated function: how `r` starts (`start`: a value cchecker cannot know, a trylock, a lock that waits), its
## body, and what runs after the label `out:` that `goto out` reaches.
export struct Program
  start: Int
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

# What the rules keep of `r` in the whole function (docs/rules.md): its value is followed when the function names it in
# two places (`known`), that of `r == EBUSY` when two tests are of it (`busy`), and the failure of a lock that waits
# is a path only when the function tests `r` (`tested`).
struct Oracle
  known: Bool
  busy: Bool
  tested: Bool
end

## The generator of functions: up to 24 tokens of the body and 3 of the cleanup (lock, unlock, work, or a `return` or
## a `goto out` under a condition), and how `r` starts.
export def programs() -> Prop.Gen[Program]
  drawn = Prop.list(Prop.one_of(DRAWN), 24)
  tail = Prop.list(Prop.one_of([LOCK, UNLOCK, WORK, RETURN, GOTO]), 3)
  tokens = Prop.pair(Prop.pair(drawn, tail), Prop.int(0, 2))
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
  start = ["pick(0)", "pthread_mutex_trylock(&m)", "pthread_mutex_lock(&m)"][generated.start]
  head = [
    "#include <errno.h>",
    "#include <pthread.h>",
    "",
    "pthread_mutex_t m;",
    "int pick(int k);",
    "void work(void);",
    "int f(void) {",
    "  int r = #{start};",
    "  int q = pick(-1);",
    "  int *p = &q;",
  ]

  lines = head.concat(lines_of(generated.body, 1)).push("out:").concat(lines_of(generated.cleanup, 1))
  lines.push("  return 0;").push("}").join("\n") + "\n"
end

def program_of(drawn: Prop.Pair[Prop.Pair[List[Int], List[Int]], Int]) -> Program
  tokens = drawn.first
  body = block(tokens.first, 0, false, false, [])
  cleanup = block(tokens.second, 0, false, false, [])
  Program(start: drawn.second, body: body.stmts, cleanup: cleanup.stmts)
end

# Reads statements from `at` to a token of `stops`. `loop` says whether a `continue` fits, `breakable` a `break`.
def block(tokens: List[Int], at: Int, loop: Bool, breakable: Bool, stops: List[Int]) -> Parsed
  stmts: List[Stmt] = []
  i = at
  while i < tokens.size
    token = tokens[i]
    return Parsed(stmts: stmts, at: i + 1, stop: token) if stops.include?(token)

    i += 1
    if [LOCK, UNLOCK, WORK, TRY, SET, KEEP, QSET].include?(token)
      stmts = stmts.push(Stmt(kind: token, id: i))
    elsif [RETURN, GOTO].include?(token) or (token == BREAK and breakable) or (token == CONTINUE and loop)
      stmts = stmts.push(Stmt(kind: IF, id: i, body: [Stmt(kind: token)]))
    elsif [IF, TEST, ON, QTEST].include?(token)
      # A `break` in a switch on `r` leaves the switch.
      inner = breakable or token == ON
      taken = block(tokens, i, loop, inner, [END, ELSE])
      other = Parsed(stmts: [], at: taken.at, stop: END)
      if taken.stop == ELSE
        other = block(tokens, taken.at, loop, inner, [END])
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
  o = oracle_of(generated)
  first = [state_of(0, UNKNOWN, UNKNOWN, UNKNOWN)]
  if generated.start == 1
    first = tried(o, first, false)
  elsif generated.start == 2
    first = kept(o, first)
  end

  body = run_block(o, generated.body, first)
  entry = merged(body.normal, body.jump)
  cleanup = run_block(o, generated.cleanup, entry)
  label = merged(entry, cleanup.jump)
  while label != entry
    entry = label
    cleanup = run_block(o, generated.cleanup, entry)
    label = merged(entry, cleanup.jump)
  end

  merged(body.ret, merged(cleanup.ret, cleanup.normal))
end

# What the rules keep of `r`, from the places that name it: each test and each kept result once (a test written
# `if ((r = ...) != 0)` twice), the labels of a switch on `r`, and a constant only where a test of `r` guards a lock.
def oracle_of(generated: Program) -> Oracle
  stmts = all_of(generated.body.concat(generated.cleanup))
  guarded = stmts.any? do |stmt|
    (stmt.kind == TEST and holds_guard?(stmt.body.concat(stmt.other))) or stmt.kind == ON or tried_in_test?(stmt)
  end

  names = 0
  tests = 0
  busy = 0
  if generated.start != 0
    names += 1
  end

  for stmt in stmts
    kind = stmt.kind
    if kind == TEST
      names += 1
      tests += 1
      if stmt.id % 6 >= 4
        busy += 1
      end
    elsif kind == TRY or kind == KEEP
      names += 1
      if tried_in_test?(stmt)
        names += 1
        tests += 1
      end
    elsif kind == SET and stmt.id % 3 != 0 and guarded
      names += 1
    elsif kind == ON
      # Its `case 0`, and its `default`, which the `case 0` makes a value of `r` too.
      names += 2
      tests += 1
    end
  end

  Oracle(known: names >= 2, busy: busy >= 2, tested: tests > 0)
end

# The statements of a list and all those inside them.
def all_of(stmts: List[Stmt]) -> List[Stmt]
  stmts.flat_map do |stmt|
    [stmt].concat(all_of(stmt.body.concat(stmt.other).concat(stmt.cases.flat_map do |one| one end)))
  end
end

# Whether statements hold a call of the lock or a way out, at any depth.
def holds_guard?(stmts: List[Stmt]) -> Bool = all_of(stmts).any? do |stmt| GUARDING.include?(stmt.kind) end

# Whether a trylock is written in the test of an if (`if ((r = pthread_mutex_trylock(&m)) != 0)`).
def tried_in_test?(stmt: Stmt) -> Bool = stmt.kind == TRY and stmt.id % 4 == 1

def run_block(o: Oracle, stmts: List[Stmt], states: List[Int]) -> Flow
  flow = Flow(normal: states)
  for stmt in stmts
    one = run_stmt(o, stmt, flow.normal)
    flow = joined(flow.with(normal: []), one)
  end

  flow
end

def run_stmt(o: Oracle, stmt: Stmt, states: List[Int]) -> Flow
  kind = stmt.kind
  if kind == LOCK or kind == UNLOCK
    return Flow(normal: moved(states, kind == LOCK))
  elsif kind == TRY
    return Flow(normal: tried(o, states, stmt.id % 4 == 3))
  elsif kind == KEEP
    return Flow(normal: kept(o, states))
  elsif kind == SET
    value = [UNKNOWN, ZERO, NONZERO][stmt.id % 3]
    kept = states.map do |state| state_of(count_of(state), r_value(o, value), UNKNOWN, q_of(state)) end
    return Flow(normal: merged([], kept))
  elsif kind == QSET
    forgot = states.map do |state| state_of(count_of(state), r_of(state), busy_of(state), UNKNOWN) end
    return Flow(normal: merged([], forgot))
  elsif kind == TEST
    form = stmt.id % 6
    taken = run_block(o, stmt.body, test_side(o, states, form, true))
    return joined(taken, run_block(o, stmt.other, test_side(o, states, form, false)))
  elsif kind == ON
    # `case 0` is the side where `r` is 0; `default`, after that `case 0`, and the `case EBUSY` before it, the side
    # where it is not. A `break` leaves the switch.
    other = knowing(o, states, NONZERO)
    ran = joined(run_block(o, stmt.body, knowing(o, states, ZERO)), run_block(o, stmt.other, other))
    return ran.with(normal: merged(ran.normal, ran.brk), brk: [])
  elsif kind == QTEST
    taken = run_block(o, stmt.body, q_knowing(states, NONZERO))
    return joined(taken, run_block(o, stmt.other, q_knowing(states, ZERO)))
  elsif kind == IF
    return joined(run_block(o, stmt.body, states), run_block(o, stmt.other, states))
  elsif kind == WHILE
    return run_loop(o, stmt.body, states)
  elsif kind == BREAK
    return Flow(brk: states)
  elsif kind == CONTINUE
    return Flow(cont: states)
  elsif kind == RETURN
    return Flow(ret: states)
  elsif kind == GOTO
    return Flow(jump: states)
  elsif kind == SWITCH
    return run_switch(o, stmt.cases, states)
  end

  Flow(normal: states)
end

# A trylock kept in `r`: the lock is taken where the call gave 0, and `r` says which way it went, the other way round
# for `r = pthread_mutex_trylock(&m) == 0` (`flipped`).
def tried(o: Oracle, states: List[Int], flipped: Bool) -> List[Int]
  zero = ZERO
  other = NONZERO
  if flipped
    zero = NONZERO
    other = ZERO
  end

  worked = moved(states, true).map do |state| state_of(count_of(state), r_value(o, zero), UNKNOWN, q_of(state)) end
  failed = states.map do |state| state_of(count_of(state), r_value(o, other), UNKNOWN, q_of(state)) end
  merged(worked, failed)
end

# A lock that waits kept in `r`: it failed only on a path of a function that tests `r`.
def kept(o: Oracle, states: List[Int]) -> List[Int]
  worked = moved(states, true).map do |state| state_of(count_of(state), r_value(o, ZERO), UNKNOWN, q_of(state)) end
  return merged([], worked) if not o.tested

  merged(worked, states.map do |state| state_of(count_of(state), r_value(o, NONZERO), UNKNOWN, q_of(state)) end)
end

# What a path knows of `r` after it learns `value`: nothing when the rules do not follow `r`.
def r_value(o: Oracle, value: Int) -> Int
  return UNKNOWN if not o.known

  value
end

# The states on a side of a test of `r` of this form: `r == 0`, `r != 0`, `!r`, `r`, `r == EBUSY`, `r != EBUSY`.
def test_side(o: Oracle, states: List[Int], form: Int, yes: Bool) -> List[Int]
  return knowing(o, states, [ZERO, NONZERO, ZERO, NONZERO][form]) if form < 4 and yes

  return knowing(o, states, [NONZERO, ZERO, NONZERO, ZERO][form]) if form < 4

  # `r == EBUSY` holds: `r` is not 0. It does not hold: nothing more of `r`.
  busy = (form == 4) == yes
  return busy_side(o, knowing(o, states, NONZERO), YES) if busy

  busy_side(o, states, NO)
end

# The states that can have `r` as `value` says, knowing it from then on.
def knowing(o: Oracle, states: List[Int], value: Int) -> List[Int]
  return states if not o.known

  allowed = states.select do |state| r_of(state) == UNKNOWN or r_of(state) == value end
  merged([], allowed.map do |state| state_of(count_of(state), value, busy_of(state), q_of(state)) end)
end

# The states that can have `r == EBUSY` as `value` says, knowing it from then on.
def busy_side(o: Oracle, states: List[Int], value: Int) -> List[Int]
  return states if not o.busy

  allowed = states.select do |state| busy_of(state) == UNKNOWN or busy_of(state) == value end
  merged([], allowed.map do |state| state_of(count_of(state), r_of(state), value, q_of(state)) end)
end

# One number for a count of the lock (from -CLAMP to CLAMP), what a path knows of `r`, of `r == EBUSY` and of `q`.
def state_of(count: Int, r: Int, busy: Int, q: Int) -> Int = (((count + CLAMP) * KNOWS + r) * KNOWS + busy) * KNOWS + q

def count_of(state: Int) -> Int = state / (KNOWS * KNOWS * KNOWS) - CLAMP

def r_of(state: Int) -> Int = (state / (KNOWS * KNOWS)) % KNOWS

def busy_of(state: Int) -> Int = (state / KNOWS) % KNOWS

def q_of(state: Int) -> Int = state % KNOWS

# The states that can have `q` as `value` says, knowing it from then on: a test of `q` is one of a variable that the
# rules follow, though they never know a value written to it, as its address is taken (`QSET` forgets it).
def q_knowing(states: List[Int], value: Int) -> List[Int]
  allowed = states.select do |state| q_of(state) == UNKNOWN or q_of(state) == value end
  merged([], allowed.map do |state| state_of(count_of(state), r_of(state), busy_of(state), value) end)
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
      state_of(count, r_of(state), busy_of(state), q_of(state))
    end,
  )
end

# The head of the loop is reached from before it and after each turn (the end of the body or a `continue`), until no
# new state comes. The loop ends at the head (its condition false) or at a `break`.
def run_loop(o: Oracle, body: List[Stmt], states: List[Int]) -> Flow
  head = states
  turn = run_block(o, body, head)
  next_head = merged(head, merged(turn.normal, turn.cont))
  while next_head != head
    head = next_head
    turn = run_block(o, body, head)
    next_head = merged(head, merged(turn.normal, turn.cont))
  end

  Flow(normal: merged(head, turn.brk), ret: turn.ret, jump: turn.jump)
end

# Each case is entered from the switch and from the case before it that does not break; with no `default`, the switch
# also goes on after it.
def run_switch(o: Oracle, cases: List[List[Stmt]], states: List[Int]) -> Flow
  flow = Flow(normal: [])
  falling: List[Int] = []
  breaks = states
  for one in cases
    ran = run_block(o, one, merged(states, falling))
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
    KEEP: "r = pthread_mutex_lock(&m);",
  }

  if kind == TRY
    forms = [
      "r = pthread_mutex_trylock(&m);", "if ((r = pthread_mutex_trylock(&m)) != 0) work();",
      "r = pthread_mutex_trylock(&m) != 0;", "r = pthread_mutex_trylock(&m) == 0;",
    ]

    return ["#{pad}#{forms[stmt.id % 4]}"]
  elsif kind == SET
    return ["#{pad}r = #{["pick(#{stmt.id})", "0", "1"][stmt.id % 3]};"]
  elsif kind == QSET
    return ["#{pad}#{["q = 0;", "q = 1;", "*p = 0;", "*p = 1;"][stmt.id % 4]}"]
  elsif kind == ON
    lines = ["#{pad}switch (r) {", "#{pad}case 0: {"].concat(lines_of(stmt.body, depth + 1)).push("#{pad}} break;")
    if stmt.id % 2 == 1
      lines = lines.push("#{pad}case EBUSY:")
    end

    return lines.push("#{pad}default: {").concat(lines_of(stmt.other, depth + 1)).push("#{pad}}").push("#{pad}}")
  elsif [IF, TEST, QTEST].include?(kind)
    test = "pick(#{stmt.id})"
    if kind == TEST
      test = ["r == 0", "r != 0", "!r", "r", "r == EBUSY", "r != EBUSY"][stmt.id % 6]
    elsif kind == QTEST
      test = "q"
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
