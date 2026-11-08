## Reading whole files of any size.

## Returns the text of a file. `File.read_text` stops at 1 MiB, and a compile database or a baseline can be larger.
export def read_all(path: String) -> Result[String]
  handle = try File.open(path)
  chunks: List[Bytes] = []
  while true
    chunk = try File.read_bytes(handle, 1_048_576)
    if chunk.empty?
      break
    end

    chunks = chunks.push(chunk)
  end

  try File.close(handle)
  return String.from_bytes(Bytes.concat(chunks))
end
