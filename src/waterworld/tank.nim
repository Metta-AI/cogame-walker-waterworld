## The tank: fixed geometry, the seeded draws (`perm`, the initial particle
## table, every respawn), the bounded spawn sampler, and the swept-contact test.
##
## NO FLOATING POINT.
##
## RANDOMNESS. Exactly one seeded stream, and every draw goes through
## `drawInt`, which steps `std/random`'s **uint64 domain** (`rng.next()`). No
## draw ever touches `rand(int)`, whose `int` is 32-bit under `--cpu:wasm32` and
## 64-bit natively — that difference alone would fork the hash chain between the
## server and the browser. A monotonic `rngDraws` counter is mixed into
## `gameHash`, so a divergence in *how many* draws a build took is caught at the
## tick it happens rather than as a mysterious position mismatch later.

import std/random

import sim_types, trig

proc drawInt*(sim: var SimServer, lo, hi: int32): int32 =
  ## One uniform draw in `[lo, hi]`, inclusive, from the episode's only stream.
  inc sim.rngDraws
  if hi <= lo:
    return lo
  let span = uint64(int64(hi) - int64(lo) + 1'i64)
  int32(int64(lo) + int64(sim.rng.next() mod span))

proc distSqUm*(ax, ay, bx, by: int32): int64 {.inline.} =
  let
    dx = int64(ax) - int64(bx)
    dy = int64(ay) - int64(by)
  dx * dx + dy * dy

proc withinUm*(ax, ay, bx, by, limit: int32): bool {.inline.} =
  distSqUm(ax, ay, bx, by) <= int64(limit) * int64(limit)

proc rockNormalIndex*(x, y: int32): int {.inline.} =
  ## The DirQ12 index nearest the outward normal at a point on the rock. A
  ## point exactly at the centre has no normal; index 0 is the documented
  ## fallback so the reflection stays defined.
  let
    dx = int64(x) - int64(RockCentreX)
    dy = int64(y) - int64(RockCentreY)
  if dx == 0 and dy == 0:
    return 0
  nearestDirIndex(dx, dy)

proc pushOutOfRock*(x, y: var int32, clearance: int32) =
  ## Moves a centre that is inside `clearance` of the rock centre out to exactly
  ## `clearance` along the outward normal. Integer, isqrt-based.
  let dSq = distSqUm(x, y, RockCentreX, RockCentreY)
  if dSq >= int64(clearance) * int64(clearance):
    return
  let d = isqrt(dSq)
  if d == 0:
    x = RockCentreX + clearance
    y = RockCentreY
    return
  let
    dx = int64(x) - int64(RockCentreX)
    dy = int64(y) - int64(RockCentreY)
  x = int32(int64(RockCentreX) + (dx * int64(clearance)) div d)
  y = int32(int64(RockCentreY) + (dy * int64(clearance)) div d)

# ---------------------------------------------------------------------------
#  The swept-contact test
# ---------------------------------------------------------------------------
# A contact counts if the two bodies overlap at the tick's END positions OR if
# the segment travelled by their RELATIVE displacement passes within rA + rB of
# the origin. The end-position test alone is already enough given the
# no-tunnelling bound asserted in tests/test_physics.nim
# (MaxSkimmerSpeed + max(PoisonSpeedSet) < SkimmerRadius + PoisonRadius), so the
# sweep is belt and braces — and testable, which a comment is not.
#
# The sweep runs in DECIMILLIMETRES (0.1 mm), not micrometres, and that is
# deliberate: the closest-point-on-segment algebra squares a dot product, and at
# µm scale `cross*cross` overflows int64 for legal inputs. At 0.1 mm scale every
# intermediate stays under 5e14, comfortably inside int64. Truncating to 0.1 mm
# is exact integer arithmetic on both builds, and the resolution (0.1 mm against
# a 160-240 mm radius) is far finer than the contact it decides. The END-position
# test below is exact at µm.

proc sweptContact*(
  ax0, ay0, ax1, ay1: int32,
  bx0, by0, bx1, by1: int32,
  radiusSum: int32
): bool =
  ## True when body A (start -> end) and body B (start -> end) come within
  ## `radiusSum` of each other at any point during the tick.
  if withinUm(ax1, ay1, bx1, by1, radiusSum):
    return true
  # TOTALITY GUARD. The sweep is only meaningful for a pair that MOVED by at
  # most a tick's worth of legal motion; a body that teleported (a particle
  # respawning at a fresh seeded point) has no swept path at all, and squaring
  # its tank-sized displacement would overflow. Callers already skip a particle
  # that respawned this tick — this makes the function total either way.
  const MaxTravelUm = 2 * MaxSkimmerSpeed
  if abs(int64(ax1) - int64(ax0)) > MaxTravelUm or
      abs(int64(ay1) - int64(ay0)) > MaxTravelUm or
      abs(int64(bx1) - int64(bx0)) > MaxTravelUm or
      abs(int64(by1) - int64(by0)) > MaxTravelUm:
    return false
  let
    r0x = (int64(ax0) - int64(bx0)) div 100'i64
    r0y = (int64(ay0) - int64(by0)) div 100'i64
    r1x = (int64(ax1) - int64(bx1)) div 100'i64
    r1y = (int64(ay1) - int64(by1)) div 100'i64
    dx = r1x - r0x
    dy = r1y - r0y
    rMm = int64(radiusSum) div 100'i64
  let den = dx * dx + dy * dy
  if den == 0:
    return r0x * r0x + r0y * r0y <= rMm * rMm
  # Closest point of the segment r0 -> r1 to the origin.
  let numerator = -(r0x * dx + r0y * dy)
  if numerator <= 0:
    return r0x * r0x + r0y * r0y <= rMm * rMm
  if numerator >= den:
    return r1x * r1x + r1y * r1y <= rMm * rMm
  # Perpendicular distance to the infinite line, compared without dividing:
  # (r0 x d)^2 <= rMm^2 * |d|^2.
  let cross = r0x * dy - r0y * dx
  cross * cross <= rMm * rMm * den

# ---------------------------------------------------------------------------
#  Seeded spawns
# ---------------------------------------------------------------------------

proc spawnAcceptable(
  sim: SimServer, x, y, radius: int32, atStart: bool
): bool =
  ## The acceptance predicate every particle spawn obeys, at t = 0 and at every
  ## respawn: clear of the rock, clear of the walls, and clear of the skimmers.
  if x < SpawnWallClearUm + radius or x > ArenaW - SpawnWallClearUm - radius:
    return false
  if y < SpawnWallClearUm + radius or y > ArenaH - SpawnWallClearUm - radius:
    return false
  if distSqUm(x, y, RockCentreX, RockCentreY) <
      int64(RockRadius + SpawnRockClearUm) * int64(RockRadius + SpawnRockClearUm):
    return false
  if atStart:
    for spawn in SkimmerSpawnUm:
      if withinUm(x, y, spawn.x, spawn.y, SpawnSkimmerClearUm):
        return false
  else:
    for skimmer in sim.skimmers:
      if withinUm(x, y, skimmer.x, skimmer.y, RespawnSkimmerClearUm):
        return false
  true

proc latticePoint(
  sim: SimServer, radius: int32, atStart: bool
): tuple[x, y: int32] =
  ## Degrade-never-hang applies to sampling too: after SpawnAttempts rejected
  ## draws the spawn takes the first free point of a fixed 0.50 m lattice
  ## scanned in raster order. An unbounded rejection loop inside a hashed step
  ## function is exactly the hang the rule forbids.
  var y = SpawnLatticeStepUm
  while y < ArenaH:
    var x = SpawnLatticeStepUm
    while x < ArenaW:
      if sim.spawnAcceptable(x, y, radius, atStart):
        return (x, y)
      x += SpawnLatticeStepUm
    y += SpawnLatticeStepUm
  (ArenaW div 2'i32, SpawnWallClearUm + radius)

proc drawSpawn*(
  sim: var SimServer, radius: int32, atStart: bool
): tuple[x, y: int32] =
  ## A bounded rejection sample of one legal particle position.
  for _ in 0 ..< SpawnAttempts:
    let
      x = sim.drawInt(SpawnWallClearUm + radius, ArenaW - SpawnWallClearUm - radius)
      y = sim.drawInt(SpawnWallClearUm + radius, ArenaH - SpawnWallClearUm - radius)
    if sim.spawnAcceptable(x, y, radius, atStart):
      return (x, y)
  inc sim.latticeFallbacks
  sim.latticePoint(radius, atStart)

proc drawParticle*(
  sim: var SimServer, radius: int32, speeds: openArray[int32], atStart: bool
): Particle =
  ## Position, direction index and speed, in that fixed order — the draw ORDER
  ## is part of the determinism contract, not an implementation detail.
  let spawn = sim.drawSpawn(radius, atStart)
  result = Particle(
    state: psLive,
    x: spawn.x,
    y: spawn.y,
    dir: uint8(sim.drawInt(0'i32, 31'i32)),
    speed: speeds[int(sim.drawInt(0'i32, int32(speeds.len - 1)))],
    timer: 0
  )

proc drawPerm*(sim: var SimServer) =
  ## Fisher-Yates over one dedicated draw, the FIRST thing drawn at t = 0.
  ## Skimmer `i` always spawns at the same point, so `perm` is what makes the
  ## spawn a seat gets — and therefore its first neighbourhood of the tank —
  ## vary per episode. It is never visible to any seat.
  for i in 0 ..< SkimmerCount:
    sim.perm[i] = int32(i)
  for i in countdown(SkimmerCount - 1, 1):
    let j = int(sim.drawInt(0'i32, int32(i)))
    let swapped = sim.perm[i]
    sim.perm[i] = sim.perm[j]
    sim.perm[j] = swapped
  for seat in 0 ..< SkimmerCount:
    sim.seatOf[int(sim.perm[seat])] = int32(seat)

# ---------------------------------------------------------------------------
#  Integer ray casts (the presentation half of the sensor frame)
# ---------------------------------------------------------------------------
# Both casts run in DECIMILLIMETRES for the same overflow reason as the sweep,
# and tests/test_tank.nim pins them against a float reference to within 2 mm.

proc rayWallDistanceUm*(x, y: int32, dir: int): int32 =
  ## Distance from a point to the tank wall along DirQ12[dir], capped at
  ## SensorRange.
  let
    ux = int64(DirQ12[dir].x)
    uy = int64(DirQ12[dir].y)
    # The table entries are ROUNDED, so |u| is within a unit of Q12 but not
    # exactly Q12: scaling by the true length rather than by Q12 is what keeps
    # the cast inside a fraction of a millimetre of a float ray-cast.
    uLen = isqrt(ux * ux + uy * uy)
    px = int64(x) div 100'i64
    py = int64(y) div 100'i64
    wMm = int64(ArenaW) div 100'i64
    hMm = int64(ArenaH) div 100'i64
  var best = int64(SensorRange) div 100'i64
  if ux > 0:
    best = min(best, ((wMm - px) * uLen) div ux)
  elif ux < 0:
    best = min(best, (px * uLen) div (-ux))
  if uy > 0:
    best = min(best, ((hMm - py) * uLen) div uy)
  elif uy < 0:
    best = min(best, (py * uLen) div (-uy))
  int32(max(0'i64, best) * 100'i64)

proc rayRockDistanceUm*(x, y: int32, dir: int): int32 =
  ## Distance from a point to the rock along DirQ12[dir], or SensorRange when
  ## the ray misses it. A point already inside the rock reads 0.
  let
    ux = int64(DirQ12[dir].x)
    uy = int64(DirQ12[dir].y)
    fx = (int64(x) - int64(RockCentreX)) div 100'i64
    fy = (int64(y) - int64(RockCentreY)) div 100'i64
    rMm = int64(RockRadius) div 100'i64
    capMm = int64(SensorRange) div 100'i64
    a = ux * ux + uy * uy
    b = fx * ux + fy * uy
    c = fx * fx + fy * fy - rMm * rMm
  if c <= 0:
    return 0
  if b >= 0:
    return SensorRange           ## pointing away from the rock
  let disc = b * b - a * c
  if disc < 0:
    return SensorRange
  # The ray is p + s*u/|u| with s in 0.1 mm units, so
  # s = (-b - sqrt(b^2 - a*c)) / |u|.
  let tMm = (-b - isqrt(disc)) div isqrt(a)
  if tMm < 0 or tMm > capMm:
    return SensorRange
  int32(tMm * 100'i64)
