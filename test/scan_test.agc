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

def test_an_array_of_plain_numbers_is_told_by_its_type() -> Result[Void]
  types = ["\"const unsigned char[300]\"", "\"int[2][3]\"", "\"void *[3]\"", "\"char *[2]\"", "\"int\"", "\"char *\""]
  try Test.eq(types.map do |t| Scan.plain_array?(t) end, [true, true, false, false, false, false])
  return Test.eq(Scan.plain_array?("\"const uint8_t[3]\""), false)
end

def test_a_table_of_a_typedef_is_dropped_by_its_numbers_and_kept_by_a_function() -> Result[Void]
  state = TABLES.split("\n").reduce(Scan.start("/proj", "/proj"), &Scan.step)
  dump = try JSON.decode("{\"decls\": #{Scan.finish(state)}}", Names)
  return Test.eq(dump.decls.map do |d| d.name end, ["OPS"])
end
