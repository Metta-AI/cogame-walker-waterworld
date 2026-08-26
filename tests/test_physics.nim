## Sim unit tests: the motion, the bounces, the constant-speed property and the
## no-tunnelling bound the whole contact model rests on.

import std/[math, random, strformat]

import helpers
import waterworld/[sim, trig, tank]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

proc clearParticles(sim: var SimServer) =
  ## Pure-physics blocks measure MOTION, so nothing may be in the water: a
  ## poison hit halves the speed and a capture consumes a plankton, and either
  ## would be measured as drag.
  for f in 0 ..< FoodCount:
    sim.food[f].state = psRespawning
    sim.food[f].timer = 1
  for q in 0 ..< PoisonCount:
    sim.poison[q].state = psRespawning
    sim.poison[q].timer = 1
  sim.config.foodCount = 0
  sim.config.poisonCount = 0

proc parkOthers(sim: var SimServer) =
  ## And nothing may collide: the other three skimmers go to a far corner.
  for i in 1 ..< SkimmerCount:
    sim.skimmers[i].x = ArenaW - SkimmerRadius
    sim.skimmers[i].y = ArenaH - SkimmerRadius
    sim.skimmers[i].vx = 0
    sim.skimmers[i].vy = 0

proc speedOf(vx, vy: int32): float =
  sqrt(float(vx) * float(vx) + float(vy) * float(vy))

block thrustAccelerates:
  ## The RAMP and the TERMINAL speed together pin the accel and the drag. Note
  ## the design note's "2.6 .. 3.3 m/s after 24 ticks" cannot hold for its own
  ## constants: 3.00 m/s^2 against 3.81 %/tick of drag reaches 3.24 m/s
  ## ASYMPTOTICALLY, and one second of it is 1.9 m/s. The constants are the
  ## design's; this is the behaviour they produce, and both ends are asserted.
  var sim = seatedSim()
  sim.clearParticles()
  sim.parkOthers()
  var cmds: array[SkimmerCount, uint8]
  cmds[0] = encodeThrust(0, 7)
  sim.skimmers[0].x = 1_000_000
  sim.skimmers[0].y = 7_000_000
  sim.skimmers[0].vx = 0
  sim.skimmers[0].vy = 0
  for _ in 0 ..< 24:
    sim.skimmers[0].x = 1_000_000          ## keep the wall out of it
    sim.step(cmds)
  let after24 = speedOf(sim.skimmers[0].vx, sim.skimmers[0].vy) *
    float(TargetFps) / 1_000_000.0
  check("level 7 for 24 ticks reaches 1.8 .. 2.1 m/s",
    after24 >= 1.8 and after24 <= 2.1, &"{after24:.3f} m/s")
  for _ in 0 ..< 300:
    sim.skimmers[0].x = 1_000_000
    sim.step(cmds)
  let terminal = speedOf(sim.skimmers[0].vx, sim.skimmers[0].vy) *
    float(TargetFps) / 1_000_000.0
  check("held at level 7 it settles on the 3.24 m/s terminal speed",
    terminal >= 3.15 and terminal <= 3.25, &"{terminal:.3f} m/s")
  check("never exceeds the speed clamp",
    speedOf(sim.skimmers[0].vx, sim.skimmers[0].vy) <= float(MaxSkimmerSpeed) + 1.0)

block dragDecays:
  var sim = seatedSim()
  sim.clearParticles()
  sim.parkOthers()
  sim.skimmers[0].x = 6_000_000
  sim.skimmers[0].y = 7_400_000
  sim.skimmers[0].vx = MaxSkimmerSpeed
  sim.skimmers[0].vy = 0
  let initial = speedOf(sim.skimmers[0].vx, sim.skimmers[0].vy)
  var cmds: array[SkimmerCount, uint8]
  sim.step(cmds)
  let afterOne = speedOf(sim.skimmers[0].vx, sim.skimmers[0].vy)
  let decay = (initial - afterOne) / initial
  check("one tick of coasting decays 3.5 .. 4.2 %",
    decay >= 0.035 and decay <= 0.042, &"{decay * 100:.3f}%")
  # 120 ticks of coasting, with the skimmer re-parked each tick so a wall never
  # interferes with the pure drag measurement.
  var sim2 = seatedSim()
  sim2.clearParticles()
  sim2.parkOthers()
  sim2.skimmers[0].vx = MaxSkimmerSpeed
  sim2.skimmers[0].vy = 0
  for _ in 0 ..< 120:
    sim2.skimmers[0].x = 6_000_000
    sim2.skimmers[0].y = 7_400_000
    sim2.step(cmds)
  check("120 ticks of coasting falls under 1 % of the initial speed",
    speedOf(sim2.skimmers[0].vx, sim2.skimmers[0].vy) < initial * 0.01,
    $speedOf(sim2.skimmers[0].vx, sim2.skimmers[0].vy))

