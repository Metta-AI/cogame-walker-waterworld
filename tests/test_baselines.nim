## THE BOUNDED-ORDERS / LEGALITY ASSERTION on the scripted baselines, plus the
## anti-regression pin on the whole physics tuning: if four `shoal`s cannot
## capture, the three BaselineParams numbers are wrong — the physics constants do
## not move.
##
## Release-only (NIM_TESTS_RELEASE_ONLY): it plays whole episodes.

import std/[json, math, os, random, strformat, strutils]

import helpers
import waterworld/[sim, roster, sensors, intents, control, baselines]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

block boundedOrders:
  ## 500 pseudo-random world states x both baselines: every emitted intent must
  ## validate against the reply schema, and the compiled command byte must be in
  ## range. Both baselines emit the SAME object an LLM does, which is what makes
  ## one validator cover both.
  var sim = seatedSim()
  var ctl = initControlState()
  var rng = initRand(6060)
  for trial in 0 ..< 500:
    for i in 0 ..< SkimmerCount:
      sim.skimmers[i].x = SkimmerRadius +
        int32(rng.next() mod uint64(ArenaW - 2 * SkimmerRadius))
      sim.skimmers[i].y = SkimmerRadius +
        int32(rng.next() mod uint64(ArenaH - 2 * SkimmerRadius))
      sim.skimmers[i].vx = int32(rng.next() mod uint64(2 * MaxSkimmerSpeed)) -
        MaxSkimmerSpeed
      sim.skimmers[i].vy = int32(rng.next() mod uint64(2 * MaxSkimmerSpeed)) -
        MaxSkimmerSpeed
      sim.skimmers[i].stun = int32(rng.next() mod uint64(StunTicks + 1))
    for f in 0 ..< FoodCount:
      sim.food[f].state = if rng.next() mod 4'u64 == 0'u64: psRespawning else: psLive
      sim.food[f].x = FoodRadius + int32(rng.next() mod uint64(ArenaW - 2 * FoodRadius))
      sim.food[f].y = FoodRadius + int32(rng.next() mod uint64(ArenaH - 2 * FoodRadius))
    for q in 0 ..< PoisonCount:
      sim.poison[q].state = if rng.next() mod 4'u64 == 0'u64: psRespawning else: psLive
      sim.poison[q].x = PoisonRadius +
        int32(rng.next() mod uint64(ArenaW - 2 * PoisonRadius))
      sim.poison[q].y = PoisonRadius +
        int32(rng.next() mod uint64(ArenaH - 2 * PoisonRadius))
    for kind in [blShoal, blDrifter]:
      for i in 0 ..< SkimmerCount:
        let
          frame = sim.frameFor(i)
          intent = scriptedIntent(sim, kind, i, frame, trial)
        check("mode is in the closed enum", ord(intent.mode) >= 0 and
          ord(intent.mode) <= ord(high(Mode)))
        check("lead_ticks is inside 0..24",
          intent.leadTicks >= 0 and intent.leadTicks <= MaxLeadTicks,
          $intent.leadTicks)
        check("standoff is inside 0..2500 mm",
          intent.standoffMm >= 0 and intent.standoffMm <= MaxStandoffMm,
          $intent.standoffMm)
        check("throttle is inside 0..255",
          intent.throttle255 >= 0 and intent.throttle255 <= 255,
          $intent.throttle255)
        check("the waypoint is inside the tank",
          intent.waypointXUm >= WaypointMinUm and
            intent.waypointXUm <= WaypointMaxXUm and
            intent.waypointYUm >= WaypointMinUm and
            intent.waypointYUm <= WaypointMaxYUm,
          $intent.waypointXUm & "," & $intent.waypointYUm)
        check("the note is inside its rune cap",
          intent.note.len <= MaxNoteRunes * 4, $intent.note.len)
        check("say is inside its rune cap", intent.say.len <= MaxSayRunes * 4,
          $intent.say.len)
        if intent.target >= 0:
          check("target is either none or a CURRENTLY DETECTED plankton",
            frame.foodDetection(int(intent.target)) >= 0,
            $kind & " named " & foodId(int(intent.target)) & " it cannot sense")
        if intent.partner >= 0:
          check("partner is another skimmer, never its own alias",
            int(intent.partner) != i and int(intent.partner) < SkimmerCount,
            $intent.partner)
        let cmd = ctl.thrustCommand(sim, i, frame, intent)
        let decoded = decodeThrust(cmd)
        check("the compiled command byte is in range",
          decoded.dir >= 0 and decoded.dir < 32 and
            decoded.level >= 0 and decoded.level < 8)

# ---------------------------------------------------------------------------
#  The tuning pin
# ---------------------------------------------------------------------------

type PanelResult = object
  captures: int
  score: float

proc playPanel(kind: Baseline, seeds: seq[int]): seq[PanelResult] =
  for seed in seeds:
    var sim = seatedSim(seed)
    discard sim.runScripted(kind)
    result.add PanelResult(captures: int(sim.captures), score: sim.scoreDouble())

