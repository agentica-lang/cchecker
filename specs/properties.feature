Feature: Laws of the rules on generated C files
  Each scenario generates small C files with the `prop` package (specs/props.agc), runs cchecker on each and checks a
  law. A case that breaks it is shrunk, and the failure shows the seed and the C file. The fast tier runs a few cases;
  the scenarios tagged @slow run many, in several scenarios so that each stays within the 30 s of a scenario.

  Scenario: A blocking function stored in a table is always found through it
    Then cchecker finds the blocking function of 15 generated tables

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
