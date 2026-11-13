## The tools cchecker runs.

## The tools: gcc with its analyzer, clang-tidy, and the rules of cchecker on clang's AST.
enum Tool
  Gcc
  ClangTidy
  Rules
end

## Returns the name of the tool, as the findings and the `--tools` option spell it.
def name(tool: Tool) -> String
  case tool
    Tool.Gcc -> "gcc"
    Tool.ClangTidy -> "clang-tidy"
    Tool.Rules -> "rules"
  end
end

## Returns the tool of a name, or none.
def named(text: String) -> Optional[Tool]
  case text
    "gcc" -> some(Tool.Gcc)
    "clang-tidy" -> some(Tool.ClangTidy)
    "rules" -> some(Tool.Rules)
    _ -> none
  end
end
