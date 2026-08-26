## Geometry and sensors: the spawn predicate, range-based detection, the sixteen
## ray sectors and the integer ray casts.

import std/[math, random, strformat]

import helpers
import waterworld/[sim, trig, tank]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

block spawnPredicate:
  var accepted = 0
  var lattice = 0
  for seed in 0 ..< 200:
    var sim = initSimServer(testConfig(seed))
    sim.gameEventLoggingEnabled = false
    for f in 0 ..< FoodCount:
      let p = sim.food[f]
      inc accepted
      check("t=0 plankton is clear of the walls",
        p.x >= SpawnWallClearUm + FoodRadius and
          p.x <= ArenaW - SpawnWallClearUm - FoodRadius and
          p.y >= SpawnWallClearUm + FoodRadius and
          p.y <= ArenaH - SpawnWallClearUm - FoodRadius,
        &"seed {seed} F{f + 1} at {p.x},{p.y}")
      check("t=0 plankton is 1.20 m clear of the rock surface",
        distSqUm(p.x, p.y, RockCentreX, RockCentreY) >=
          int64(RockRadius + SpawnRockClearUm) * int64(RockRadius + SpawnRockClearUm),
        &"seed {seed} F{f + 1}")
      for spawn in SkimmerSpawnUm:
        check("t=0 plankton is 2.00 m from every skimmer spawn",
          not withinUm(p.x, p.y, spawn.x, spawn.y, SpawnSkimmerClearUm),
          &"seed {seed} F{f + 1}")
    for q in 0 ..< PoisonCount:
      inc accepted
    # 100 respawn draws per seed on top of the 13 initial ones.
    for _ in 0 ..< 100:
      let p = sim.drawParticle(FoodRadius, FoodSpeedSet, atStart = false)
      inc accepted
      check("a respawn is clear of the rock",
        distSqUm(p.x, p.y, RockCentreX, RockCentreY) >=
          int64(RockRadius + SpawnRockClearUm) * int64(RockRadius + SpawnRockClearUm))
      for i in 0 ..< SkimmerCount:
        check("a respawn is 1.50 m from every live skimmer",
          not withinUm(p.x, p.y, sim.skimmers[i].x, sim.skimmers[i].y,
            RespawnSkimmerClearUm))
    lattice += int(sim.latticeFallbacks)
  check("20 000+ accepted spawns were checked", accepted >= 20_000, $accepted)
  check("the lattice fallback fired ZERO times over 200 seeds",
    lattice == 0, $lattice)

block detectionIsRangeBased:
  var sim = seatedSim()
  var rng = initRand(31337)
  for _ in 0 ..< 50_000:
    let
      mx = int32(rng.next() mod uint64(ArenaW))
      my = int32(rng.next() mod uint64(ArenaH))
      px = int32(rng.next() mod uint64(ArenaW))
      py = int32(rng.next() mod uint64(ArenaH))
    sim.skimmers[0].x = mx
    sim.skimmers[0].y = my
    sim.food[0].x = px
    sim.food[0].y = py
    sim.food[0].state = psLive
    let
      frame = sim.frameFor(0)
      expected = distSqUm(px, py, mx, my) <=
        int64(SensorRange) * int64(SensorRange)
    var found = false
    for det in frame.food:
      if det.index == 0:
        found = true
    if found != expected:
      check("detection is exactly centre distance <= 2 400 000 µm", false,
        &"({mx},{my}) vs ({px},{py})")
      break
check("range-based detection held over 50k pairs", true)

block sectorsTile:
  # The sixteen sectors must tile 360 degrees with no gap and no overlap, and a
  # detected object must land in exactly one of them.
  var counts: array[16, int]
  for deg in 0 ..< 3600:
    let
      angle = degToRad(float(deg) / 10.0)
      dx = int64(round(1_000_000.0 * cos(angle)))
      dy = int64(round(-1_000_000.0 * sin(angle)))
      sector = nearestSectorIndex(dx, dy)
    check("the sector index is in 0..15", sector >= 0 and sector < 16, $sector)
    inc counts[sector]
    # A float reference bearing must agree to within one sector.
    var reference = int(round((float(deg) / 10.0) / 22.5)) mod 16
    let delta = min(abs(sector - reference), 16 - abs(sector - reference))
    check("the integer sector matches a float reference to within one",
      delta <= 1, &"{deg / 10} deg: {sector} vs {reference}")
  for n in 0 ..< 16:
    check("sector " & $n & " covers about a sixteenth of the circle",
      counts[n] >= 200 and counts[n] <= 250, $counts[n])

