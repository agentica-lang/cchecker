## cchecker: gcc -fanalyzer and clang-tidy on C files, in one command with one output format.

import App from "src/app"
import OP from "std/option_parser"
import Options from "src/options"

def main() -> Void
  parsed = Options.parse(System.args())
  options = OP.run!(parsed)
  case App.run(options)
    ok(code) -> System.exit(code)
    error(message) ->
      IO.warn("cchecker: #{message}")
      System.exit(2)
  end
end
