## The controller: `thrustCommand(sim, i) -> uint8`, evaluated once per tick per
## skimmer in INDEX order. One function, shared by every policy — both LLM
## intents and scripted-baseline intents are compiled by this same code, so the
## two policy kinds are strictly comparable and a baseline is legal by
## construction.
##
## It sits OUTSIDE the determinism boundary and may use floats: the byte it
## produces is what the replay records, and the browser replays the byte rather
## than re-running this logic. The byte uses the whole 0..255 range —
## `dir * 8 + level`, 32 x 8 = 256 exactly — so no value is reserved and no
## value needs repair.
##
## It contains no memory across ticks except the last steering direction, no
## knowledge of any other seat's intent, and no access to any particle it has
## not detected: `thrustCommand`'s inputs are structurally limited to that
## skimmer's own state, its sensor frame and its seat's intent, and
## `tests/test_locality.nim` asserts the signature cannot see more.

import std/math

import sim_types, trig, sim, intents

type
  ControlState* = object
    ## The controller's only memory: the last steering direction per skimmer,
    ## so a degenerate steering sum keeps last tick's heading instead of
    ## snapping. Never hashed, never recorded — the BYTE is.
    lastSteerX*, lastSteerY*: array[SkimmerCount, float]
    haveSteer*: array[SkimmerCount, bool]

proc initControlState*(): ControlState = ControlState()

const
  EscortStandoffM = 0.80
  EscortFoodRadiusM = 1.50
  AvoidPushM = 2.50
  ParkRadiusM = 0.30
  RockMarginM = 0.20
  RepulsionGain = 1.5

proc metres(um: int32): float {.inline.} = float(um) / 1_000_000.0
proc micro(m: float): int32 {.inline.} = int32(clamp(m * 1_000_000.0, -2.0e7, 2.0e7))

proc normalise(x, y: float): tuple[x, y: float] =
  let mag = sqrt(x * x + y * y)
  if mag < 1.0e-6:
    (0.0, 0.0)
  else:
    (x / mag, y / mag)

proc segmentDistanceToPoint(
  ax, ay, bx, by, px, py: float
): float =
  ## Distance from point p to the segment a->b, in the same units.
  let
    dx = bx - ax
    dy = by - ay
    lenSq = dx * dx + dy * dy
  if lenSq < 1.0e-9:
    return sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay))
  var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
  t = clamp(t, 0.0, 1.0)
  let
    cx = ax + dx * t
    cy = ay + dy * t
  sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))

proc goalPoint(
  frame: SensorFrame, intent: SkimmerIntent, px, py: float
): tuple[x, y: float] =
  ## The goal point G, in SIM metres (origin top-left, y down). Explicit result
  ## assignment rather than a case expression: every mode has a documented goal
  ## and none of them may fall through to "nothing".
  result = (px, py)
  case intent.mode
  of mHold:
    discard                        ## G = p; the servo then brakes
  of mSweep:
    result = (metres(intent.waypointXUm), metres(intent.waypointYUm))
  of mHunt:
    var pick = frame.foodDetection(int(intent.target))
    if pick < 0:
      pick = frame.nearestFood()
    if pick < 0:
      result = (metres(intent.waypointXUm), metres(intent.waypointYUm))
    else:
      # A straight-line lead, deliberately NOT a bounce-aware prediction: an
      # agent that wants a bounce accounted for asks for a shorter lead.
      let det = frame.food[pick]
      result = (
        metres(det.x) + metres(det.vx) * float(intent.leadTicks),
        metres(det.y) + metres(det.vy) * float(intent.leadTicks))
  of mEscort:
    var pick = frame.partnerDetection(int(intent.partner))
    if pick < 0:
      pick = frame.nearestPartner()
    if pick >= 0:
      let
        mate = frame.partners[pick]
        mx = metres(mate.x) + metres(mate.vx) * float(intent.leadTicks)
        my = metres(mate.y) + metres(mate.vy) * float(intent.leadTicks)
      var
        bestFood = -1
        bestDist = EscortFoodRadiusM
      for k, det in frame.food:
        let d = sqrt((metres(det.x) - mx) * (metres(det.x) - mx) +
                     (metres(det.y) - my) * (metres(det.y) - my))
        if d <= bestDist:
          bestDist = d
          bestFood = k
      if bestFood >= 0:
        # THIS is how two skimmers arrive together: the instant either of them
        # smells plankton near the other, both go to the plankton.
        let det = frame.food[bestFood]
        result = (
          metres(det.x) + metres(det.vx) * float(intent.leadTicks),
          metres(det.y) + metres(det.vy) * float(intent.leadTicks))
      else:
        # Stop EscortStandoffM short of the partner, so two escorting skimmers
        # converge to a rendezvous rather than colliding.
        let
          span = sqrt((mx - px) * (mx - px) + (my - py) * (my - py))
          unit = normalise(mx - px, my - py)
        if span > EscortStandoffM and (unit.x != 0.0 or unit.y != 0.0):
          result = (px + unit.x * (span - EscortStandoffM),
                    py + unit.y * (span - EscortStandoffM))
  of mAvoid:
    let pick = frame.nearestPoison()
    if pick >= 0:
      let det = frame.poison[pick]
      let unit = normalise(px - metres(det.x), py - metres(det.y))
      if unit.x == 0.0 and unit.y == 0.0:
        result = (px, py + AvoidPushM)
      else:
        result = (metres(det.x) + unit.x * AvoidPushM,
                  metres(det.y) + unit.y * AvoidPushM)
    else:
      # No poison sensed: the tank centre, offset outward along (p - rock) so
      # the fallback never steers INTO the rock.
      let unit = normalise(px - metres(RockCentreX), py - metres(RockCentreY))
      if unit.x == 0.0 and unit.y == 0.0:
        result = (metres(RockCentreX), metres(RockCentreY) - 1.60)
      else:
        result = (metres(RockCentreX) + unit.x * 1.60,
                  metres(RockCentreY) + unit.y * 1.60)

