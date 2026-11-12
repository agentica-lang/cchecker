import Scan from "../src/scan"
import Paths from "../src/paths"
import UnitReader from "../src/unit"

# A dump as clang writes it: a location leaves out the file and the line when they are those of the location before
# it, and `includedFrom` names the file that included it, which is not the file of the location.
DUMP = <<~JSON
  {
    "id": "0x1",
    "kind": "TranslationUnitDecl",
    "loc": {},
    "range": {
      "begin": {},
      "end": {}
    },
    "inner": [
      {
        "kind": "TypedefDecl",
        "loc": {},
        "name": "__int128_t"
      },
      {
        "kind": "FunctionDecl",
        "loc": {
          "offset": 1,
          "file": "/usr/include/stdio.h",
          "line": 3,
          "col": 5,
          "tokLen": 1
        },
        "name": "printf"
      },
      {
        "kind": "FunctionDecl",
        "loc": {
          "offset": 1,
          "file": "src/a.h",
          "line": 7,
          "col": 5,
          "tokLen": 1,
          "includedFrom": {
            "file": "/usr/include/x.h"
          }
        },
        "name": "f"
      },
      {
        "kind": "FunctionDecl",
        "loc": {
          "offset": 9,
          "col": 6,
          "tokLen": 1
        },
        "name": "g"
      },
      {
        "kind": "FunctionDecl",
        "loc": {
          "offset": 1,
          "file": "/usr/include/stdlib.h",
          "line": 4,
          "col": 5,
          "tokLen": 1
        },
        "name": "malloc"
      }
    ]
  }
JSON