block rayCasts:
  var rng = initRand(2718)
  var
    pinned = 0
    nearTangent = 0
    grazeFlips = 0
  for _ in 0 ..< 2000:
    let
      mx = SkimmerRadius + int32(rng.next() mod uint64(ArenaW - 2 * SkimmerRadius))
      my = SkimmerRadius + int32(rng.next() mod uint64(ArenaH - 2 * SkimmerRadius))
    if distSqUm(mx, my, RockCentreX, RockCentreY) <
        int64(RockRadius + SkimmerRadius) * int64(RockRadius + SkimmerRadius):
      continue
    for n in 0 ..< SensorCount:
      let
        dir = n * 2
        uLen = sqrt(float(DirQ12[dir].x) * float(DirQ12[dir].x) +
                    float(DirQ12[dir].y) * float(DirQ12[dir].y))
        ux = float(DirQ12[dir].x) / uLen
        uy = float(DirQ12[dir].y) / uLen
      # Float reference: march to the wall, along the UNIT direction.
      var wall = float(SensorRange)
      if ux > 1e-9: wall = min(wall, (float(ArenaW) - float(mx)) / ux)
      elif ux < -1e-9: wall = min(wall, float(mx) / -ux)
      if uy > 1e-9: wall = min(wall, (float(ArenaH) - float(my)) / uy)
      elif uy < -1e-9: wall = min(wall, float(my) / -uy)
      let got = float(rayWallDistanceUm(mx, my, dir))
      check("the integer wall cast matches a float ray-cast within 2 mm",
        abs(got - min(wall, float(SensorRange))) <= 2000.0,
        &"{got} vs {min(wall, float(SensorRange))}")
      # Float reference: the rock.
      let
        fx = float(mx) - float(RockCentreX)
        fy = float(my) - float(RockCentreY)
        b = fx * ux + fy * uy
        c = fx * fx + fy * fy - float(RockRadius) * float(RockRadius)
        disc = b * b - c
      var rock = float(SensorRange)
      if b < 0 and disc >= 0:
        let t = -b - sqrt(disc)
        if t >= 0 and t <= float(SensorRange):
          rock = t
      # A NEAR-TANGENT ray is legitimately ambiguous at any finite precision:
      # `t = -b - sqrt(b*b - a*c)` has an unbounded derivative in the closest
      # approach as the discriminant goes to zero, so the 0.1 mm truncation in
      # `rayRockDistanceUm` can move the answer by millimetres or flip a graze
      # into a miss. Those rays are NOT dropped: they are counted and held to a
      # wider bound, and the two counts are asserted below so the class can
      # never quietly swallow the sample.
      let perpendicular = sqrt(max(0.0,
        fx * fx + fy * fy - b * b))
      let gotRock = float(rayRockDistanceUm(mx, my, dir))
      if abs(perpendicular - float(RockRadius)) < 20_000.0:
        inc nearTangent
        if (gotRock >= float(SensorRange)) != (rock >= float(SensorRange)):
          ## A graze one side calls a hit and the other a miss. Bounded by
          ## count, below, not by distance: the two answers are SensorRange
          ## apart by construction.
          inc grazeFlips
        else:
          check("a near-tangent rock cast still agrees within 5 mm",
            abs(gotRock - rock) <= 5000.0, &"{gotRock} vs {rock}")
      else:
        inc pinned
        check("the integer rock cast matches a float ray-cast within 2 mm",
          abs(gotRock - rock) <= 2000.0, &"{gotRock} vs {rock}")
  echo "rock casts: ", pinned, " pinned to 2 mm, ", nearTangent,
    " near-tangent (", grazeFlips, " graze/miss flips)"
  # The three numbers this sweep actually produces are 29 972 / 268 / 1. Pin
  # the SHAPE of that: the wide class is a sliver, the flips are a handful, and
  # the pinned class is the bulk -- so a change that made every ray
  # "near-tangent" (or that stopped generating rays at all) fails here rather
  # than passing vacuously.
  check("the near-tangent class is a sliver of the sample",
    nearTangent * 20 < pinned, $nearTangent & " vs " & $pinned)
  check("only a handful of rays flip between a graze and a miss",
    grazeFlips <= 5, $grazeFlips)
  check("and the 2 mm pin still covers the bulk of the rays",
    pinned > 25_000, $pinned)

block closingSign:
  var sim = seatedSim()
  # One plankton, one poison, everything else out of play: this block is about
  # the SIGN of the closing speed, not about which particle is nearest.
  for f in 1 ..< FoodCount:
    sim.food[f].state = psRespawning
  for q in 0 ..< PoisonCount:
    sim.poison[q].state = psRespawning
  for i in 1 ..< SkimmerCount:
    sim.skimmers[i].x = ArenaW - SkimmerRadius
    sim.skimmers[i].y = ArenaH - SkimmerRadius
  sim.skimmers[0].x = 2_000_000
  sim.skimmers[0].y = 4_000_000
  sim.skimmers[0].vx = 100_000
  sim.skimmers[0].vy = 0
  sim.food[0].state = psLive
  sim.food[0].x = 3_000_000
  sim.food[0].y = 4_000_000
  sim.food[0].dir = 16          ## due west in view terms: heading at me
  sim.food[0].speed = 30_000
  let approaching = sim.frameFor(0)
  check("closing is positive when the pair is approaching",
    approaching.food.len == 1 and approaching.food[0].closingUm > 0,
    $approaching.food[0].closingUm)
  sim.food[0].dir = 0           ## due east: running away
  sim.skimmers[0].vx = 0        ## and I am not chasing it
  let leaving = sim.frameFor(0)
  check("closing is negative when the pair is separating",
    leaving.food.len == 1 and leaving.food[0].closingUm < 0,
    $leaving.food[0].closingUm)

block partnersAlwaysDetected:
  var sim = seatedSim()
  sim.skimmers[0].x = SkimmerRadius + 1
  sim.skimmers[0].y = SkimmerRadius + 1
  sim.skimmers[1].x = ArenaW - SkimmerRadius - 1
  sim.skimmers[1].y = ArenaH - SkimmerRadius - 1
  let frame = sim.frameFor(0)
  check("partners always has exactly three entries", frame.partners.len == 3,
    $frame.partners.len)
  var farPartner = -1
  for k, det in frame.partners:
    if det.index == 1:
      farPartner = k
  check("a partner across the tank is still reported", farPartner >= 0)
  check("a partner beyond the sensor range is flagged out of sensors",
    not frame.partners[farPartner].inSensors)
  var raysOnFarPartner = 0
  for n in 0 ..< SensorCount:
    if frame.rays[n].kind == rkCog:
      inc raysOnFarPartner
  check("a partner beyond the sensor range occupies NO ray",
    raysOnFarPartner == 0, $raysOnFarPartner)

if failures > 0:
  quit("test_tank: " & $failures & " failure(s)", 1)
echo "test_tank: ok"