proc thrustCommand*(
  ctl: var ControlState,
  sim: SimServer,
  i: int,
  frame: SensorFrame,
  intent: SkimmerIntent
): uint8 =
  ## The command byte for skimmer `i` this tick.
  # (6) Any phase other than Playing, and any tick with stun left, coasts.
  if sim.phase != Playing or sim.skimmers[i].stun > 0:
    return 0'u8
  let
    me = sim.skimmers[i]
    px = metres(me.x)
    py = metres(me.y)
    vx = metres(me.vx)
    vy = metres(me.vy)
    goal = goalPoint(frame, intent, px, py)

  # (2) Poison repulsion — always, in every mode.
  var
    repX = 0.0
    repY = 0.0
  let standoff = intent.standoffMetres()
  if standoff > 0.0:
    for det in frame.poison:
      let d = metres(det.distUm)
      if d < standoff and d > 1.0e-6:
        let unit = normalise(px - metres(det.x), py - metres(det.y))
        let weight = RepulsionGain * (standoff - d) / standoff
        repX += unit.x * weight
        repY += unit.y * weight
  var steer = normalise(goal.x - px, goal.y - py)
  let combined = normalise(steer.x + repX, steer.y + repY)
  if combined.x == 0.0 and combined.y == 0.0:
    if ctl.haveSteer[i]:
      steer = (ctl.lastSteerX[i], ctl.lastSteerY[i])
    else:
      steer = normalise(goal.x - px, goal.y - py)
  else:
    steer = combined

  # (3) Rock avoidance: if the path p -> G passes within the rock's keep-out,
  # rotate the steering onto the tangent on the side that keeps G nearer. The
  # only path-planning in the controller, and it is a single rotation.
  let
    rockX = metres(RockCentreX)
    rockY = metres(RockCentreY)
    keepOut = metres(RockRadius) + metres(SkimmerRadius) + RockMarginM
  let fromRock = sqrt((px - rockX) * (px - rockX) + (py - rockY) * (py - rockY))
  if fromRock < keepOut:
    # ALREADY inside the keep-out ring: steer straight out. A tangent here would
    # make the skimmer orbit the rock instead of leaving it, which is a trap the
    # sim's own push-out cannot break.
    let outward = normalise(px - rockX, py - rockY)
    if outward.x != 0.0 or outward.y != 0.0:
      steer = outward
  elif segmentDistanceToPoint(px, py, goal.x, goal.y, rockX, rockY) < keepOut:
    let toRock = normalise(rockX - px, rockY - py)
    if toRock.x != 0.0 or toRock.y != 0.0:
      let
        tangentAX = -toRock.y
        tangentAY = toRock.x
        tangentBX = toRock.y
        tangentBY = -toRock.x
        toGoal = normalise(goal.x - px, goal.y - py)
      if tangentAX * toGoal.x + tangentAY * toGoal.y >=
          tangentBX * toGoal.x + tangentBY * toGoal.y:
        steer = (tangentAX, tangentAY)
      else:
        steer = (tangentBX, tangentBY)

  if steer.x != 0.0 or steer.y != 0.0:
    ctl.lastSteerX[i] = steer.x
    ctl.lastSteerY[i] = steer.y
    ctl.haveSteer[i] = true

  # (4) Velocity servo.
  let
    maxSpeed = metres(MaxSkimmerSpeed)
    throttle = clamp(intent.throttleFraction(), 0.0, 1.0)
    distToGoal = sqrt((goal.x - px) * (goal.x - px) + (goal.y - py) * (goal.y - py))
  var target = throttle * maxSpeed
  if intent.mode == mHold:
    target = 0.0
  elif intent.mode in {mSweep, mHold} and distToGoal < ParkRadiusM:
    target = target * (distToGoal / ParkRadiusM)
  let
    wantX = steer.x * target
    wantY = steer.y * target
    accelX = wantX - vx
    accelY = wantY - vy
    accelMag = sqrt(accelX * accelX + accelY * accelY)

  # (5) Quantise.
  if accelMag < 1.0e-9:
    return 0'u8
  let
    dir = nearestDirIndex(int64(micro(accelX)), int64(micro(accelY)))
    maxAccel = metres(MaxThrustAccel)
    level = int32(clamp(round(accelMag * 7.0 / maxAccel), 0.0, 7.0))
  if level <= 0:
    return 0'u8
  encodeThrust(int32(dir), level)
