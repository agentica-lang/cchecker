Feature: Laws of the rules on generated C files
  Each scenario generates small C files with the `prop` package (specs/props.agc), runs cchecker on each and checks a
  law. A case that breaks it is shrunk, and the failure shows the seed and the C file; CCHECKER_PROP_SEED=SEED runs
  the same cases again. The fast tier runs a few cases; the scenarios tagged @slow run many, in rows that each stay
  within the 30 s of a scenario.

  Scenario: A blocking function stored in a table is always found through it
    Then cchecker finds the blocking function of 15 generated tables

  Scenario: A function stored in a table that does not block is never blamed
    Then cchecker finds nothing in 10 generated tables of a function that does not block

  @slow
  Scenario Outline: A blocking function stored in a table is always found through it, on many cases (<batch>)
    Then cchecker finds the blocking function of 100 generated tables

    Examples:
      | batch |
      | 1     |
      | 2     |
      | 3     |
      | 4     |
      | 5     |

  @slow
  Scenario Outline: A function stored in a table that does not block is never blamed, on many cases (<batch>)
    Then cchecker finds nothing in 100 generated tables of a function that does not block

    Examples:
      | batch |
      | 1     |
      | 2     |
