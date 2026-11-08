## Paths of the findings: absolute while the tools run, relative to the working directory in the output.

## Returns the working directory without a trailing slash (`Path.cwd` keeps the one the shell gave).
export def working_directory() -> Result[String]
  cwd = try Path.cwd()
  if cwd.length > 1 and cwd.end_with?("/")
    return ok(cwd.slice(0, cwd.length - 1))
  end

  return ok(cwd)
end

## Returns `path` made absolute against `base` (a path that is absolute already stays as it is), with `.` and `..`
## taken out.
export def absolute(base: String, path: String) -> Result[String]
  if path.start_with?("/")
    return Path.resolve(path)
  end

  joined = try Path.join([base, path])
  return Path.resolve(joined)
end

## Returns the path relative to `cwd`, or `none` for a path outside of it (a system or a third-party header).
export def inside(cwd: String, path: String) -> Optional[String]
  prefix = cwd + "/"
  if cwd == "/"
    prefix = "/"
  end

  if path.start_with?(prefix)
    return some(path.slice(prefix.length, path.length - prefix.length))
  end

  return none
end

## Returns whether the path, relative to `cwd`, is one of the excluded files or folders or is inside one. An exclusion
## may be written with `./` or `..`, with a trailing slash or as an absolute path, and it matches whole path parts.
export def excluded?(cwd: String, path: String, exclude: List[String]) -> Bool
  return exclude.any? do |item| matches?(cwd, path, item) end
end

## Returns the folder of an absolute path.
export def parent(path: String) -> String
  parts = path.split("/")
  folder = parts.take(parts.size - 1).join("/")
  if folder == ""
    return "/"
  end

  return folder
end

def matches?(cwd: String, path: String, item: String) -> Bool
  full = without_slash(absolute(cwd, item).unwrap_or(item))
  if full == cwd
    return true
  end

  case inside(cwd, full)
    some(relative) -> return path == relative or path.start_with?(relative + "/")
    none -> return false
  end
end

# Path.resolve keeps the slash of a path that ends with one.
def without_slash(path: String) -> String
  if path.length > 1 and path.end_with?("/")
    return without_slash(path.slice(0, path.length - 1))
  end

  return path
end
