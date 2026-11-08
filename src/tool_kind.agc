## The tools cchecker runs.

## The tools: gcc with its analyzer, clang-tidy, and the rules of cchecker on clang's AST.
export enum Tool
  Gcc
  ClangTidy
  Rules
end

## Returns the name of the tool, as the findings and the `--tools` option spell it.
export def name(tool: Tool) -> String
  case tool
    Tool.Gcc -> return "gcc"
    Tool.ClangTidy -> return "clang-tidy"
    Tool.Rules -> return "rules"
  end
end

## Returns the tool of a name, or none.
export def named(text: String) -> Optional[Tool]
  case text
    "gcc" -> return some(Tool.Gcc)
    "clang-tidy" -> return some(Tool.ClangTidy)
    "rules" -> return some(Tool.Rules)
    _ -> return none
  end
end
