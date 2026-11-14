import ImageSize from "../src/campfire/image_size"

private

def main() -> Void
  Test.run([
    Test.test("the size is read from the header of each format") do
      try Test.eq(size("89504e470d0a1a0a0000000d4948445200000280000001e00806000000"), "640x480")
      try Test.eq(size("4749463839612c01c800"), "300x200")
      try Test.eq(size("ffd8ffe000044a46ffc2001108006400c8"), "200x100")
      try Test.eq(size("52494646000000005745425056503820000000000000009d012a90012c01"), "400x300")
      try Test.eq(size("5249464600000000574542505650384c000000002fe743bb00"), "1000x750")
      Test.eq(size("5249464600000000574542505650385800000000000000001f4e00973a00"), "20000x15000")
    end,
    Test.test("a JPEG turned a quarter by its EXIF orientation has its sides swapped") do
      Test.eq(
        size("ffd8ffe100224578696600004d4d002a00000008000101120003000000010006000000000000ffc0001108006400c803"),
        "100x200",
      )
    end,
    Test.test("a cut header, a zero side, a side over 65535 or another file has no size") do
      try Test.eq(size("89504e470d0a1a0a0000000d49484452000002"), "none")
      try Test.eq(size("4749463839610000c800"), "none")
      try Test.eq(size("89504e470d0a1a0a0000000d49484452c0000000c00000000806000000"), "none")
      try Test.eq(size("89504e470d0a1a0a0000000d4948445200010000000000010806000000"), "none")
      try Test.eq(size("ffd8ffe000044a46ffda"), "none")
      Test.eq(size("255044462d312e34"), "none")
    end,
  ])
end

def size(hex: String) -> String
  case ImageSize.measure(OpenSSL.Digest.hexdecode(hex).unwrap!)
    some(found) -> "#{found.width}x#{found.height}"
    none -> "none"
  end
end
