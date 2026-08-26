## The scoring formula and its sign, and the rules that make a capture a
## capture: two skimmers, same tick, and a nibble that cannot be farmed.

import std/[json, math, strformat]

import helpers
import waterworld/[sim, roster]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

proc scoreFor(captures, nibbles, poisonHits: int, thrust: float): float =
  round(10.0 * float(captures) + 0.05 * float(nibbles) -
    2.0 * float(poisonHits) - thrust, 3)

block workedExamples:
  ## The six worked examples of the design note, to 3 decimals.
  check("two disciplined pairs, target met",
    scoreFor(20, 26, 2, 5.10) == 192.200, $scoreFor(20, 26, 2, 5.10))
  check("good pod, full time",
    scoreFor(13, 31, 3, 6.40) == 119.150, $scoreFor(13, 31, 3, 6.40))
  check("one pair works, the other two drift",
    scoreFor(7, 22, 5, 5.80) == 55.300, $scoreFor(7, 22, 5, 5.80))
  check("four drifters",
    scoreFor(3, 18, 7, 4.60) == 12.300, $scoreFor(3, 18, 7, 4.60))
  check("everybody chases everything, poison included",
    scoreFor(1, 9, 19, 6.90) == -34.450, $scoreFor(1, 9, 19, 6.90))
  check("nobody thrusts at all",
    scoreFor(0, 2, 0, 0.0) == 0.100, $scoreFor(0, 2, 0, 0.0))

block simMatchesTheFormula:
  var sim = seatedSim()
  discard sim.runScripted(blShoal)
  let expected = round(10.0 * float(sim.captures) + 0.05 * float(sim.nibbles) -
    2.0 * float(sim.poisonHits) - sim.thrustCostDouble(), 3)
  check("the sim's score equals the formula", abs(sim.scoreDouble() - expected) < 0.002,
    &"{sim.scoreDouble()} vs {expected}")
  check("higher is better: captures are positive", CaptureMicro > 0)
  check("poison is negative", PoisonMicro < 0)

block captureNeedsExactlyTwo:
  # Park ONE skimmer on a plankton: a nibble, never a capture.
  var sim = seatedSim()
  # ONE plankton in the water and no blooms: `poisonCount` 0 is how a particle
  # leaves play legally — an out-of-range respawn timer would (rightly) trip the
  # invariant guard.
  sim.config.foodCount = 1
  sim.config.poisonCount = 0
  sim.food[0].state = psLive
  sim.food[0].x = 4_000_000
  sim.food[0].y = 4_000_000
  sim.food[0].speed = 0
  for i in 0 ..< SkimmerCount:
    sim.skimmers[i].x = 1_000_000
    sim.skimmers[i].y = 1_000_000
    sim.skimmers[i].vx = 0
    sim.skimmers[i].vy = 0
  sim.skimmers[0].x = 4_000_000
  sim.skimmers[0].y = 4_000_000
  var cmds: array[SkimmerCount, uint8]
  sim.step(cmds)
  check("one skimmer on a plankton pays a nibble, not a capture",
    sim.captures == 0 and sim.nibbles == 1, &"{sim.captures}/{sim.nibbles}")

  # 480 ticks parked: ONE nibble, not 480 — the re-arm rule.
  for _ in 0 ..< 480:
    sim.food[0].state = psLive
    sim.food[0].x = 4_000_000
    sim.food[0].y = 4_000_000
    sim.skimmers[0].x = 4_000_000
    sim.skimmers[0].y = 4_000_000
    sim.step(cmds)
  check("a lone skimmer parked for 480 ticks collects ONE nibble",
    sim.nibbles == 1, $sim.nibbles)

block twoAndThreeBothPayOneCapture:
  for holders in 2 .. 3:
    var sim = seatedSim()
    sim.config.foodCount = 1
    sim.config.poisonCount = 0
    sim.food[0].state = psLive
    sim.food[0].timer = 0
    sim.food[0].x = 4_000_000
    sim.food[0].y = 4_000_000
    sim.food[0].speed = 0
    for i in 0 ..< SkimmerCount:
      sim.skimmers[i].x = 1_000_000
      sim.skimmers[i].y = 7_000_000
      sim.skimmers[i].vx = 0
      sim.skimmers[i].vy = 0
    for i in 0 ..< holders:
      sim.skimmers[i].x = 4_000_000 + int32(i) * 40_000
      sim.skimmers[i].y = 4_000_000
    var cmds: array[SkimmerCount, uint8]
    sim.step(cmds)
    check($holders & " skimmers pay exactly ONE capture", sim.captures == 1,
      $sim.captures)
    var credited = 0
    for seat in 0 ..< SkimmerCount:
      if sim.assists[seat] > 0:
        inc credited
    check($holders & " skimmers credit " & $holders & " assists",
      credited == holders, $credited)

