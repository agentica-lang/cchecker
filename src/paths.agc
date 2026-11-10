## Paths of the findings: absolute while the tools run, relative to the working directory in the output.

## Returns the working directory without a trailing slash (`Path.cwd` keeps the one the shell gave).
export def working_directory() -> Result[String]
  cwd = try Path.cwd()
  return ok(cwd.slice(0, cwd.length - 1)) if cwd.length > 1 and cwd.end_with?("/")

  ok(cwd)
end

## Returns `path` made absolute against `base` (a path that is absolute already stays as it is), with `.` and `..`
## taken out.
export def absolute(base: String, path: String) -> Result[String]
  return Path.resolve(path) if path.start_with?("/")

  joined = try Path.join([base, path])
  Path.resolve(joined)
end

## Returns the path relative to `cwd`, or `none` for a path outside of it (a system or a third-party header).
export def inside(cwd: String, path: String) -> Optional[String]
  prefix = cwd + "/"
  if cwd == "/"
    prefix = "/"
  end

  return some(path.slice(prefix.length, path.length - prefix.length)) if path.start_with?(prefix)

  none
end

## Returns whether the path, relative to `cwd`, is one of the excluded files or folders or is inside one. An exclusion
## may be written with `./` or `..`, with a trailing slash or as an absolute path, and it matches whole path parts.
export def excluded?(cwd: String, path: String, exclude: List[String]) -> Bool
  exclude.any? do |item| matches?(cwd, path, item) end
end

## Returns the folder of an absolute path.
export def parent(path: String) -> String
  parts = path.split("/")
  folder = parts.take(parts.size - 1).join("/")
  return "/" if folder == ""

  folder
end

def matches?(cwd: String, path: String, item: String) -> Bool
  full = without_slash(absolute(cwd, item).unwrap_or(item))
  return true if full == cwd

  case inside(cwd, full)
    some(relative) -> path == relative or path.start_with?(relative + "/")
    none -> false
  end
end

# Path.resolve keeps the slash of a path that ends with one.
def without_slash(path: String) -> String
  return without_slash(path.slice(0, path.length - 1)) if path.length > 1 and path.end_with?("/")

  path
end
