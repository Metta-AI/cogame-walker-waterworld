## The controller: bounded, legal, deterministic command bytes for every
## (state, intent) pair, and each of the five modes doing what it says.

import std/[math, random, strformat]

import helpers
import waterworld/[sim, trig, intents, control]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

proc randomIntent(rng: var Rand, skimmer: int): SkimmerIntent =
  result = defaultIntent()
  result.mode = Mode(int(rng.next() mod uint64(ord(high(Mode)) + 1)))
  result.target = int32(rng.next() mod uint64(FoodCount + 1)) - 1'i32
  result.partner = int32(rng.next() mod uint64(SkimmerCount + 1)) - 1'i32
  if int(result.partner) == skimmer:
    result.partner = -1
  result.waypointXUm = WaypointMinUm +
    int32(rng.next() mod uint64(WaypointMaxXUm - WaypointMinUm))
  result.waypointYUm = WaypointMinUm +
    int32(rng.next() mod uint64(WaypointMaxYUm - WaypointMinUm))
  result.leadTicks = int32(rng.next() mod uint64(MaxLeadTicks + 1))
  result.standoffMm = int32(rng.next() mod uint64(MaxStandoffMm + 1))
  result.throttle255 = int32(rng.next() mod 256'u64)

block boundedBytes:
  var sim = seatedSim()
  var ctl = initControlState()
  var rng = initRand(1234)
  let maxAccel = float(MaxThrustAccel)
  for trial in 0 ..< 3000:
    for i in 0 ..< SkimmerCount:
      sim.skimmers[i].x = SkimmerRadius +
        int32(rng.next() mod uint64(ArenaW - 2 * SkimmerRadius))
      sim.skimmers[i].y = SkimmerRadius +
        int32(rng.next() mod uint64(ArenaH - 2 * SkimmerRadius))
      sim.skimmers[i].vx = int32(rng.next() mod uint64(2 * MaxSkimmerSpeed)) -
        MaxSkimmerSpeed
      sim.skimmers[i].vy = int32(rng.next() mod uint64(2 * MaxSkimmerSpeed)) -
        MaxSkimmerSpeed
    for f in 0 ..< FoodCount:
      sim.food[f].state = psLive
      sim.food[f].x = FoodRadius + int32(rng.next() mod uint64(ArenaW - 2 * FoodRadius))
      sim.food[f].y = FoodRadius + int32(rng.next() mod uint64(ArenaH - 2 * FoodRadius))
    let
      i = int(rng.next() mod uint64(SkimmerCount))
      frame = sim.frameFor(i)
      intent = randomIntent(rng, i)
      cmd = ctl.thrustCommand(sim, i, frame, intent)
      decoded = decodeThrust(cmd)
    check("the command byte decodes to dir 0..31",
      decoded.dir >= 0 and decoded.dir < 32, $decoded.dir)
    check("the command byte decodes to level 0..7",
      decoded.level >= 0 and decoded.level < 8, $decoded.level)
    let implied = float(decoded.level) * maxAccel / 7.0
    check("the implied acceleration is within MaxThrustAccel + 1",
      implied <= maxAccel + 1.0, &"{implied}")
    # The same (state, intent) pair always yields the same byte.
    var ctl2 = ctl
    let again = ctl2.thrustCommand(sim, i, frame, intent)
    check("the controller is a pure function of its inputs", again == cmd,
      &"trial {trial}: {cmd} vs {again}")

block modesDoWhatTheySay:
  var sim = seatedSim()
  var ctl = initControlState()
  # HOLD brakes monotonically to a stop within 96 ticks from full speed.
  sim.skimmers[0].x = 6_000_000
  sim.skimmers[0].y = 7_400_000
  sim.skimmers[0].vx = MaxSkimmerSpeed
  sim.skimmers[0].vy = 0
  var intent = defaultIntent()
  intent.mode = mHold
  intent.throttle255 = 0
  var lastSpeed = float(MaxSkimmerSpeed)
  var stopped = -1
  for tick in 0 ..< 96:
    var cmds: array[SkimmerCount, uint8]
    let frame = sim.frameFor(0)
    cmds[0] = ctl.thrustCommand(sim, 0, frame, intent)
    sim.step(cmds)
    let speed = sqrt(float(sim.skimmers[0].vx) * float(sim.skimmers[0].vx) +
      float(sim.skimmers[0].vy) * float(sim.skimmers[0].vy))
    check("hold never speeds the skimmer up", speed <= lastSpeed + 1.0,
      &"tick {tick}: {speed} > {lastSpeed}")
    lastSpeed = speed
    # Nim's `div` truncates toward zero, so drag cannot take the last unit off:
    # a held skimmer settles at a few µm/tick, which is a fraction of a
    # millimetre per second. That is a standstill, not a drift.
    if speed < 100.0 and stopped < 0:
      stopped = tick
  check("hold brakes to a standstill (under 0.01 m/s) within 96 ticks",
    stopped >= 0, $lastSpeed)

  # SWEEP drives at the waypoint.
  var sweep = defaultIntent()
  sweep.mode = mSweep
  # NOT along y = 4.00 m: the rock sits there and the tangent rule would
  # (correctly) refuse to steer through it. That rule has its own block below.
  sweep.waypointXUm = 10_000_000
  sweep.waypointYUm = 7_400_000
  sim.skimmers[0].x = 2_000_000
  sim.skimmers[0].y = 7_400_000
  sim.skimmers[0].vx = 0
  sim.skimmers[0].vy = 0
  let sweepCmd = ctl.thrustCommand(sim, 0, sim.frameFor(0), sweep)
  let sweepDir = decodeThrust(sweepCmd).dir
  check("sweep thrusts toward the waypoint",
    DirQ12[int(sweepDir)].x > 0, $sweepDir)

  # HUNT aims at a detected plankton, led by lead_ticks.
  var hunt = defaultIntent()
  hunt.mode = mHunt
  hunt.target = 0
  hunt.leadTicks = 8
  hunt.throttle255 = 255
  sim.skimmers[0].x = 2_000_000
  sim.skimmers[0].y = 7_400_000
  sim.food[0].state = psLive
  sim.food[0].x = 3_500_000
  sim.food[0].y = 7_400_000
  sim.food[0].dir = 0
  sim.food[0].speed = 30_000
  let huntCmd = ctl.thrustCommand(sim, 0, sim.frameFor(0), hunt)
  check("hunt thrusts toward the target", DirQ12[int(decodeThrust(huntCmd).dir)].x > 0)

  # An UNDETECTED target falls back to the nearest detected plankton, and with
  # nothing detected at all, to the waypoint. Neither is ever "do nothing".
  var blind = defaultIntent()
  blind.mode = mHunt
  blind.target = 4
  blind.waypointXUm = 10_000_000
  blind.waypointYUm = 7_400_000
  for f in 0 ..< FoodCount:
    sim.food[f].state = psRespawning
  sim.skimmers[0].x = 2_000_000
  sim.skimmers[0].y = 7_400_000
  let blindCmd = ctl.thrustCommand(sim, 0, sim.frameFor(0), blind)
  check("hunt with nothing detected steers at the waypoint",
    DirQ12[int(decodeThrust(blindCmd).dir)].x > 0)

  # ESCORT closes on the named partner.
  var escort = defaultIntent()
  escort.mode = mEscort
  escort.partner = 1
  escort.throttle255 = 255
  sim.skimmers[0].x = 2_000_000
  sim.skimmers[0].y = 7_400_000
  sim.skimmers[1].x = 9_000_000
  sim.skimmers[1].y = 7_400_000
  let escortCmd = ctl.thrustCommand(sim, 0, sim.frameFor(0), escort)
  check("escort thrusts toward the partner",
    DirQ12[int(decodeThrust(escortCmd).dir)].x > 0)

  # AVOID runs from the nearest poison.
  var avoid = defaultIntent()
  avoid.mode = mAvoid
  avoid.throttle255 = 255
  sim.skimmers[0].x = 6_000_000
  sim.skimmers[0].y = 7_000_000
  sim.poison[0].state = psLive
  sim.poison[0].x = 7_000_000
  sim.poison[0].y = 7_000_000
  for q in 1 ..< PoisonCount:
    sim.poison[q].state = psRespawning
  let avoidCmd = ctl.thrustCommand(sim, 0, sim.frameFor(0), avoid)
  check("avoid thrusts away from the poison",
    DirQ12[int(decodeThrust(avoidCmd).dir)].x < 0, $decodeThrust(avoidCmd).dir)

block stunAndPhaseForceCoast:
  var sim = seatedSim()
  var ctl = initControlState()
  var intent = defaultIntent()
  intent.mode = mSweep
  intent.throttle255 = 255
  sim.skimmers[0].stun = 6
  check("a stunned skimmer is forced to coast",
    ctl.thrustCommand(sim, 0, sim.frameFor(0), intent) == 0'u8)
  sim.skimmers[0].stun = 0
  sim.phase = Lobby
  check("any phase other than Playing forces a coast",
    ctl.thrustCommand(sim, 0, sim.frameFor(0), intent) == 0'u8)
  sim.phase = GameOver
  check("game over forces a coast",
    ctl.thrustCommand(sim, 0, sim.frameFor(0), intent) == 0'u8)

block poisonRepulsion:
  ## The repulsion term is RADIAL, so on a bloom that sits exactly on the line
  ## to the goal it cannot sidestep — it can only BRAKE. Both halves are
  ## asserted: the on-path half below (the design note's §Tests 4: the skimmer
  ## does not eat a bloom it is driving straight at) and the beside-the-path
  ## half after it (a wider standoff holds it farther off).
  ##
  ## On-path arithmetic, which is what says WHICH standoffs can hold:
  ##   * the repulsion weight is RepulsionGain*(s-d)/s = 1.5*(s-d)/s, so the
  ##     combined steer REVERSES once d < s/3 — the skimmer flees;
  ##   * contact is at SkimmerRadius + PoisonRadius = 0.40 m, so a standoff
  ##     under 1.20 m cannot even begin to flee before it has been eaten;
  ##   * at throttle 128 the approach speed is 0.5 * 3.24 m/s = 67 500 µm/tick
  ##     and level 7 decelerates at 5 208 µm/tick², so stopping takes
  ##     v²/2a = 0.44 m of the s/3 - 0.40 m the flee has to work with.
  ## That needs s ≳ 2.5 m — which is exactly MaxStandoffMm, and the measurement
  ## below (0.487 m of clearance at 2.5 m, eaten at 1.8 m) matches it. So the
  ## honest on-path assertion is "the widest standoff holds", not "every
  ## standoff ≥ 0.5 m holds"; the note's §Tests 4 wording is corrected in the
  ## errata of docs/plans/2026-08-26-walker-waterworld-design.md.
  proc deadAhead(standoffMm: int32): tuple[survived: bool, closest: int64] =
    ## The waypoint is straight THROUGH a pinned bloom: only the repulsion term
    ## can keep the skimmer off it.
    var sim = seatedSim()
    var ctl = initControlState()
    var intent = defaultIntent()
    intent.mode = mSweep
    intent.standoffMm = standoffMm
    intent.throttle255 = 128
    intent.waypointXUm = 6_000_000
    intent.waypointYUm = 7_400_000
    for f in 0 ..< FoodCount:
      sim.food[f].state = psRespawning
    for q in 0 ..< PoisonCount:
      sim.poison[q].state = psRespawning
    for i in 1 ..< SkimmerCount:
      sim.skimmers[i].x = SkimmerRadius
      sim.skimmers[i].y = SkimmerRadius
    sim.skimmers[0].x = 3_000_000
    sim.skimmers[0].y = 7_400_000
    sim.skimmers[0].vx = 0
    sim.skimmers[0].vy = 0
    sim.poison[0].state = psLive
    sim.poison[0].x = 4_500_000
    sim.poison[0].y = 7_400_000
    sim.poison[0].speed = 0
    result = (true, high(int64))
    for _ in 0 ..< 48:
      var cmds: array[SkimmerCount, uint8]
      cmds[0] = ctl.thrustCommand(sim, 0, sim.frameFor(0), intent)
      # Pin the bloom's POSITION — this block is about the steering, not the
      # drift — but never its STATE: being eaten is what is under test.
      sim.poison[0].x = 4_500_000
      sim.poison[0].y = 7_400_000
      sim.step(cmds)
      result.closest = min(result.closest, isqrt(distSqUm(
        sim.skimmers[0].x, sim.skimmers[0].y,
        sim.poison[0].x, sim.poison[0].y)))
      if sim.poison[0].state != psLive:
        result.survived = false
        break

  var previous = 0'i64
  for standoffMm in [0'i32, 500'i32, 900'i32, 1200'i32, 1800'i32, 2500'i32]:
    let run = deadAhead(standoffMm)
    echo "dead ahead at standoff ", standoffMm, " mm: bloom ",
      (if run.survived: "survived" else: "EATEN"), ", closest ", run.closest,
      " µm"
    check("a wider standoff never approaches a dead-ahead bloom closer " &
      "than a narrower one", run.closest >= previous,
      $standoffMm & " mm: " & $run.closest & " vs " & $previous)
    previous = run.closest
    if standoffMm == 0:
      # Non-vacuity: without a standoff this run DOES eat the bloom, so the
      # survival below is the repulsion's doing and not the geometry's.
      check("with no standoff at all the skimmer eats the dead-ahead bloom",
        not run.survived, $run.closest)
    if standoffMm == MaxStandoffMm:
      check("at the widest standoff the skimmer does not eat a bloom it is " &
        "driving straight at", run.survived, $run.closest)
      check("and it never touches it", run.closest >
        int64(SkimmerRadius + PoisonRadius), $run.closest)

  proc closestApproach(standoffMm: int32): int64 =
    ## The other half: the bloom sits 0.55 m OFF the path, where the radial
    ## term CAN hold the skimmer wide.
    var sim = seatedSim()
    var ctl = initControlState()
    var intent = defaultIntent()
    intent.mode = mSweep
    intent.standoffMm = standoffMm
    intent.throttle255 = 128
    intent.waypointXUm = 6_000_000
    intent.waypointYUm = 7_400_000
    for f in 0 ..< FoodCount:
      sim.food[f].state = psRespawning
    for q in 0 ..< PoisonCount:
      sim.poison[q].state = psRespawning
    for i in 1 ..< SkimmerCount:
      sim.skimmers[i].x = SkimmerRadius
      sim.skimmers[i].y = SkimmerRadius
    sim.skimmers[0].x = 3_000_000
    sim.skimmers[0].y = 7_400_000
    sim.skimmers[0].vx = 0
    sim.skimmers[0].vy = 0
    # The bloom sits 0.55 m OFF the path, not on it.
    sim.poison[0].state = psLive
    sim.poison[0].x = 4_500_000
    sim.poison[0].y = 6_850_000
    sim.poison[0].speed = 0
    result = high(int64)
    for _ in 0 ..< 48:
      var cmds: array[SkimmerCount, uint8]
      cmds[0] = ctl.thrustCommand(sim, 0, sim.frameFor(0), intent)
      sim.poison[0].state = psLive
      sim.poison[0].x = 4_500_000
      sim.poison[0].y = 6_850_000
      sim.step(cmds)
      result = min(result, isqrt(distSqUm(sim.skimmers[0].x, sim.skimmers[0].y,
        sim.poison[0].x, sim.poison[0].y)))

  let
    off = closestApproach(0)
    narrow = closestApproach(900)
    wide = closestApproach(1800)
  echo "closest approach: repulsion off ", off, " µm, 0.9 m standoff ", narrow,
    " µm, 1.8 m standoff ", wide, " µm"
  check("a standoff holds the skimmer farther off than no standoff at all",
    narrow > off, $narrow & " vs " & $off)
  check("a wider standoff holds it farther off still", wide >= narrow,
    $wide & " vs " & $narrow)
  check("and a 1.8 m standoff clears the contact radius entirely",
    wide > int64(SkimmerRadius + PoisonRadius), $wide)

block rockTangentNeverSteersIn:
  ## The ROCK rule in isolation: no poison in the water and no standoff, so the
  ## steering is the goal pull plus the rock rule and nothing else.
  var sim = seatedSim()
  var ctl = initControlState()
  var rng = initRand(555)
  var clipping = 0
  var worst = -2.0
  for q in 0 ..< PoisonCount:
    sim.poison[q].state = psRespawning
  for f in 0 ..< FoodCount:
    sim.food[f].state = psRespawning
  for _ in 0 ..< 10_000:
    var intent = defaultIntent()
    intent.mode = mSweep
    intent.throttle255 = 255
    intent.standoffMm = 0
    intent.waypointXUm = WaypointMinUm +
      int32(rng.next() mod uint64(WaypointMaxXUm - WaypointMinUm))
    intent.waypointYUm = WaypointMinUm +
      int32(rng.next() mod uint64(WaypointMaxYUm - WaypointMinUm))
    sim.skimmers[0].x = SkimmerRadius +
      int32(rng.next() mod uint64(ArenaW - 2 * SkimmerRadius))
    sim.skimmers[0].y = SkimmerRadius +
      int32(rng.next() mod uint64(ArenaH - 2 * SkimmerRadius))
    if distSqUm(sim.skimmers[0].x, sim.skimmers[0].y, RockCentreX, RockCentreY) <
        int64(RockRadius + SkimmerRadius) * int64(RockRadius + SkimmerRadius):
      continue
    sim.skimmers[0].vx = 0
    sim.skimmers[0].vy = 0
    let cmd = ctl.thrustCommand(sim, 0, sim.frameFor(0), intent)
    let decoded = decodeThrust(cmd)
    if decoded.level == 0:
      continue
    # The gate is the RULE's own condition: the straight path p -> G would pass
    # within the rock's keep-out. When it would not, there is nothing to avoid
    # and the goal pull is the right answer.
    let
      px = float(sim.skimmers[0].x)
      py = float(sim.skimmers[0].y)
      gx = float(intent.waypointXUm)
      gy = float(intent.waypointYUm)
      dx = gx - px
      dy = gy - py
      lenSq = dx * dx + dy * dy
      t = if lenSq < 1.0: 0.0
          else: clamp(((float(RockCentreX) - px) * dx +
                       (float(RockCentreY) - py) * dy) / lenSq, 0.0, 1.0)
      cx = px + dx * t
      cy = py + dy * t
      clip = sqrt((float(RockCentreX) - cx) * (float(RockCentreX) - cx) +
                  (float(RockCentreY) - cy) * (float(RockCentreY) - cy))
      keepOut = float(RockRadius + SkimmerRadius) + 200_000.0
    if clip >= keepOut:
      continue
    inc clipping
    let
      toRockX = int64(RockCentreX) - int64(sim.skimmers[0].x)
      toRockY = int64(RockCentreY) - int64(sim.skimmers[0].y)
      dot = toRockX * int64(DirQ12[int(decoded.dir)].x) +
        toRockY * int64(DirQ12[int(decoded.dir)].y)
      # `dot / (|toRock| * Q12)` IS the cosine of the angle between the thrust
      # and the rock, so the bound below is an angle. The velocity is zeroed
      # above, so the accel vector IS the steer vector and the only error
      # between a perfect tangent (cosine 0) and the byte is quantisation:
      #   * half a step of the 32-direction table:          5.625 deg
      #   * nearestDirIndex maximises the dot against the ROUNDED table, whose
      #     entry lengths differ by up to 1 part in 4096, which shifts the
      #     sector boundary by (2.2e-4)/(2*tan 5.625 deg):   0.064 deg
      #   * `micro()` truncates the accel to whole µm and level >= 1 needs
      #     |a| >= 372 µm, so at worst atan(sqrt(2)/372):    0.218 deg
      # sin(5.907 deg) = 0.1030, and |DirQ12| <= 4096.5 inflates the measured
      # cosine by a further 1.0002 — so 0.11 is the tolerance the arithmetic
      # supports. The worst cosine actually observed over these 10 000 goals is
      # 0.0991 (echoed below), i.e. 5.69 deg off perpendicular.
      bound = int64(0.11 * sqrt(float(toRockX * toRockX + toRockY * toRockY)) *
        float(Q12))
    worst = max(worst, float(dot) /
      (sqrt(float(toRockX * toRockX + toRockY * toRockY)) * float(Q12)))
    check("the tangent rule never thrusts into the rock", dot < bound,
      $dot & " vs " & $bound)
  echo "rock tangent: worst cosine toward the rock ", worst, " over ",
    clipping, " clipping goals"
  check("the sweep actually exercised the rock rule", clipping > 200, $clipping)

if failures > 0:
  quit("test_control: " & $failures & " failure(s)", 1)
echo "test_control: ok"
