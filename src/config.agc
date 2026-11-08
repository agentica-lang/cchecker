## The settings of a project: which families of library knowledge the rules use (`[library]`) and the functions that
## are CC_SHORT or CC_HOT roots without a mark in the C (`[roots]`).
##
## They come from the first of: the file of `-c` (its `[tool.cchecker]` table when it has one, else the whole file),
## `cchecker.toml` in the project folder, the `[tool.cchecker]` table of `agentica.toml` there, the defaults. An
## unknown key or a value of the wrong type is an error, so that a typo cannot turn a check off.

import Known from "known"
import Toml from "std/toml"

## The settings file that a project folder may hold for cchecker alone.
export OWN_FILE = "cchecker.toml"

## The manifest whose `[tool.cchecker]` table holds the settings when there is no cchecker.toml.
export MANIFEST = "agentica.toml"

## What `origin` says when no file was read.
export DEFAULTS = "defaults"

# The table of cchecker in a manifest.
TOOL_TABLE = "tool.cchecker"

## The settings of a run. `origin` is the file they were read from, as the user wrote it, or "defaults". `off` holds
## the `[library]` flags that are false; `short` and `hot` are the names of `[roots]`.
export struct Config
  origin: String
  off: Set[String]
  short: List[String]
  hot: List[String]
end

## Returns the settings of a run in `folder`, the project folder: those of `explicit` (the file of -c) when given.
export def load(explicit: Optional[String], folder: String) -> Result[Config]
  case explicit
    some(path) ->
      text = try read(path)
      document = try parse(path, text)
      case Toml.get(document, TOOL_TABLE)
        ok(table) -> return from_table(path, "#{TOOL_TABLE}.", table)
        error(_) -> return from_table(path, "", document)
      end

    none -> return found_in(folder)
  end
end

## Returns the settings of a table: the whole file, or the table of cchecker in a manifest, whose keys start with
## `prefix` in the errors.
export def from_table(origin: String, prefix: String, table: Toml.Value) -> Result[Config]
  config = defaults().with(origin: origin)
  entries = try table_of(origin, TOOL_TABLE, table)
  for key in entries.keys
    value = entries.get(key).unwrap!
    case key
      "library" -> config = config.with(off: try library_of(origin, "#{prefix}library", value))
      "roots" ->
        roots = try table_of(origin, "#{prefix}roots", value)
        for name in roots.keys
          path = "#{prefix}roots.#{name}"
          case name
            "short" -> config = config.with(short: try names_of(origin, path, roots.get(name).unwrap!))
            "hot" -> config = config.with(hot: try names_of(origin, path, roots.get(name).unwrap!))
            _ -> return error(unknown(origin, path))
          end
        end

      _ -> return error(unknown(origin, "#{prefix}#{key}"))
    end
  end

  return ok(config)
end

## Returns the settings that hold when no file gives any: every family on, no roots.
export def defaults() -> Config
  return Config(origin: DEFAULTS, off: Set.new([]), short: [], hot: [])
end

## Returns the flags of `[library]` that a run knows, in the order of the README.
export def flags() -> List[String]
  return Known.BLOCKING_FAMILIES.map do |family| family.flag end.push(Known.CALLBACKS_FLAG)
end

# The settings of the project folder: cchecker.toml, else the table of cchecker in agentica.toml, else the defaults.
def found_in(folder: String) -> Result[Config]
  own = try Path.join([folder, OWN_FILE])
  if File.stat(own).ok?
    return from_table(OWN_FILE, "", try parse(OWN_FILE, try read(own)))
  end

  manifest = try Path.join([folder, MANIFEST])
  if File.stat(manifest).ok?
    document = try parse(MANIFEST, try read(manifest))
    case Toml.get(document, TOOL_TABLE)
      ok(table) -> return from_table(MANIFEST, "#{TOOL_TABLE}.", table)
      error(_) -> return ok(defaults())
    end
  end

  return ok(defaults())
end

def library_of(origin: String, path: String, value: Toml.Value) -> Result[Set[String]]
  entries = try table_of(origin, path, value)
  off: Set[String] = Set.new([])
  known = flags()
  for flag in entries.keys
    if not known.include?(flag)
      return error(unknown(origin, "#{path}.#{flag}"))
    end

    case entries.get(flag).unwrap!
      Toml.Value.Bool(on) ->
        if not on
          off = off.add(flag)
        end

      _ -> return error("#{origin}: #{path}.#{flag} must be true or false")
    end
  end

  return ok(off)
end

def names_of(origin: String, path: String, value: Toml.Value) -> Result[List[String]]
  case value
    Toml.Value.Array(items) ->
      names: List[String] = []
      for item in items
        case item
          Toml.Value.Str(name) -> names = names.push(name)
          _ -> return error("#{origin}: #{path} must be a list of function names")
        end
      end

      return ok(names)
    _ -> return error("#{origin}: #{path} must be a list of function names")
  end
end

def table_of(origin: String, path: String, value: Toml.Value) -> Result[Map[String, Toml.Value]]
  case value
    Toml.Value.Table(entries) -> return ok(entries)
    _ -> return error("#{origin}: #{path} must be a table")
  end
end

def unknown(origin: String, path: String) -> String
  return "#{origin}: #{path} is not a setting of cchecker"
end

def read(path: String) -> Result[String]
  case File.read_text(path)
    ok(text) -> return ok(text)
    error(message) -> return error("cannot read the settings file #{path}: #{message}")
  end
end

def parse(origin: String, text: String) -> Result[Toml.Value]
  case Toml.parse(text)
    ok(document) -> return ok(document)
    error(message) -> return error("#{origin}: #{message}")
  end
end
