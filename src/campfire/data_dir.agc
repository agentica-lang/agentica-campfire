## The folder for the files of the app. It holds the database, which has password digests and tokens, so every folder
## that this makes is private to the user that runs the app.

## Makes the folder `path` and the parents that are missing, each with mode 0700, and leaves a folder that exists as it
## is. SQLite makes `campfire.db` with the umask, so the private folder is what keeps others out of it.
export def ensure(path: String) -> Result[Void]
  parts = path.split("/")
  current = ""
  for index in 0...parts.length
    part = parts[index]
    # A leading `/` gives an empty first part, which starts an absolute path; an empty part later is a `//`.
    if index == 0
      current = part
    elsif part.empty?
      next
    else
      current = "#{current}/#{part}"
    end

    if not current.empty? and not File.stat(current).ok?
      try Dir.mkdir_private(current)
    end
  end

  ok()
end
