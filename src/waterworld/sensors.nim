## `frameFor` — the ONE function that builds a skimmer's percept. The seat's
## websocket frame filter, the LLM user message and the board's ray drawing all
## read exactly what it returns; there is no second path, which is what makes
## `tests/test_locality.nim` a real invariant rather than a spot check.
##
## NO FLOATING POINT. The frame carries INTEGER geometry (µm distances, µm/tick
## closing speeds, sector indices, raw offsets); the degrees a policy is shown
## are formatted from those integers one layer up, in `decide.nim`, which is
## outside the determinism boundary and may use floats.
##
## Detection is RANGE-based, not ray-based: a particle is detected by skimmer
## `i` iff the distance between centres is <= SensorRange. That is a deliberate
## departure from a literal ray sensor — a 0.16 m particle at 2.40 m subtends
## 7.6 deg and would slip between 22.5 deg rays, producing a percept that is
## confusing to a spectator and arbitrary to a policy. Nothing hides between
## rays. The sixteen rays are the PRESENTATION of that percept.
##
## The other three skimmers are detected at ANY range: the pod shares a
## transponder. Capture needs two bodies on one particle at one instant with no
## communication channel of any kind, so with partners invisible beyond 2.40 m
## in a 12 x 8 m tank rendezvous would be luck, not play. Prey stays hidden;
## teammates do not. A partner beyond SensorRange occupies NO ray.

import sim_types, trig, tank

type
  RayKind* = enum
    rkClear = "clear"
    rkFood = "food"
    rkPoison = "poison"
    rkCog = "cog"
    rkRock = "rock"
    rkWall = "wall"

  Ray* = object
    kind*: RayKind
    distUm*: int32       ## hit distance, capped at SensorRange
    closingUm*: int32    ## radial closing speed, µm/tick (0 for rock/wall)

  Detection* = object
    index*: int32        ## particle id index, or skimmer index for a partner
    dx*, dy*: int32      ## offset from me, SIM components (y down)
    distUm*: int32
    closingUm*: int32
    sector*: int32       ## 0..15, which ray reports it
    vx*, vy*: int32      ## the object's velocity, µm/tick
    x*, y*: int32        ## the object's centre, µm
    stun*: int32         ## partners only
    inSensors*: bool     ## partners only

  SensorFrame* = object
    skimmer*: int32
    rays*: array[SensorCount, Ray]
    food*: seq[Detection]
    poison*: seq[Detection]
    partners*: seq[Detection]

proc closingSpeed(dx, dy, dvx, dvy: int32, distUm: int32): int32 =
  ## -(v_object - v_self) . rhat, in µm/tick: positive means approaching.
  if distUm <= 0:
    return 0
  let dot = int64(dvx) * int64(dx) + int64(dvy) * int64(dy)
  int32(-(dot div int64(distUm)))

