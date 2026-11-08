import Scan from "../src/scan"

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

def scanned() -> Result[List[Decl]]
  lines = DUMP.split("\n")
  state = lines.reduce(Scan.start("/proj", "/proj"), &Scan.step)
  dump = try JSON.decode("{\"decls\": #{Scan.finish(state)}}", Dump)
  return ok(dump.decls)
end

def test_only_the_declarations_of_the_project_are_kept() -> Result[Void]
  decls = try scanned()
  return Test.eq(decls.map do |d| d.name end, ["f", "g"])
end

def test_a_location_gets_the_file_and_line_it_left_out() -> Result[Void]
  decls = try scanned()
  try Test.eq(decls[0].loc, Place(cc_file: "/proj/src/a.h", cc_line: 7, col: 5))
  return Test.eq(decls[1].loc, Place(cc_file: "/proj/src/a.h", cc_line: 7, col: 6))
end
