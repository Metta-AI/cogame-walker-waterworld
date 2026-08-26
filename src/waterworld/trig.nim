## The only trigonometry in the determinism boundary: a committed 32-entry
## unit-vector table and an integer square root. NO FLOATING POINT.
##
## Entry `d` is the **view** bearing `11.25 deg * d` (0 = right, 90 = up,
## counter-clockwise) expressed in **sim** components, which are y-DOWN — so
## `DirQ12[d] = (round(4096*cos(11.25 deg * d)), round(-4096*sin(11.25 deg * d)))`
## and the sim never negates anything at a call site. Generated once by
## `tools/gen_trig_table.nim` and checked in; `tests/test_determinism.nim`
## re-derives every entry from `math.cos`/`math.sin` and fails on a drift.
##
## Reflections are exact INDEX arithmetic, not vector maths:
##   * vertical wall   (x negated): `d' = (16 - d) mod 32`
##   * horizontal wall (y negated): `d' = (32 - d) mod 32`
##   * the rock, about outward normal index `n`: `d' = (2*n - d + 16) mod 32`

const
  DirCount* = 32
  Q12* = 4096'i32

  DirQ12*: array[DirCount, tuple[x, y: int32]] = [
    ( 4096'i32,     0'i32), ( 4017'i32,  -799'i32), ( 3784'i32, -1567'i32), ( 3406'i32, -2276'i32),
    ( 2896'i32, -2896'i32), ( 2276'i32, -3406'i32), ( 1567'i32, -3784'i32), (  799'i32, -4017'i32),
    (    0'i32, -4096'i32), ( -799'i32, -4017'i32), (-1567'i32, -3784'i32), (-2276'i32, -3406'i32),
    (-2896'i32, -2896'i32), (-3406'i32, -2276'i32), (-3784'i32, -1567'i32), (-4017'i32,  -799'i32),
    (-4096'i32,     0'i32), (-4017'i32,   799'i32), (-3784'i32,  1567'i32), (-3406'i32,  2276'i32),
    (-2896'i32,  2896'i32), (-2276'i32,  3406'i32), (-1567'i32,  3784'i32), ( -799'i32,  4017'i32),
    (    0'i32,  4096'i32), (  799'i32,  4017'i32), ( 1567'i32,  3784'i32), ( 2276'i32,  3406'i32),
    ( 2896'i32,  2896'i32), ( 3406'i32,  2276'i32), ( 3784'i32,  1567'i32), ( 4017'i32,   799'i32)
  ]

proc isqrt*(value: int64): int64 =
  ## Integer square root by Newton's method from an integer seed: the largest
  ## `r` with `r*r <= value`. The ONLY square root in the sim — contact
  ## distances, speed clamps, sensor ranges — and exhaustively unit-tested
  ## below 2^16 and on perfect squares to 2^40.
  if value <= 0:
    return 0
  if value < 4:
    return 1
  var
    r = value
    shift = 0'i64
  # Seed with 2^ceil(bits/2), which is >= sqrt(value) and within a factor of 2.
  while r > 0:
    r = r shr 2
    inc shift
  var guess = 1'i64 shl shift
  # floor(sqrt(high(int64))): keeps guess*guess below the overflow cliff for
  # any input, so the correction loops never trap in the debug build.
  if guess > 3_037_000_499'i64:
    guess = 3_037_000_499'i64
  while true:
    let next = (guess + value div guess) shr 1
    if next >= guess:
      break
    guess = next
  # Newton from above converges to floor(sqrt) or one above it; correct down.
  while guess * guess > value:
    dec guess
  while (guess + 1) * (guess + 1) <= value:
    inc guess
  guess

proc reflectVertical*(dir: uint8): uint8 {.inline.} =
  ## Off a vertical wall: the x-component is negated.
  uint8((16 - int(dir) + 32) mod 32)

proc reflectHorizontal*(dir: uint8): uint8 {.inline.} =
  ## Off a horizontal wall: the y-component is negated.
  uint8((32 - int(dir)) mod 32)

proc reflectNormal*(dir: uint8, normal: int): uint8 {.inline.} =
  ## Off the rock, about the outward normal index `normal`.
  uint8(((2 * normal - int(dir) + 16) mod 32 + 32) mod 32)

proc nearestDirIndex*(dx, dy: int64): int =
  ## The DirQ12 index closest in angle to a SIM-space vector, by maximising the
  ## dot product against the table — the same test as "which 11.25 deg sector
  ## does this bearing fall in", with no arctangent anywhere.
  result = 0
  var best = low(int64)
  for d in 0 ..< DirCount:
    let dot = dx * int64(DirQ12[d].x) + dy * int64(DirQ12[d].y)
    if dot > best:
      best = dot
      result = d

proc nearestSectorIndex*(dx, dy: int64): int =
  ## Which of the SIXTEEN 22.5 deg ray sectors a sim-space vector falls in: the
  ## even DirQ12 entries are the ray directions, so this is nearestDirIndex
  ## restricted to them.
  result = 0
  var best = low(int64)
  for n in 0 ..< 16:
    let d = n * 2
    let dot = dx * int64(DirQ12[d].x) + dy * int64(DirQ12[d].y)
    if dot > best:
      best = dot
      result = n