proc frameFor*(sim: SimServer, i: int): SensorFrame =
  ## The percept of skimmer `i`.
  result.skimmer = int32(i)
  let
    me = sim.skimmers[i]
    reach = int32(sim.config.sensorRangeUm)

  # --- what is in range ----------------------------------------------------
  for f in 0 ..< sim.config.foodCount:
    let p = sim.food[f]
    if p.state != psLive:
      continue
    let dSq = distSqUm(p.x, p.y, me.x, me.y)
    if dSq > int64(reach) * int64(reach):
      continue
    let
      dx = p.x - me.x
      dy = p.y - me.y
      dist = int32(isqrt(dSq))
      pvx = int32((int64(p.speed) * int64(DirQ12[int(p.dir)].x)) div int64(Q12))
      pvy = int32((int64(p.speed) * int64(DirQ12[int(p.dir)].y)) div int64(Q12))
    result.food.add Detection(
      index: int32(f), dx: dx, dy: dy, distUm: dist,
      closingUm: closingSpeed(dx, dy, pvx - me.vx, pvy - me.vy, dist),
      sector: int32(nearestSectorIndex(int64(dx), int64(dy))),
      vx: pvx, vy: pvy, x: p.x, y: p.y, stun: 0, inSensors: true)

  for q in 0 ..< sim.config.poisonCount:
    let p = sim.poison[q]
    if p.state != psLive:
      continue
    let dSq = distSqUm(p.x, p.y, me.x, me.y)
    if dSq > int64(reach) * int64(reach):
      continue
    let
      dx = p.x - me.x
      dy = p.y - me.y
      dist = int32(isqrt(dSq))
      pvx = int32((int64(p.speed) * int64(DirQ12[int(p.dir)].x)) div int64(Q12))
      pvy = int32((int64(p.speed) * int64(DirQ12[int(p.dir)].y)) div int64(Q12))
    result.poison.add Detection(
      index: int32(q), dx: dx, dy: dy, distUm: dist,
      closingUm: closingSpeed(dx, dy, pvx - me.vx, pvy - me.vy, dist),
      sector: int32(nearestSectorIndex(int64(dx), int64(dy))),
      vx: pvx, vy: pvy, x: p.x, y: p.y, stun: 0, inSensors: true)

  # --- the transponder: every partner, at any range -------------------------
  for j in 0 ..< SkimmerCount:
    if j == i:
      continue
    let other = sim.skimmers[j]
    let
      dx = other.x - me.x
      dy = other.y - me.y
      dist = int32(isqrt(distSqUm(other.x, other.y, me.x, me.y)))
    result.partners.add Detection(
      index: int32(j), dx: dx, dy: dy, distUm: dist,
      closingUm: closingSpeed(dx, dy, other.vx - me.vx, other.vy - me.vy, dist),
      sector: int32(nearestSectorIndex(int64(dx), int64(dy))),
      vx: other.vx, vy: other.vy, x: other.x, y: other.y,
      stun: other.stun, inSensors: dist <= reach)

  # --- the sixteen rays -----------------------------------------------------
  for n in 0 ..< SensorCount:
    let dir = n * 2
    var
      best = min(rayWallDistanceUm(me.x, me.y, dir), reach)
      kind = rkWall
      closing = 0'i32
    let rock = rayRockDistanceUm(me.x, me.y, dir)
    if rock < best:
      best = rock
      kind = rkRock
      closing = 0
    for det in result.food:
      if int(det.sector) == n and det.distUm < best:
        best = det.distUm
        kind = rkFood
        closing = det.closingUm
    for det in result.poison:
      if int(det.sector) == n and det.distUm < best:
        best = det.distUm
        kind = rkPoison
        closing = det.closingUm
    for det in result.partners:
      if det.inSensors and int(det.sector) == n and det.distUm < best:
        best = det.distUm
        kind = rkCog
        closing = det.closingUm
    if best >= reach:
      best = reach
      kind = rkClear
      closing = 0
    result.rays[n] = Ray(kind: kind, distUm: best, closingUm: closing)

proc nearestFood*(frame: SensorFrame): int =
  ## Index into `frame.food` of the nearest detected plankton, or -1.
  result = -1
  var best = high(int32)
  for k, det in frame.food:
    if det.distUm < best:
      best = det.distUm
      result = k

proc nearestPoison*(frame: SensorFrame): int =
  result = -1
  var best = high(int32)
  for k, det in frame.poison:
    if det.distUm < best:
      best = det.distUm
      result = k

proc foodDetection*(frame: SensorFrame, foodIndex: int): int =
  ## Index into `frame.food` of a named plankton, or -1 when it is not
  ## currently detected — which is the ONLY sense in which a target exists.
  result = -1
  for k, det in frame.food:
    if int(det.index) == foodIndex:
      return k

proc partnerDetection*(frame: SensorFrame, skimmer: int): int =
  result = -1
  for k, det in frame.partners:
    if int(det.index) == skimmer:
      return k

proc nearestPartner*(frame: SensorFrame): int =
  result = -1
  var best = high(int32)
  for k, det in frame.partners:
    if det.distUm < best:
      best = det.distUm
      result = k
