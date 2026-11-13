import Options from "../src/options"

private

def test_a_value_that_starts_with_a_dash_is_taken_from_the_next_word() -> Result[Void]
  long = try Options.parse(["--checks", "-*,bugprone-*", "-j", "1", "a.c"])
  try Test.eq(long.checks, "-*,bugprone-*")
  try Test.eq(long.files, ["a.c"])
  short = try Options.parse(["-b", "-base.json", "-j", "1", "a.c"])
  Test.eq(short.baseline, some("-base.json"))
end

def test_an_empty_value_is_still_a_value() -> Result[Void]
  options = try Options.parse(["--checks", "", "-j", "1", "a.c"])
  try Test.eq(options.checks, "")
  short = try Options.parse(["-b", "", "-j", "1", "a.c"])
  Test.eq(short.baseline, some(""))
end

def test_an_option_at_the_end_needs_a_value() -> Result[Void] = Test.eq(Options.parse(["a.c", "--checks"]).ok?, false)
