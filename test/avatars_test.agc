import Avatars from "../src/campfire/avatars"

private

def main() -> Void
  Test.run([
    Test.test("the initials are the first letter of each word of the name, as User#initials makes them") do
      try Test.eq(Avatars.initials("Ana"), "A")
      try Test.eq(Avatars.initials("Bea Smith"), "BS")
      try Test.eq(Avatars.initials("Mary-Jane O'Neil"), "MJON")
      Test.eq(Avatars.initials(""), "")
    end,
    Test.test("the colour is the one of AVATAR_COLORS at the CRC-32 of the id, as Rails picks it") do
      # Zlib.crc32("1") % 18 and Zlib.crc32("42") % 18 in Ruby, for the table of Users::AvatarsHelper.
      try Test.eq(Avatars.color(1), "#BF7C2A")
      Test.eq(Avatars.color(42), "#D07B53")
    end,
    Test.test("a key is a file in the folders that the Disk service of Rails makes from its first four characters") do
      try Test.eq(
        Avatars.path("/rails/storage/files", "x1s3j8autb7671fkjsjfwutj3z3z").unwrap_or(""),
        "/rails/storage/files/x1/s3/x1s3j8autb7671fkjsjfwutj3z3z",
      )

      try Test.eq(Avatars.path("/files", "../../etc/passwd"), none)
      try Test.eq(Avatars.path("/files", "abc"), none)
      try Test.eq(Avatars.path("/files", "AB12cd34"), none)
      Test.eq(Avatars.path("/files", ""), none)
    end,
  ])
end
