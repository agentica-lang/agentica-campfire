## A QR code (ISO/IEC 18004) of some bytes, as `RQRCode` makes for Rails' `QrCodeController`: byte mode, error
## correction level M, the smallest version from 1 to 10 that holds the bytes (213 at most). The mask is always
## pattern 0: a reader takes any mask from the format bits, so the penalty search of the standard is left out. The
## algorithm follows Project Nayuki's reference encoder.

## The most bytes that a code holds.
MAX_BYTES = 213

## The modules of a code, `size` by `size`, row by row: `dark[y * size + x]`.
struct Code
  size: Int
  dark: List[Bool]
end

## The code of `data`, or an error when it holds more than `MAX_BYTES`.
def encode(data: Bytes) -> Result[Code]
  version = 0
  for candidate in 1..MAX_VERSION
    if version == 0 and data.size <= capacity(candidate)
      version = candidate
    end
  end

  return error("a QR code holds at most #{MAX_BYTES} bytes, not #{data.size}") if version == 0

  ok(draw(version, interleaved(version, codewords(version, data))))
end

private

MAX_VERSION = 10
# Level M, per version (index 0 unused): error correction codewords per block and number of blocks.
ECC_PER_BLOCK = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26]
BLOCKS = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5]
# Level M is 0b00 in the format bits.
LEVEL_M = 0
MASK = 0
BYTE_MODE = 4
PAD_BYTES = [0xEC, 0x11]

# The grid of a version: `fixed` marks the function modules, `dark` the dark ones.
struct Grid
  size: Int
  dark: List[Bool]
  fixed: List[Bool]
end

def size_of(version: Int) -> Int = version * 4 + 17

def raw_modules(version: Int) -> Int
  result = (16 * version + 128) * version + 64
  if version >= 2
    aligns = version / 7 + 2
    result = result - ((25 * aligns - 10) * aligns - 55)
  end

  if version >= 7
    result = result - 36
  end

  result
end

def data_codewords(version: Int) -> Int = raw_modules(version) / 8 - ECC_PER_BLOCK[version] * BLOCKS[version]

def count_bits(version: Int) -> Int
  return 8 if version < 10

  16
end

def capacity(version: Int) -> Int = (data_codewords(version) * 8 - 4 - count_bits(version)) / 8

# The data codewords: the mode, the count, the bytes, the terminator and the padding.
def codewords(version: Int, data: Bytes) -> List[Int]
  payload = data.to_a.flat_map do |byte| bits_of(byte, 8) end
  bits = bits_of(BYTE_MODE, 4) + bits_of(data.size, count_bits(version)) + payload

  room = data_codewords(version) * 8
  terminator = [4, room - bits.size].min.unwrap_or(0)
  bits = bits + List.repeat(0, terminator)
  bits = bits + List.repeat(0, (8 - bits.size % 8) % 8)
  words = (0...(bits.size / 8)).map do |k| (0..7).reduce(0) do |word, b| word * 2 + bits[k * 8 + b] end end

  pad = 0
  while words.size < data_codewords(version)
    words = words.push(PAD_BYTES[pad % 2])
    pad = pad + 1
  end

  words
end

def bits_of(value: Int, count: Int) -> List[Int]
  (0...count).map do |i| value.shift_right(count - 1 - i).bit_and(1) end
end

# The blocks with their error correction, interleaved as the standard reads them.
def interleaved(version: Int, data: List[Int]) -> List[Int]
  blocks = BLOCKS[version]
  ecc = ECC_PER_BLOCK[version]
  raw = raw_modules(version) / 8
  short_blocks = blocks - raw % blocks
  short_length = raw / blocks
  divisor = rs_divisor(ecc)
  parts: List[List[Int]] = []
  k = 0
  for i in 0...blocks
    length = short_length - ecc
    if i >= short_blocks
      length = length + 1
    end

    block = data.drop(k).take(length)
    k = k + length
    # A short block gets a placeholder where the long ones have their last data codeword, skipped below.
    filler: List[Int] = []
    if i < short_blocks
      filler = [0]
    end

    parts = parts.push(block + filler + rs_remainder(block, divisor))
  end

  result: List[Int] = []
  for i in 0..short_length
    for j in 0...blocks
      if i != short_length - ecc or j >= short_blocks
        result = result.push(parts[j][i])
      end
    end
  end

  result
end

def gf_multiply(x: Int, y: Int) -> Int
  z = 0
  for i in 0..7
    z = (z * 2).bit_xor(z.shift_right(7) * 0x11D)
    z = z.bit_xor(y.shift_right(7 - i).bit_and(1) * x)
  end

  z
end

def rs_divisor(degree: Int) -> List[Int]
  result = List.repeat(0, degree).set(degree - 1, 1)
  root = 1
  for _i in 0...degree
    for j in 0...degree
      value = gf_multiply(result[j], root)
      if j + 1 < degree
        value = value.bit_xor(result[j + 1])
      end

      result = result.set(j, value)
    end

    root = gf_multiply(root, 0x02)
  end

  result
end

