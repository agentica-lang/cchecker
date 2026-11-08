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

## Returns the folder of an absolute path.
export def parent(path: String) -> String
  parts = path.split("/")
  folder = parts.take(parts.size - 1).join("/")
  if folder == ""
    return "/"
  end

  return folder
end
