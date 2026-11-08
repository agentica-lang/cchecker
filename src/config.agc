## The settings of a project: which families of library knowledge the rules use (`[library]`), the functions that
## are CC_SHORT or CC_HOT roots without a mark in the C (`[roots]`), how the effect rules walk the project's own
## functions (`[effects]`), and what the project assumes of some of them (`[assume]`).
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

# What an unknown key of a file of -c without that table adds: the file may be a manifest that lacks it.
WHOLE_NOTE = " (no [tool.cchecker] table; read as a cchecker file)"

## The settings of a run. `origin` is the file they were read from, as the user wrote it, or "defaults". `off` holds
## the `[library]` flags that are false; `short` and `hot` are the names of `[roots]`. `follow_cold` is
## `[effects] follow_cold`: the walk goes into the functions that never return or are cold. `trusted` and `stops` are
## `[assume] short` and `[assume] stop`: the functions that count as fine for CC_SHORT, and those no walk goes into;
## `short_locks` is `[assume] short_locks`, the classes of the locks that taking is not blocking for CC_SHORT.
export struct Config
  origin: String
  off: Set[String]
  short: List[String]
  hot: List[String]
  follow_cold: Bool = false
  trusted: List[String] = []
  stops: List[String] = []
  short_locks: List[String] = []
end

## Returns the settings of a run in `folder`, the project folder: those of `explicit` (the file of -c) when given.
export def load(explicit: Optional[String], folder: String) -> Result[Config]
  case explicit
    some(path) ->
      text = try read(path)
      document = try parse(path, text)
      case Toml.get(document, TOOL_TABLE)
        ok(table) -> return from_table(path, "#{TOOL_TABLE}.", table)
        error(_) -> return from_table(path, "", document, manifest_note(document))
      end

    none -> return found_in(folder)
  end
end

## Returns the settings of a table: the whole file, or the table of cchecker in a manifest, whose keys start with
## `prefix` in the errors.
export def from_table(origin: String, prefix: String, table: Toml.Value, note: String = "") -> Result[Config]
  config = defaults().with(origin: origin)
  entries = try table_of(origin, TOOL_TABLE, table)
  for key in entries.keys
    value = entries.get(key).unwrap!
    case key
      "library" -> config = config.with(off: try library_of(origin, "#{prefix}library", value, note))
      "roots" ->
        roots = try table_of(origin, "#{prefix}roots", value)
        for name in roots.keys
          path = "#{prefix}roots.#{name}"
          case name
            "short" -> config = config.with(short: try names_of(origin, path, roots.get(name).unwrap!))
            "hot" -> config = config.with(hot: try names_of(origin, path, roots.get(name).unwrap!))
            _ -> return error(unknown(origin, path, note))
          end
        end

      "effects" ->
        effects = try table_of(origin, "#{prefix}effects", value)
        for name in effects.keys
          path = "#{prefix}effects.#{name}"
          case name
            "follow_cold" -> config = config.with(follow_cold: try flag_of(origin, path, effects.get(name).unwrap!))
            _ -> return error(unknown(origin, path, note))
          end
        end

      "assume" ->
        assume = try table_of(origin, "#{prefix}assume", value)
        for name in assume.keys
          path = "#{prefix}assume.#{name}"
          case name
            "short" -> config = config.with(trusted: try names_of(origin, path, assume.get(name).unwrap!))
            "stop" -> config = config.with(stops: try names_of(origin, path, assume.get(name).unwrap!))
            "short_locks" -> config = config.with(short_locks: try names_of(origin, path, assume.get(name).unwrap!))
            _ -> return error(unknown(origin, path, note))
          end
        end

      _ -> return error(unknown(origin, "#{prefix}#{key}", note))
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
  return (
    Known.BLOCKING_FAMILIES.map do |family| family.flag end
      .push(Known.CALLBACKS_FLAG)
      .push(Known.LIBGC_ALLOC_FLAG)
      .push(Known.NONBLOCKING_FLAG)
  )
end

# The note of an unknown key of a file of -c read whole: only a file that looks like a manifest of Agentica (it has a
# `name`) gets it, as it may lack its [tool.cchecker] table; a plain file of cchecker does not.
def manifest_note(document: Toml.Value) -> String
  if Toml.get(document, "name").ok?
    return WHOLE_NOTE
  end

  return ""
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

def library_of(origin: String, path: String, value: Toml.Value, note: String) -> Result[Set[String]]
  entries = try table_of(origin, path, value)
  off: Set[String] = Set.new([])
  known = flags()
  for flag in entries.keys
    if not known.include?(flag)
      return error(unknown(origin, "#{path}.#{flag}", note))
    end

    if not try flag_of(origin, "#{path}.#{flag}", entries.get(flag).unwrap!)
      off = off.add(flag)
    end
  end

  return ok(off)
end

def flag_of(origin: String, path: String, value: Toml.Value) -> Result[Bool]
  case value
    Toml.Value.Bool(on) -> return ok(on)
    _ -> return error("#{origin}: #{path} must be true or false")
  end
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

def unknown(origin: String, path: String, note: String) -> String
  return "#{origin}: #{path} is not a setting of cchecker#{note}"
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
