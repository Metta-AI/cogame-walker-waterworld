## The two published scripted baselines.
##
## Both emit the SAME intent object an LLM does, on the same 72-tick cadence, so
## their output is legal by construction and directly comparable, and both are
## pure functions of the observation a seat would receive — which is what makes
## the bounded-orders test in `tests/test_baselines.nim` meaningful.
##
## `shoal` is load-bearing in four places: it is the certification player, the
## per-turn fallback when a seat's LLM call fails twice, the driver of any
## skimmer whose seat never connected, and the default for a seat that
## registers with neither PLAYER_PROMPT nor PLAYER_SCRIPTED. It is documented in
## docs/RULES.md precisely so "coordinating without talking" here means "adapt
## to a partner whose rules you know but do not control".
##
## Four `shoal`s reliably capture without communicating, and the ONLY thing that
## makes two independent copies of the algorithm cooperate is that both index the
## patrol circuit by the same turn number. No communication is used or needed.

import std/strutils

import sim_types, sim, intents

type
  Baseline* = enum
    blShoal = "shoal"
    blDrifter = "drifter"

  BaselineParams* = object
    ## The three tunables. They are a parameter rather than a literal because
    ## they were CHOSEN by a grid sweep, not guessed: `tools/tune_baselines.nim`
    ## plays the pod over a bounded matrix of them and prints the table,
    ## `tools/ci/baseline_tuning.json` records the sweep's pick, and
    ## `tests/test_tuning.nim` asserts the shipped defaults below still equal
    ## it. THE PHYSICS CONSTANTS IN sim_types.nim ARE NOT SWEPT: if four
    ## `shoal`s cannot capture, these three numbers are wrong.
    pairJoinRadiusUm*: int32   ## how near my mate must be to the plankton
    standoffMilli*: int32      ## the autopilot's poison swing, in mm
    leadTicks*: int32          ## how far ahead a hunt aims

const DefaultBaselineParams* = BaselineParams(
  pairJoinRadiusUm: 3_200_000,
  standoffMilli: 1_200,
  leadTicks: 8
)

const
  ShoalPatrol: array[4, tuple[x, y: int32]] = [
    (3_000_000'i32, 6_000_000'i32),   ## view (3, 2)
    (9_000_000'i32, 6_000_000'i32),   ## view (9, 2)
    (9_000_000'i32, 2_000_000'i32),   ## view (9, 6)
    (3_000_000'i32, 2_000_000'i32)    ## view (3, 6)
  ]
  DrifterSerpentine: array[6, tuple[x, y: int32]] = [
    (1_500_000'i32, 6_500_000'i32),   ## view (1.5, 1.5)
    (10_500_000'i32, 6_500_000'i32),  ## view (10.5, 1.5)
    (1_500_000'i32, 4_000_000'i32),   ## view (1.5, 4.0)
    (10_500_000'i32, 4_000_000'i32),  ## view (10.5, 4.0)
    (1_500_000'i32, 1_500_000'i32),   ## view (1.5, 6.5)
    (10_500_000'i32, 1_500_000'i32)   ## view (10.5, 6.5)
  ]
  ShoalPoisonPanicUm = 900_000'i32
  ShoalSitOnItUm = 1_000_000'i32
  ShoalRegroupUm = 2_400_000'i32

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `shoal`: a seat that says
  ## nothing useful still plays the published default rather than sitting out.
  case text.strip().toLowerAscii()
  of "drifter", "drift": blDrifter
  else: blShoal

