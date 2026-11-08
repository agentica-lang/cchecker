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

  Scenario: The lock walk finds every path that leaves the lock held or releases it unheld, and only those
    Then the lock walk agrees with the oracle on 15 generated functions

  @slow
  Scenario Outline: The lock walk agrees with the oracle on many functions (<batch>)
    Then the lock walk agrees with the oracle on 100 generated functions

    Examples:
      | batch |
      | 1     |
      | 2     |
      | 3     |
      | 4     |
      | 5     |

  Scenario: Suppressions hold where the rule says: a trailing comment for its line, one alone for the next line too
    Then suppressions agree with the rule on 15 generated files

  Scenario: With nothing to suppress, every suppression is unused
    Then every suppression is unused in 10 generated files with nothing to suppress

  @slow
  Scenario Outline: Suppressions agree with the rule on many files (<batch>)
    Then suppressions agree with the rule on 100 generated files

    Examples:
      | batch |
      | 1     |
      | 2     |
      | 3     |
      | 4     |
      | 5     |

  @slow
  Scenario Outline: With nothing to suppress, every suppression is unused, on many files (<batch>)
    Then every suppression is unused in 100 generated files with nothing to suppress

    Examples:
      | batch |
      | 1     |
      | 2     |