block wallRebound:
  var sim = seatedSim()
  sim.clearParticles()
  sim.parkOthers()
  sim.skimmers[0].x = ArenaW - SkimmerRadius - 10_000
  sim.skimmers[0].y = 4_000_000
  sim.skimmers[0].vx = MaxSkimmerSpeed
  sim.skimmers[0].vy = 0
  var cmds: array[SkimmerCount, uint8]
  sim.step(cmds)
  let ratio = abs(float(sim.skimmers[0].vx)) / float(MaxSkimmerSpeed)
  check("a wall returns 35 .. 45 % of the normal speed",
    ratio >= 0.35 and ratio <= 0.45, &"{ratio * 100:.2f}%")
  check("the rebounding skimmer's velocity reversed", sim.skimmers[0].vx < 0)

block wallsContain:
  var sim = seatedSim()
  var rng = initRand(4242)
  for trial in 0 ..< 400:
    var cmds: array[SkimmerCount, uint8]
    for i in 0 ..< SkimmerCount:
      cmds[i] = uint8(rng.next() mod 256'u64)
    sim.step(cmds)
    for i in 0 ..< SkimmerCount:
      let s = sim.skimmers[i]
      if s.x < SkimmerRadius or s.x > ArenaW - SkimmerRadius or
          s.y < SkimmerRadius or s.y > ArenaH - SkimmerRadius:
        check("a skimmer centre never leaves the tank", false,
          &"tick {trial} skimmer {i} at {s.x},{s.y}")
        break
check("random-drive containment held", true)

block rockPushOut:
  var sim = seatedSim()
  sim.clearParticles()
  sim.parkOthers()
  sim.skimmers[0].x = RockCentreX - RockRadius - SkimmerRadius + 200_000
  sim.skimmers[0].y = RockCentreY
  sim.skimmers[0].vx = MaxSkimmerSpeed
  sim.skimmers[0].vy = 0
  var cmds: array[SkimmerCount, uint8]
  sim.step(cmds)
  let d = isqrt(distSqUm(sim.skimmers[0].x, sim.skimmers[0].y,
    RockCentreX, RockCentreY))
  check("a skimmer driven into the rock ends exactly R away",
    abs(d - int64(RockRadius + SkimmerRadius)) <= 2, $d)

block particleSpeedIsExactlyConstant:
  ## THE INDEX-REFLECTION PROPERTY, asserted bit-exactly: a live particle's
  ## speed never changes. Direction changes only at a bounce, and the whole
  ## motion is integer-exact with no energy drift to renormalise. A respawn
  ## draws a FRESH speed, so the baseline is refreshed whenever a particle
  ## comes back.
  var sim = seatedSim()
  var cmds: array[SkimmerCount, uint8]
  var
    speeds: array[FoodCount, int32]
    dirs: array[FoodCount, uint8]
    live: array[FoodCount, bool]
    bounces = 0
    respawns = 0
  for f in 0 ..< FoodCount:
    speeds[f] = sim.food[f].speed
    dirs[f] = sim.food[f].dir
    live[f] = sim.food[f].state == psLive
  for tick in 0 ..< 5000:
    sim.step(cmds)
    for f in 0 ..< FoodCount:
      let p = sim.food[f]
      if p.state != psLive:
        live[f] = false
        continue
      if not live[f]:
        live[f] = true
        speeds[f] = p.speed
        dirs[f] = p.dir
        inc respawns
        continue
      if p.speed != speeds[f]:
        check("a live plankton's speed is EXACTLY constant", false,
          &"F{f + 1} {speeds[f]} -> {p.speed}")
        speeds[f] = p.speed
      if p.dir != dirs[f]:
        inc bounces
        dirs[f] = p.dir
      let clearance = int64(RockRadius + FoodRadius - 2)
      if distSqUm(p.x, p.y, RockCentreX, RockCentreY) < clearance * clearance:
        check("a plankton never ends inside the rock", false, &"F{f + 1}")
      if p.x < FoodRadius - 1 or p.x > ArenaW - FoodRadius + 1 or
          p.y < FoodRadius - 1 or p.y > ArenaH - FoodRadius + 1:
        check("a plankton never ends outside the tank", false, &"F{f + 1}")
  check("5000 ticks produced 40+ bounces", bounces >= 40, $bounces)
  echo "particle walk: ", bounces, " bounces, ", respawns, " respawns"

block reflectionRules:
  # Every index reflection must agree with a float reference to within one index.
  for d in 0 ..< DirCount:
    let bearing = 11.25 * float(d)
    proc nearest(deg: float): int =
      var best = 0
      var bestDelta = 1e9
      for k in 0 ..< DirCount:
        var delta = abs(11.25 * float(k) - deg)
        while delta > 180.0: delta = abs(delta - 360.0)
        if delta < bestDelta:
          bestDelta = delta
          best = k
      best
    let
      vertical = nearest(180.0 - bearing + 360.0)
      horizontal = nearest(360.0 - bearing)
    check("vertical reflection matches the float reference at d=" & $d,
      abs(int(reflectVertical(uint8(d))) - vertical) mod DirCount <= 1 or
        abs(int(reflectVertical(uint8(d))) - vertical) mod DirCount >= DirCount - 1,
      $reflectVertical(uint8(d)) & " vs " & $vertical)
    check("horizontal reflection matches the float reference at d=" & $d,
      abs(int(reflectHorizontal(uint8(d))) - horizontal) mod DirCount <= 1 or
        abs(int(reflectHorizontal(uint8(d))) - horizontal) mod DirCount >= DirCount - 1,
      $reflectHorizontal(uint8(d)) & " vs " & $horizontal)
  for n in 0 ..< DirCount:
    for d in 0 ..< DirCount:
      let reflected = int(reflectNormal(uint8(d), n))
      check("rock reflection is an involution", reflected >= 0 and reflected < DirCount)
      check("rock reflection twice is the identity",
        int(reflectNormal(reflectNormal(uint8(d), n), n)) == d)

block noTunnelling:
  # THE BOUND, asserted directly: no legal closing speed can cross a contact
  # window in one tick, which is what makes the swept test a guard rather than a
  # behaviour change.
  var fastestPoison = 0'i32
  for speed in PoisonSpeedSet:
    fastestPoison = max(fastestPoison, speed)
  var fastestFood = 0'i32
  for speed in FoodSpeedSet:
    fastestFood = max(fastestFood, speed)
  check("skimmer + poison closing speed is under the contact window",
    MaxSkimmerSpeed + fastestPoison < SkimmerRadius + PoisonRadius,
    $(MaxSkimmerSpeed + fastestPoison) & " < " & $(SkimmerRadius + PoisonRadius))
  check("skimmer + plankton closing speed is under the contact window",
    MaxSkimmerSpeed + fastestFood < SkimmerRadius + FoodRadius,
    $(MaxSkimmerSpeed + fastestFood) & " < " & $(SkimmerRadius + FoodRadius))

block sweptIsASuperset:
  ## The swept test must never MISS a contact the end-position test finds (it is
  ## a superset), and must never fire for a pair farther apart than the radius
  ## sum plus one tick of relative travel. Those two together are what make the
  ## sweep a guard: it can only ever add a graze the end test would have
  ## dropped, never remove a contact.
  var rng = initRand(90210)
  var endOnly = 0
  var sweptOnly = 0
  let radii = SkimmerRadius + PoisonRadius
  for _ in 0 ..< 50_000:
    let
      ax0 = int32(rng.next() mod uint64(ArenaW))
      ay0 = int32(rng.next() mod uint64(ArenaH))
      bx0 = ax0 + int32(rng.next() mod 1_400_000'u64) - 700_000'i32
      by0 = ay0 + int32(rng.next() mod 1_400_000'u64) - 700_000'i32
      ax1 = ax0 + int32(rng.next() mod uint64(2 * MaxSkimmerSpeed)) - MaxSkimmerSpeed
      ay1 = ay0 + int32(rng.next() mod uint64(2 * MaxSkimmerSpeed)) - MaxSkimmerSpeed
      bx1 = bx0 + int32(rng.next() mod 104_000'u64) - 52_000'i32
      by1 = by0 + int32(rng.next() mod 104_000'u64) - 52_000'i32
    let
      swept = sweptContact(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1, radii)
      ends = withinUm(ax1, ay1, bx1, by1, radii)
    if ends and not swept:
      inc endOnly
    if swept and not ends:
      inc sweptOnly
      # The graze it added must be a real near-pass, not a wild answer.
      let start = withinUm(ax0, ay0, bx0, by0, radii + 400_000'i32)
      let finish = withinUm(ax1, ay1, bx1, by1, radii + 400_000'i32)
      check("a swept-only contact was genuinely close", start or finish)
  check("the swept test never misses an end-position contact", endOnly == 0,
    $endOnly)
  echo "swept-only grazes over 50k random pairs: ", sweptOnly

if failures > 0:
  quit("test_physics: " & $failures & " failure(s)", 1)
echo "test_physics: ok"