def rs_remainder(data: List[Int], divisor: List[Int]) -> List[Int]
  result = List.repeat(0, divisor.size)
  for byte in data
    factor = byte.bit_xor(result[0])
    result = result.drop(1).push(0)
    for i in 0...divisor.size
      result = result.set(i, result[i].bit_xor(gf_multiply(divisor[i], factor)))
    end
  end

  result
end

def put(grid: Grid, x: Int, y: Int, dark: Bool) -> Grid
  i = y * grid.size + x
  grid.with(dark: grid.dark.set(i, dark), fixed: grid.fixed.set(i, true))
end

def draw(version: Int, words: List[Int]) -> Code
  size = size_of(version)
  grid = Grid(size: size, dark: List.repeat(false, size * size), fixed: List.repeat(false, size * size))
  for i in 0...size
    grid = put(grid, 6, i, i % 2 == 0)
    grid = put(grid, i, 6, i % 2 == 0)
  end

  grid = finder(grid, 3, 3)
  grid = finder(grid, size - 4, 3)
  grid = finder(grid, 3, size - 4)
  positions = alignment_positions(version)
  last = positions.size - 1
  for i in 0...positions.size
    for j in 0...positions.size
      corner = (i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0)
      if not corner
        grid = alignment(grid, positions[i], positions[j])
      end
    end
  end

  grid = format(grid)
  grid = version_bits(grid, version)
  grid = placed(grid, words)
  Code(size: size, dark: masked(grid))
end

def finder(grid: Grid, cx: Int, cy: Int) -> Grid
  result = grid
  for dy in -4..4
    for dx in -4..4
      x = cx + dx
      y = cy + dy
      if x >= 0 and x < grid.size and y >= 0 and y < grid.size
        distance = [dx.abs, dy.abs].max.unwrap_or(0)
        result = put(result, x, y, distance != 2 and distance != 4)
      end
    end
  end

  result
end

def alignment(grid: Grid, cx: Int, cy: Int) -> Grid
  result = grid
  for dy in -2..2
    for dx in -2..2
      result = put(result, cx + dx, cy + dy, [dx.abs, dy.abs].max.unwrap_or(0) != 1)
    end
  end

  result
end

def alignment_positions(version: Int) -> List[Int]
  return [] if version == 1

  count = version / 7 + 2
  step = ((version * 8 + count * 3 + 5) / (count * 4 - 4)) * 2
  size = size_of(version)
  inner = (0...(count - 1)).map do |i| size - 7 - i * step end
  [6] + inner.reverse
end

def format_bits() -> Int
  data = LEVEL_M * 8 + MASK
  rem = data
  for _i in 0...10
    rem = (rem * 2).bit_xor(rem.shift_right(9) * 0x537)
  end

  (data * 1024 + rem).bit_xor(0x5412)
end

def bit?(value: Int, i: Int) -> Bool = value.shift_right(i).bit_and(1) != 0

def format(grid: Grid) -> Grid
  bits = format_bits()
  size = grid.size
  result = grid
  for i in 0..5
    result = put(result, 8, i, bit?(bits, i))
  end

  result = put(result, 8, 7, bit?(bits, 6))
  result = put(result, 8, 8, bit?(bits, 7))
  result = put(result, 7, 8, bit?(bits, 8))
  for i in 9..14
    result = put(result, 14 - i, 8, bit?(bits, i))
  end

  for i in 0..7
    result = put(result, size - 1 - i, 8, bit?(bits, i))
  end

  for i in 8..14
    result = put(result, 8, size - 15 + i, bit?(bits, i))
  end

  put(result, 8, size - 8, true)
end

def version_bits(grid: Grid, version: Int) -> Grid
  return grid if version < 7

  rem = version
  for _i in 0...12
    rem = (rem * 2).bit_xor(rem.shift_right(11) * 0x1F25)
  end

  bits = version * 4096 + rem
  result = grid
  for i in 0..17
    a = grid.size - 11 + i % 3
    b = i / 3
    result = put(result, a, b, bit?(bits, i))
    result = put(result, b, a, bit?(bits, i))
  end

  result
end

# The codewords in the zigzag of two columns, from the bottom right, skipping the function modules and column 6.
def placed(grid: Grid, words: List[Int]) -> Grid
  size = grid.size
  dark = grid.dark
  total = words.size * 8
  i = 0
  right = size - 1
  while right >= 1
    if right == 6
      right = 5
    end

    upward = (right + 1).bit_and(2) == 0
    for vert in 0...size
      for j in 0..1
        x = right - j
        y = vert
        if upward
          y = size - 1 - vert
        end

        cell = y * size + x
        if not grid.fixed[cell] and i < total
          dark = dark.set(cell, bit?(words[i / 8], 7 - i % 8))
          i = i + 1
        end
      end
    end

    right = right - 2
  end

  grid.with(dark: dark)
end

# Mask 0 flips the data modules where x + y is even.
def masked(grid: Grid) -> List[Bool]
  size = grid.size
  (0...(size * size)).map do |cell|
    flip = not grid.fixed[cell] and (cell / size + cell % size) % 2 == 0
    grid.dark[cell] != flip
  end
end
