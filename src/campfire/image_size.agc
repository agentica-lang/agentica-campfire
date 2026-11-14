## The width and the height of a PNG, GIF, JPEG or WebP image, read from its header as `ActiveStorage::Analyzer::
## ImageAnalyzer` finds them, without decoding a pixel. A JPEG whose EXIF orientation turns it a quarter (5 to 8) has
## them swapped, as a browser shows it. `none` when the bytes have no header that this reads.

import Binary from "std/binary"

## How many bytes of the start of a file `measure` reads: a JPEG's EXIF block (at most 64 KiB) comes before its size.
HEAD_BYTES = 131072

struct Size
  width: Int
  height: Int
end

def measure(head: Bytes) -> Optional[Size]
  read = read_size(head)
  return none if not read.ok?

  size = read.unwrap!
  return none if size.width < 1 or size.height < 1

  some(size)
end

private

PNG_MAGIC = "89504e470d0a1a0a"
JPEG_MAGIC = "ffd8"
VP8_START = "9d012a"
EXIF = "457869660000"
QUARTER_TURNS = [5, 6, 7, 8]
ORIENTATION_TAG = 0x0112

def read_size(head: Bytes) -> Result[Size]
  return png(head) if starts_hex?(head, 0, PNG_MAGIC)

  return gif(head) if starts?(head, 0, "GIF87a") or starts?(head, 0, "GIF89a")

  return webp(head) if starts?(head, 0, "RIFF") and starts?(head, 8, "WEBP")

  return jpeg(head) if starts_hex?(head, 0, JPEG_MAGIC)

  error("no image header")
end

def starts?(head: Bytes, at: Int, text: String) -> Bool = holds?(head, at, text.bytes)

def starts_hex?(head: Bytes, at: Int, hex: String) -> Bool = holds?(head, at, OpenSSL.Digest.hexdecode(hex).unwrap!)

def holds?(head: Bytes, at: Int, wanted: Bytes) -> Bool
  head.size >= at + wanted.size and head.slice(at, wanted.size) == wanted
end

def png(head: Bytes) -> Result[Size]
  return error("no IHDR") if not starts?(head, 12, "IHDR")

  ok(Size(width: try Binary.read_u32_be(head, 16), height: try Binary.read_u32_be(head, 20)))
end

def gif(head: Bytes) -> Result[Size]
  ok(Size(width: try Binary.read_u16_le(head, 6), height: try Binary.read_u16_le(head, 8)))
end

def webp(head: Bytes) -> Result[Size]
  if starts?(head, 12, "VP8 ")
    return error("no VP8 start code") if not starts_hex?(head, 23, VP8_START)

    width = (try Binary.read_u16_le(head, 26)).bit_and(0x3fff)
    return ok(Size(width: width, height: (try Binary.read_u16_le(head, 28)).bit_and(0x3fff)))
  end

  if starts?(head, 12, "VP8L")
    return error("no VP8L signature") if try Binary.read_u8(head, 20) != 0x2f

    bits = try Binary.read_u32_le(head, 21)
    return ok(Size(width: 1 + bits.bit_and(0x3fff), height: 1 + bits.shift_right(14).bit_and(0x3fff)))
  end

  return error("no WebP chunk") if not starts?(head, 12, "VP8X")

  ok(Size(width: 1 + try u24_le(head, 24), height: 1 + try u24_le(head, 27)))
end

def u24_le(head: Bytes, at: Int) -> Result[Int]
  low = try Binary.read_u16_le(head, at)
  ok(low + (try Binary.read_u8(head, at + 2)).shift_left(16))
end

# The segments up to the first frame header (SOF0 to SOF15 but DHT, JPG and DAC), noting the EXIF orientation on
# the way.
def jpeg(head: Bytes) -> Result[Size]
  at = 2
  turned = false
  while true
    return error("no marker") if try Binary.read_u8(head, at) != 0xff

    marker = try Binary.read_u8(head, at + 1)
    if marker == 0xff
      at += 1
      next
    end

    return error("no frame header before the scan") if marker == 0xda or marker == 0xd9

    length = try Binary.read_u16_be(head, at + 2)
    return error("a segment shorter than its length") if length < 2

    if marker == 0xe1 and starts_hex?(head, at + 4, EXIF)
      turned = QUARTER_TURNS.include?(orientation(head, at + 10).unwrap_or(1))
    end

    if marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc
      height = try Binary.read_u16_be(head, at + 5)
      width = try Binary.read_u16_be(head, at + 7)
      return ok(Size(width: height, height: width)) if turned

      return ok(Size(width: width, height: height))
    end

    at += 2 + length
  end

  error("unreachable")
end

# The orientation tag of the first IFD of the TIFF block at `tiff`.
def orientation(head: Bytes, tiff: Int) -> Result[Int]
  little = starts?(head, tiff, "II")
  return error("no byte order") if not little and not starts?(head, tiff, "MM")

  first = tiff + try u32(head, tiff + 4, little)
  count = try u16(head, first, little)
  for index in 0...count
    entry = first + 2 + index * 12
    return u16(head, entry + 8, little) if try u16(head, entry, little) == ORIENTATION_TAG
  end

  error("no orientation")
end

def u16(head: Bytes, at: Int, little: Bool) -> Result[Int]
  return Binary.read_u16_le(head, at) if little

  Binary.read_u16_be(head, at)
end

def u32(head: Bytes, at: Int, little: Bool) -> Result[Int]
  return Binary.read_u32_le(head, at) if little

  Binary.read_u32_be(head, at)
end