proc shoalIntent*(
  sim: SimServer, skimmer: int, frame: SensorFrame, turn: int,
  params = DefaultBaselineParams
): SkimmerIntent =
  ## `shoal` — pair and hunt. Seven branches, in this order, for skimmer `i`
  ## with `mate = i xor 1`.
  result = defaultIntent()
  result.source = isScripted
  result.standoffMm = params.standoffMilli
  let mate = skimmer xor 1

  # 1. stunned: nothing to do but stop being in the way.
  if sim.skimmers[skimmer].stun > 0:
    result.mode = mHold
    result.throttle255 = 0
    result.say = "shaking it off"
    return

  # 2. poison inside 0.90 m: get out, at full throttle, for one turn.
  let nearPoison = frame.nearestPoison()
  if nearPoison >= 0 and frame.poison[nearPoison].distUm <= ShoalPoisonPanicUm:
    result.mode = mAvoid
    result.throttle255 = 255
    result.standoffMm = 1_800
    result.say = "poison, breaking off"
    return

  let matePick = frame.partnerDetection(mate)
  result.partner = int32(mate)

  # 3. a plankton my mate can also reach: take it TOGETHER — that is the +10.
  var
    bestJoin = -1
    bestJoinScore = high(int64)
  if matePick >= 0:
    let m = frame.partners[matePick]
    for k, det in frame.food:
      let mateDist = isqrt(distSqUm(det.x, det.y, m.x, m.y))
      if mateDist > int64(params.pairJoinRadiusUm):
        continue
      let score = int64(det.distUm) + mateDist
      if score < bestJoinScore:
        bestJoinScore = score
        bestJoin = k
  if bestJoin >= 0:
    result.mode = mHunt
    result.target = frame.food[bestJoin].index
    result.leadTicks = params.leadTicks
    result.throttle255 = 255
    result.say = "on it with two"
    return

  # 4. a plankton I am already sitting on: hold it and wait for the mate.
  let nearFood = frame.nearestFood()
  if nearFood >= 0 and frame.food[nearFood].distUm <= ShoalSitOnItUm:
    result.mode = mHunt
    result.target = frame.food[nearFood].index
    result.leadTicks = 2
    result.throttle255 = 128
    result.say = "holding it, come here"
    return

  # 5. a plankton I can smell but nobody can join: fetch the mate instead.
  if nearFood >= 0:
    result.mode = mEscort
    result.leadTicks = 6
    result.throttle255 = 255
    result.say = "fetching my mate"
    return

  # 6. drifted apart: close up. Two skimmers 6 m apart catch nothing.
  if matePick >= 0 and frame.partners[matePick].distUm > ShoalRegroupUm:
    result.mode = mEscort
    result.throttle255 = 230
    result.say = "closing up"
    return

  # 7. sweep the tank together. BOTH members of the pair index the circuit by
  # the same turn number, which is the whole of their coordination.
  let point = ShoalPatrol[((turn div 2) mod 4 + 4) mod 4]
  result.mode = mSweep
  result.waypointXUm = point.x
  result.waypointYUm = point.y
  result.throttle255 = 179                 ## 0.70 of full
  result.say = "sweeping"

proc drifterIntent*(
  sim: SimServer, skimmer: int, frame: SensorFrame, turn: int,
  params = DefaultBaselineParams
): SkimmerIntent =
  ## `drifter` — the second filler, deliberately different in SHAPE and weaker:
  ## it never coordinates and never escorts. Two drifters capture only when they
  ## happen to converge, which gives the ladder a spread and gives a champion a
  ## bad neighbour to cope with.
  result = defaultIntent()
  result.source = isScripted
  result.standoffMm = 600
  result.throttle255 = 179
  let nearFood = frame.nearestFood()
  if nearFood >= 0:
    result.mode = mHunt
    result.target = frame.food[nearFood].index
    result.leadTicks = 0
    result.say = "food"
    return
  let point = DrifterSerpentine[((turn mod 6) + 6) mod 6]
  result.mode = mSweep
  result.waypointXUm = point.x
  result.waypointYUm = point.y
  result.say = "drifting"

proc scriptedIntent*(
  sim: SimServer, kind: Baseline, skimmer: int, frame: SensorFrame, turn: int,
  params = DefaultBaselineParams
): SkimmerIntent =
  case kind
  of blShoal: shoalIntent(sim, skimmer, frame, turn, params)
  of blDrifter: drifterIntent(sim, skimmer, frame, turn, params)