block poisonCosts:
  var sim = seatedSim()
  sim.config.foodCount = 0
  sim.config.poisonCount = 1
  sim.poison[0].state = psLive
  sim.poison[0].timer = 0
  sim.poison[0].x = 4_000_000
  sim.poison[0].y = 4_000_000
  sim.poison[0].speed = 0
  for i in 0 ..< SkimmerCount:
    sim.skimmers[i].x = 1_000_000
    sim.skimmers[i].y = 7_000_000
    sim.skimmers[i].vx = 0
    sim.skimmers[i].vy = 0
  sim.skimmers[0].x = 4_000_000
  sim.skimmers[0].y = 4_000_000
  var cmds: array[SkimmerCount, uint8]
  sim.step(cmds)
  check("a poison hit costs exactly -2.000",
    sim.scoreMicro == PoisonMicro, $sim.scoreMicro)
  check("a poison hit stuns for 12 ticks",
    sim.skimmers[0].stun == StunTicks, $sim.skimmers[0].stun)
  check("the bloom is consumed", sim.poison[0].state == psRespawning)

block fullThrottleBill:
  ## Full throttle for a whole episode costs 6.912 points: 1000 micro-points per
  ## tick per seat, 1728 ticks, four seats.
  let bill = float(thrustMicroFor(7) * 1728 * 4) / 1_000_000.0
  check("full throttle for the whole episode costs 6.912",
    abs(bill - 6.912) < 0.0005, $bill)

block resultsShape:
  var sim = seatedSim()
  discard sim.runScripted(blShoal)
  let results = parseJson(sim.playerResultsJson())
  check("results has exactly 22 keys", results.len == 22, $results.len)
  check("all four scores are bit-identical",
    results["scores"][0] == results["scores"][1] and
      results["scores"][1] == results["scores"][2] and
      results["scores"][2] == results["scores"][3])
  check("sharedScore equals every seat's score",
    results["sharedScore"] == results["scores"][0])
  let won = sim.captures >= int32(sim.config.captureTarget)
  for seat in 0 ..< SkimmerCount:
    check("win is the same in all four slots",
      results["win"][seat].getBool() == won)
  check("reason is in the closed enum",
    results["reason"].getStr() in ["complete", "deadline", "fault"],
    results["reason"].getStr())
  check("endRule is in the closed enum",
    results["endRule"].getStr() in
      ["target_met", "full_time", "wall_clock", "sim_fault", "host_error"],
    results["endRule"].getStr())
  for key in ["names", "aliases", "skimmers", "policyKinds", "scores", "win",
      "assists", "nibblesBySeat", "poisonBySeat", "thrustMeanPct", "llmTurns",
      "fallbackTurns"]:
    check("every per-seat array has exactly 4 entries: " & key,
      results[key].len == 4, $results[key].len)

block targetEndsTheEpisode:
  var sim = seatedSim(maxTicks = 1728)
  sim.config.captureTarget = 1
  sim.config.foodCount = 1
  sim.config.poisonCount = 0
  sim.food[0].state = psLive
  sim.food[0].timer = 0
  sim.food[0].x = 4_000_000
  sim.food[0].y = 4_000_000
  sim.food[0].speed = 0
  for i in 0 ..< SkimmerCount:
    sim.skimmers[i].x = 4_000_000
    sim.skimmers[i].y = 4_000_000
    sim.skimmers[i].vx = 0
    sim.skimmers[i].vy = 0
  var cmds: array[SkimmerCount, uint8]
  sim.step(cmds)
  check("reaching the target ends the episode on that tick",
    sim.phase == GameOver, $sim.phase)
  check("the ending is complete/target_met",
    sim.endReason == ReasonComplete and sim.endRule == EndRuleTargetMet,
    sim.endReason & "/" & sim.endRule)
  check("win is true", sim.podWon())

if failures > 0:
  quit("test_scoring: " & $failures & " failure(s)", 1)
echo "test_scoring: ok"