# Two tables of a typedef'd type, which clang does not desugar: one of numbers, one that holds a function.
TABLES = <<~JSON
  {
    "kind": "TranslationUnitDecl",
    "inner": [
      {
        "kind": "VarDecl",
        "loc": {
          "file": "t.c",
          "line": 3,
          "col": 17
        },
        "name": "ROM",
        "type": {
          "qualType": "const uint8_t[2]"
        },
        "inner": [
          {
            "kind": "InitListExpr",
            "type": {
              "qualType": "const uint8_t[2]"
            },
            "array_filler": [
              {
                "kind": "ImplicitValueInitExpr"
              }
            ],
            "inner": [
              {
                "kind": "ImplicitCastExpr",
                "inner": [
                  {
                    "kind": "IntegerLiteral",
                    "value": "7"
                  }
                ]
              }
            ]
          }
        ]
      },
      {
        "kind": "VarDecl",
        "loc": {
          "line": 4,
          "col": 17
        },
        "name": "OPS",
        "type": {
          "qualType": "const handler_t[1]"
        },
        "inner": [
          {
            "kind": "InitListExpr",
            "inner": [
              {
                "kind": "ImplicitCastExpr",
                "inner": [
                  {
                    "kind": "DeclRefExpr",
                    "referencedDecl": {
                      "kind": "FunctionDecl",
                      "name": "f"
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
JSON

# A table of a typedef'd function pointer whose first item is a null pointer: `{0, f}`.
NULLS = <<~JSON
  {
    "kind": "TranslationUnitDecl",
    "inner": [
      {
        "kind": "VarDecl",
        "loc": {
          "file": "t.c",
          "line": 3,
          "col": 11
        },
        "name": "table",
        "type": {
          "qualType": "fn[2]"
        },
        "inner": [
          {
            "kind": "InitListExpr",
            "inner": [
              {
                "kind": "ImplicitCastExpr",
                "type": {
                  "qualType": "fn"
                },
                "castKind": "NullToPointer",
                "inner": [
                  {
                    "kind": "IntegerLiteral",
                    "value": "0"
                  }
                ]
              },
              {
                "kind": "DeclRefExpr",
                "referencedDecl": {
                  "kind": "FunctionDecl",
                  "name": "f"
                }
              }
            ]
          }
        ]
      }
    ]
  }
JSON

struct Dump
  decls: List[Decl]
end

struct Decl
  name: String
  loc: Place
end

struct Place
  cc_file: String
  cc_line: Int
  col: Int
end

struct Names
  decls: List[Named]
end

struct Named
  name: String
end

def scanned() -> Result[List[Decl]]
  lines = DUMP.split("\n")
  state = lines.reduce(Scan.start("/proj", "/proj"), &Scan.step)
  dump = try JSON.decode("{\"decls\": #{Scan.finish(state)}}", Dump)
  ok(dump.decls)
end

def test_only_the_declarations_of_the_project_are_kept() -> Result[Void]
  decls = try scanned()
  Test.eq(decls.map do |d| d.name end, ["f", "g"])
end

def test_a_location_gets_the_file_and_line_it_left_out() -> Result[Void]
  decls = try scanned()
  try Test.eq(decls[0].loc, Place(cc_file: "/proj/src/a.h", cc_line: 7, col: 5))
  Test.eq(decls[1].loc, Place(cc_file: "/proj/src/a.h", cc_line: 7, col: 6))
end

def test_an_array_of_plain_numbers_is_told_by_its_type() -> Result[Void]
  types = ["\"const unsigned char[300]\"", "\"int[2][3]\"", "\"void *[3]\"", "\"char *[2]\"", "\"int\"", "\"char *\""]
  try Test.eq(types.map do |t| Scan.plain_array?(t) end, [true, true, false, false, false, false])
  Test.eq(Scan.plain_array?("\"const uint8_t[3]\""), false)
end

def test_a_table_of_a_typedef_is_dropped_by_its_numbers_and_kept_by_a_function() -> Result[Void]
  state = TABLES.split("\n").reduce(Scan.start("/proj", "/proj"), &Scan.step)
  dump = try JSON.decode("{\"decls\": #{Scan.finish(state)}}", Names)
  Test.eq(dump.decls.map do |d| d.name end, ["OPS"])
end

def test_a_null_pointer_first_item_is_no_number() -> Result[Void]
  state = NULLS.split("\n").reduce(Scan.start("/proj", "/proj"), &Scan.step)
  dump = try JSON.decode("{\"decls\": #{Scan.finish(state)}}", Names)
  Test.eq(dump.decls.map do |d| d.name end, ["table"])
end

# The scan in C (native/scan.c) gives what the scan in Agentica gives, on the dumps above and on clang's dumps of the C
# fixtures, which hold the system headers.
def test_the_scan_in_c_gives_what_the_scan_in_agentica_gives() -> Result[Void]
  cwd = try Paths.working_directory()
  folder = "#{System.env("TMPDIR").unwrap_or("/tmp")}/cchecker-scan-test-#{System.pid()}"
  try Dir.mkdir_private(folder)
  dumps: List[String] = []
  for text in [DUMP, TABLES, NULLS]
    path = "#{folder}/#{dumps.size}.json"
    try File.write_text(path, text)
    dumps = dumps.push(path)
  end

  # The reference scan is slow: a few fixtures, which include system headers.
  for name in ["specs/fixtures/annotated.c", "specs/fixtures/leak.c", "specs/fixtures/effects/cast_integer.c"]
    path = "#{folder}/#{dumps.size}.json"
    try clang_dump(name, path)
    dumps = dumps.push(path)
  end

  result = same_scans(dumps, cwd)
  for path in dumps
    _ = Path.remove(path)
  end

  _ = Path.remove(folder)
  result
end

# A FIFO that no writer opens (a clang that never started, or was killed before its redirect) ends the copy at its
# timeout, and holds no thread of the compute pool for the rest of the run; a failure before a writer says so.
def test_the_copy_of_a_fifo_that_no_one_opens_ends_at_its_timeout() -> Result[Void]
  folder = "#{System.env("TMPDIR").unwrap_or("/tmp")}/cchecker-fifo-test-#{System.pid()}"
  try Dir.mkdir_private(folder)
  fifo = "#{folder}/0.fifo"
  made = Scan.fifo(fifo)
  copied = Scan.compact(fifo, "#{folder}/0.json", 200)
  # A copy that cannot be written fails at once, before a writer: the caller then stops clang.
  unwritten = Scan.compact(fifo, "#{folder}/missing/0.json", 10_000)
  _ = Path.remove(fifo)
  _ = Path.remove("#{folder}/0.json")
  _ = Path.remove(folder)
  try made
  try Test.eq(error_of(copied), Scan.TIMED_OUT)
  Test.eq(error_of(unwritten).start_with?(Scan.UNSTARTED), true)
end

def error_of(copied: Result[List[String]]) -> String
  case copied
    ok(_) -> "copied"
    error(message) -> "#{message}"
  end
end

# Dumps that clang does not write but a file may hold: CRLF line ends and no final one, and a location with a line
# longer than the 1 MiB block of the C scan after its `col`, then a `"cc_file": ` line of its own, which is no place.
def test_the_scan_in_c_reads_crafted_lines_as_the_scan_in_agentica() -> Result[Void]
  folder = "#{System.env("TMPDIR").unwrap_or("/tmp")}/cchecker-crafted-test-#{System.pid()}"
  try Dir.mkdir_private(folder)
  # The checks run after the cleanup: a failed assertion ends the test at once.
  checks = crafted_scans(folder)
  for name in ["crlf.json", "long.json"]
    _ = Path.remove("#{folder}/#{name}")
  end

  _ = Path.remove(folder)
  Test.eq(try checks, [true, true, true, true, true, true, true, true])
end

# For each dump: the C scan keeps some declarations, gives the reference text and reads its compacted copy the same;
# then the place of each pruned dump.
def crafted_scans(folder: String) -> Result[List[Bool]]
  crlf = "#{folder}/crlf.json"
  long = "#{folder}/long.json"
  try File.write_text(crlf, DUMP.strip.replace("\n", "\r\n"))
  # The long line is written in parts: one text call writes at most 1 MiB.
  marker = "XLONGX"
  h = "    {\n      \"kind\": \"FunctionDecl\",\n      \"loc\": {\n        \"col\": 2,\n"
  h = "#{h}        \"tokLen\": \"#{marker}\",\n        \"cc_file\": 1\n      },\n      \"name\": \"h\"\n    },\n"
  parts = DUMP.replace("\"name\": \"g\"\n    },\n", "\"name\": \"g\"\n    },\n#{h}").split(marker)
  try File.write_text(long, parts[0])
  for _ in 0...3
    try File.append_text(long, "x" * 500_000)
  end

  try File.append_text(long, parts[1])
  checks: List[Bool] = []
  for path in [crlf, long]
    fast = try Scan.project_decls(path, "/proj", "/proj", false)
    reference = try Scan.reference_decls(path, "/proj", "/proj")
    checks = checks.push(fast.decls.length > 2).push(fast.decls == reference.decls)
    checks = checks.push(try same_copy(path, "/proj"))
  end

  pruned_crlf = try Scan.project_decls(crlf, "/proj", "/proj")
  # The place of h is that of its own `col` line.
  pruned_long = try Scan.project_decls(long, "/proj", "/proj")
  checks = checks.push(pruned_crlf.decls.include?("\"cc_loc\": [\"/proj/src/a.h\", 7, 6]"))
  ok(checks.push(pruned_long.decls.include?("\"cc_loc\": [\"/proj/src/a.h\", 7, 2]")))
end

def same_scans(dumps: List[String], cwd: String) -> Result[Void]
  for k in 0...dumps.size
    path = dumps[k]
    root = cwd
    if k < 3
      root = "/proj"
    end

    fast = try Scan.project_decls(path, root, root, false)
    reference = try Scan.reference_decls(path, root, root)
    try Test.eq(fast.decls.length > 2, true)
    try Test.eq(fast.decls, reference.decls)
    try Test.eq(fast.oversized, reference.oversized)
    try Test.eq(fast.skipped, reference.skipped)
    # The keys that the pruned text leaves out are none that the rules read: both give the same unit.
    pruned = try Scan.project_decls(path, root, root)
    try Test.eq(pruned.decls.length < fast.decls.length, true)
    full_unit = try UnitReader.read(try JSON.parse(fast.decls))
    pruned_unit = try UnitReader.read(try JSON.parse(pruned.decls))
    try Test.eq(pruned_unit, full_unit)
    try Test.eq(try same_copy(path, root), true)
  end

  ok()
end

# Whether the copy of a dump by `Scan.compact`, with its indents cut short, scans as the dump, pruned and not.
def same_copy(path: String, root: String) -> Result[Bool]
  copy = "#{path}.copy"
  raws = try Scan.compact(path, copy, 10_000)
  copied = Scan.decls_in(copy, raws, root, root, false)
  copied_pruned = Scan.decls_in(copy, raws, root, root)
  _ = Path.remove(copy)
  fast = try Scan.project_decls(path, root, root, false)
  pruned = try Scan.project_decls(path, root, root)
  ok(try copied == fast and try copied_pruned == pruned)
end

# The dump of a C file as the rules ask clang for it.
def clang_dump(source: String, path: String) -> Result[Void]
  script = "exec clang \"$@\" > \"$CCHECKER_DUMP\""
  args = [
    "-c", script, "clang", "-w", "-DCCHECKER_AST", "-Iinclude", "-fsyntax-only", "-Xclang", "-ast-dump=json", source,
  ]

  process = try Process.spawn_captured("sh", args, Process.Options(timeout_ms: 30_000, env: {"CCHECKER_DUMP": path}))
  code = try Process.wait(process, 30_000)
  Process.close(process)
  Test.eq(code, 0)
end
