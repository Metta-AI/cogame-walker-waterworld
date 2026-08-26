## The sensor-locality invariant: what a seat can see, and — much more
## importantly — everything it cannot.

import std/[json, random, strutils]

import helpers
import waterworld/[sim, roster, sensors, intents, control, baselines, decide, llm]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

var sim = seatedSim()
var engine = initDecisionEngine(sim)
for seat in 0 ..< SkimmerCount:
  engine.seats[seat].isLlm = true
  engine.seats[seat].prompt = "operator guidance for seat " & $seat
  sim.seatNames[seat] = "REAL-POLICY-NAME-" & $seat
var rng = initRand(8080)

for trial in 0 ..< 200:
  for i in 0 ..< SkimmerCount:
    sim.skimmers[i].x = SkimmerRadius +
      int32(rng.next() mod uint64(ArenaW - 2 * SkimmerRadius))
    sim.skimmers[i].y = SkimmerRadius +
      int32(rng.next() mod uint64(ArenaH - 2 * SkimmerRadius))
  for f in 0 ..< FoodCount:
    sim.food[f].state = psLive
    sim.food[f].x = FoodRadius + int32(rng.next() mod uint64(ArenaW - 2 * FoodRadius))
    sim.food[f].y = FoodRadius + int32(rng.next() mod uint64(ArenaH - 2 * FoodRadius))
  for q in 0 ..< PoisonCount:
    sim.poison[q].state = psLive
    sim.poison[q].x = PoisonRadius +
      int32(rng.next() mod uint64(ArenaW - 2 * PoisonRadius))
    sim.poison[q].y = PoisonRadius +
      int32(rng.next() mod uint64(ArenaH - 2 * PoisonRadius))
  for seat in 0 ..< SkimmerCount:
    let
      skimmer = sim.skimmerForSeat(seat)
      me = sim.skimmers[skimmer]
      frame = sim.frameFor(skimmer)
      view = engine.seatViewJson(sim, seat, 9, frame)
      message = userMessage(engine.seats[seat].prompt, view)
    # A particle appears IFF its centre is within the sensor range.
    for f in 0 ..< FoodCount:
      let
        near = withinUm(sim.food[f].x, sim.food[f].y, me.x, me.y, SensorRange)
        mentioned = ("\"" & foodId(f) & "\"") in view
      if near != mentioned:
        check("plankton " & foodId(f) & " appears iff it is within 2.40 m",
          false, "trial " & $trial & " seat " & $seat)
    for q in 0 ..< PoisonCount:
      let
        near = withinUm(sim.poison[q].x, sim.poison[q].y, me.x, me.y, SensorRange)
        mentioned = ("\"" & poisonId(q) & "\"") in view
      if near != mentioned:
        check("poison " & poisonId(q) & " appears iff it is within 2.40 m",
          false, "trial " & $trial & " seat " & $seat)
    # All three partners, always.
    let parsed = parseJson(view)
    if parsed{"partners"}.len != 3:
      check("partners always has exactly three entries", false,
        $parsed{"partners"}.len)
    if parsed{"sensors"}.len != 16:
      check("sensors always has exactly sixteen entries", false,
        $parsed{"sensors"}.len)
    # NOTHING about any other seat, and no real name anywhere.
    for other in 0 ..< SkimmerCount:
      if ("REAL-POLICY-NAME-" & $other) in message:
        check("no real policy name reaches a seat", false, "seat " & $seat)
      if other != seat and ("operator guidance for seat " & $other) in message:
        check("no other seat's prompt reaches a seat", false, "seat " & $seat)
    for banned in ["perm", "\"seed\"", "rngDraws", "initialFood", "initialPoison",
        "latticeFallbacks", "policyKind", "fallback", "variant"]:
      if banned in view:
        check("the seat view leaks nothing: " & banned, false, "seat " & $seat)
    # No total for what it cannot see.
    if "\"food_total\"" in view or "\"plankton_count\"" in view:
      check("food_detected never carries a total", false)

check("200 randomised states held the locality invariant", true)

block structuralLimits:
  ## `thrustCommand`'s inputs are STRUCTURALLY limited to that skimmer's own
  ## state, its sensor frame and its seat's intent: the signature takes a
  ## SensorFrame, not the sim's particle arrays, so there is no path from the
  ## controller to a particle the skimmer has not detected.
  let source = readRepoFile("src/waterworld/control.nim")
  check("the controller never reads sim.food directly",
    "sim.food" notin source, "sim.food")
  check("the controller never reads sim.poison directly",
    "sim.poison" notin source, "sim.poison")
  check("the controller never reads perm", "sim.perm" notin source)
  check("the controller never reads the RNG", "sim.rng" notin source)
  check("the controller never reads seat names", "seatNames" notin source)
  let sensorSource = readRepoFile("src/waterworld/sensors.nim")
  check("the sensor frame never reads seat names", "seatNames" notin sensorSource)
  check("the sensor frame never reads perm", "sim.perm" notin sensorSource)

if failures > 0:
  quit("test_locality: " & $failures & " failure(s)", 1)
echo "test_locality: ok"
