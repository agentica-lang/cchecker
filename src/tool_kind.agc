## The tools cchecker runs.

## The tools: gcc with its analyzer, and clang-tidy.
export enum Tool
  Gcc
  ClangTidy
end

## Returns the name of the tool, as the findings and the `--tools` option spell it.
export def name(tool: Tool) -> String
  case tool
    Tool.Gcc -> return "gcc"
    Tool.ClangTidy -> return "clang-tidy"
  end
end

## Returns the tool of a name, or none.
export def named(text: String) -> Optional[Tool]
  case text
    "gcc" -> return some(Tool.Gcc)
    "clang-tidy" -> return some(Tool.ClangTidy)
    _ -> return none
  end
end
