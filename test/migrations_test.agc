import Migrations from "../src/campfire/repo/migrations"

FOLDER = "src/campfire/repo/migrations"

# The number in `m0007_boosts.agc`, or -1 for a name that is not of that form.
def number_of(file: String) -> Int
  if file.length < 6 or not file.start_with?("m") or not file.end_with?(".agc")
    return -1
  end

  return file.slice(1, 4).to_i().unwrap_or(-1)
end

def main() -> Void
  Test.run([
    Test.test("the list of migrations has one entry per file, numbered like the file, in order") do
      files = Dir.list(FOLDER).unwrap!.select do |file| file.end_with?(".agc") end
      from_files = files.map do |file| number_of(file) end
      from_list = Migrations.all().map do |migration| migration.version end
      try Test.assert(not from_files.include?(-1), "a file that is not mNNNN_name.agc: #{files}")
      Test.eq(from_list, from_files)
    end,
  ])
end