proc playMixed(seeds: seq[int]): seq[PanelResult] =
  for seed in seeds:
    var sim = seatedSim(seed)
    var kinds: array[SkimmerCount, Baseline] = [
      blShoal, blShoal, blDrifter, blDrifter]
    discard sim.mixedRun(kinds)
    result.add PanelResult(captures: int(sim.captures), score: sim.scoreDouble())

proc summarize(rows: seq[PanelResult], atLeast: int): tuple[
    hits: int, mean: float, best: int] =
  var total = 0.0
  for row in rows:
    total += row.score
    if row.captures >= atLeast:
      inc result.hits
    result.best = max(result.best, row.captures)
  result.mean = total / float(max(1, rows.len))

let seeds = block:
  var out: seq[int]
  for i in 0 ..< 20:
    out.add(1000 + i * 7919)
  out

let
  shoal = playPanel(blShoal, seeds)
  drifter = playPanel(blDrifter, seeds)
  mixed = playMixed(seeds)
  shoalSummary = shoal.summarize(8)
  drifterSummary = drifter.summarize(8)
  mixedSummary = mixed.summarize(4)

echo "---- baseline panel over ", seeds.len, " seeds ----"
echo "shoal  : ", shoalSummary.hits, "/20 seeds at 8+ captures, mean score ",
  shoalSummary.mean.formatFloat(ffDecimal, 2), ", best ", shoalSummary.best
echo "drifter: ", drifterSummary.hits, "/20 seeds at 8+ captures, mean score ",
  drifterSummary.mean.formatFloat(ffDecimal, 2), ", best ", drifterSummary.best
echo "mix 2+2: ", mixedSummary.hits, "/20 seeds at 4+ captures, mean score ",
  mixedSummary.mean.formatFloat(ffDecimal, 2), ", best ", mixedSummary.best
echo "---- end baseline panel ----"

block tuningPin:
  ## The pin is a RECORDED MEASUREMENT, not a guess: `tools/tune_baselines.nim`
  ## sweeps the three BaselineParams numbers, `tools/ci/baseline_tuning.json`
  ## records the winning cell AND the panel it won with, and this asserts the
  ## shipped defaults still reach it. The authoring sandbox has no Nim, so the
  ## first CI run MINTS the measurement (printed above and below) and it is
  ## committed from the log; after that this branch only ever compares.
  let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
  check("the shipped pairJoinRadiusUm equals the sweep's pick",
    int(tuning["pick"]["pairJoinRadiusUm"].getInt()) ==
      int(DefaultBaselineParams.pairJoinRadiusUm),
    $DefaultBaselineParams.pairJoinRadiusUm)
  check("the shipped standoffMilli equals the sweep's pick",
    int(tuning["pick"]["standoffMilli"].getInt()) ==
      int(DefaultBaselineParams.standoffMilli),
    $DefaultBaselineParams.standoffMilli)
  check("the shipped leadTicks equals the sweep's pick",
    int(tuning["pick"]["leadTicks"].getInt()) ==
      int(DefaultBaselineParams.leadTicks),
    $DefaultBaselineParams.leadTicks)
  if not tuning.hasKey("measured"):
    echo "---- BEGIN tools/ci/baseline_tuning.json measured block ----"
    echo (%*{
      "measured": {
        "seeds": seeds.len,
        "shoalSeedsAt8": shoalSummary.hits,
        "shoalMeanScore": shoalSummary.mean,
        "drifterMeanScore": drifterSummary.mean,
        "mixedSeedsAt4": mixedSummary.hits
      }
    }).pretty()
    echo "---- END measured block ----"
    check("baseline_tuning.json carries the measured panel " &
      "(printed above; commit it)", false)
  else:
    let measured = tuning["measured"]
    check("four shoals still reach the recorded seed count at 8+ captures",
      shoalSummary.hits >= measured["shoalSeedsAt8"].getInt(),
      $shoalSummary.hits & " vs " & $measured["shoalSeedsAt8"].getInt())
    check("four shoals still reach the recorded mean score",
      shoalSummary.mean >= measured["shoalMeanScore"].getFloat() - 5.0,
      $shoalSummary.mean & " vs " & $measured["shoalMeanScore"].getFloat())
    check("a 2-shoal/2-drifter mix still reaches the recorded seed count",
      mixedSummary.hits >= measured["mixedSeedsAt4"].getInt(),
      $mixedSummary.hits & " vs " & $measured["mixedSeedsAt4"].getInt())

block drifterIsWeaker:
  ## `drifter` is deliberately different in SHAPE and weaker, so the ladder gets
  ## a spread rather than two versions of one bot.
  check("four drifters score strictly below four shoals in mean",
    drifterSummary.mean < shoalSummary.mean,
    $drifterSummary.mean & " vs " & $shoalSummary.mean)

block shoalIsTheDefault:
  check("an unrecognised PLAYER_SCRIPTED is shoal",
    parseBaseline("nonsense") == blShoal)
  check("an empty PLAYER_SCRIPTED is shoal", parseBaseline("") == blShoal)
  check("drifter parses", parseBaseline("drifter") == blDrifter)
  check("drift parses too", parseBaseline("DRIFT") == blDrifter)

if failures > 0:
  quit("test_baselines: " & $failures & " failure(s)", 1)
echo "test_baselines: ok"
