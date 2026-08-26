## Join/auth, the seat-side counters the chrome and the results document read,
## and `playerResultsJson` — the artifact the platform scores the episode from.
##
## This is where the sim's integer micro-points become the DOUBLES the results
## schema declares, which is exactly why it is a separate module from
## `sim.nim`: the determinism boundary is float-free and grep-enforced, and the
## results document is not part of it.

import std/[json, math]

import sim_types, sim, sim_state
export sim

proc scoreDouble*(sim: SimServer): float =
  ## The shared score, rounded to 3 decimals. Computed ONCE and copied into all
  ## four slots so the four numbers are bit-identical.
  round(float(sim.scoreMicro) / 1_000_000.0, 3)

proc thrustCostDouble*(sim: SimServer): float =
  round(float(sim.thrustMicro) / 1_000_000.0, 3)

proc thrustMeanPct*(sim: SimServer, seat: int): int =
  ## Mean applied thrust as a percent of full for one seat, over the ticks the
  ## episode actually played.
  let ticks = max(1, sim.gameTicksElapsed())
  int((int64(sim.thrustTicks[seat]) * 100'i64) div (int64(ticks) * 7'i64))

proc podWon*(sim: SimServer): bool {.inline.} =
  sim.captures >= int32(sim.config.captureTarget)

proc applySayBubble*(sim: var SimServer, skimmer: int, text: string) =
  ## Spectator-side speech. Never hashed, never seen by any seat: at most three
  ## bubbles live at once and each is held for 2.5 s of sim time.
  if text.len == 0 or skimmer < 0 or skimmer >= SkimmerCount:
    return
  var kept: seq[SayBubble]
  for bubble in sim.bubbles:
    if bubble.untilTick > sim.tickCount and int(bubble.skimmer) != skimmer:
      kept.add(bubble)
  kept.add SayBubble(skimmer: int32(skimmer), text: text,
    untilTick: sim.tickCount + (TargetFps * 5) div 2)
  while kept.len > 3:
    kept.delete(0)
  sim.bubbles = kept

proc pushFeedIntent*(sim: var SimServer, record: string) =
  ## Records one `intent` chat record for the broadcast feed. Called from the
  ## live server as it writes the record AND from the replay's chat
  ## re-application, so the feed tells the same story either way. Never hashed.
  if record.len == 0 or record[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(record)
  except CatchableError:
    return
  if node.kind != JObject or node{"k"}.getStr() != "intent":
    return
  sim.feedIntents.add(record)
  if sim.feedIntents.len > 8:
    sim.feedIntents.delete(0)
  let skimmer = int(node{"skimmer"}.getInt())
  sim.applySayBubble(skimmer, node{"say"}.getStr())
  let source = node{"source"}.getStr()
  let seat = int(node{"seat"}.getInt())
  if seat >= 0 and seat < sim.llmTurns.len:
    if source == "llm":
      inc sim.llmTurns[seat]
    elif source == "fallback":
      inc sim.fallbackTurns[seat]
  if node.hasKey("turn"):
    sim.turnIndex = int(node{"turn"}.getInt())

proc playerResultsJson*(sim: SimServer): string =
  ## The results document, written to COGAME_RESULTS_URI. It must equal the
  ## manifest's `results_schema` key for key — that schema is
  ## `additionalProperties: false` and the certifier rejects any unknown field,
  ## so adding or removing a key here means editing
  ## `coworld_manifest_template.json` in the SAME commit.
  ##
  ## The game is fully cooperative: ONE score, computed once and copied into all
  ## four slots so the numbers are bit-identical.
  let
    seats = SkimmerCount
    score = sim.scoreDouble()
    won = sim.podWon()
  var
    names = newJArray()
    aliases = newJArray()
    skimmerIds = newJArray()
    kinds = newJArray()
    scores = newJArray()
    wins = newJArray()
    assists = newJArray()
    nibbles = newJArray()
    poison = newJArray()
    thrustPct = newJArray()
    llmTurns = newJArray()
    fallbacks = newJArray()
  for seat in 0 ..< seats:
    let skimmer = sim.skimmerForSeat(seat)
    var name =
      if seat < sim.seatNames.len and sim.seatNames[seat].len > 0:
        sim.seatNames[seat]
      else:
        "Baseline (" & $(seat + 1) & ")"
    names.add(%name)
    aliases.add(%skimmerAlias(skimmer))
    skimmerIds.add(%skimmer)
    kinds.add(%(if seat < sim.seatPolicyKind.len and
        sim.seatPolicyKind[seat].len > 0: sim.seatPolicyKind[seat]
      else: "scripted"))
    scores.add(%score)
    wins.add(%won)
    assists.add(%int(sim.assists[seat]))
    nibbles.add(%int(sim.nibblesBySeat[seat]))
    poison.add(%int(sim.poisonBySeat[seat]))
    thrustPct.add(%sim.thrustMeanPct(seat))
    llmTurns.add(%int(sim.llmTurns[seat]))
    fallbacks.add(%int(sim.fallbackTurns[seat]))
  let reason = if sim.endReason.len > 0: sim.endReason else: ReasonComplete
  let rule = if sim.endRule.len > 0: sim.endRule else: EndRuleFullTime
  $(%*{
    "names": names,
    "aliases": aliases,
    "skimmers": skimmerIds,
    "policyKinds": kinds,
    "scores": scores,
    "win": wins,
    "sharedScore": score,
    "captures": int(sim.captures),
    "captureTarget": sim.config.captureTarget,
    "nibbles": int(sim.nibbles),
    "poisonHits": int(sim.poisonHits),
    "thrustCost": sim.thrustCostDouble(),
    "assists": assists,
    "nibblesBySeat": nibbles,
    "poisonBySeat": poison,
    "thrustMeanPct": thrustPct,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbacks,
    "finalTick": sim.gameTicksElapsed(),
    "reason": reason,
    "endRule": rule,
    "seed": sim.config.seed
  })

proc replayConfigJson*(sim: SimServer): string =
  ## The resolved config plus the two things only a live sim knows: `perm` and
  ## the SEEDED INITIAL PARTICLE TABLE. Both are needed by the viewer (it maps
  ## real names onto bodies and re-simulates from tick 0) and neither is ever
  ## visible to a seat.
  var node = parseJson(sim.config.configJson())
  var perm = newJArray()
  for seat in 0 ..< SkimmerCount:
    perm.add(%int(sim.perm[seat]))
  node["perm"] = perm
  var initialFood = newJArray()
  for f in 0 ..< FoodCount:
    initialFood.add(%*{
      "id": foodId(f), "x": int(sim.food[f].x), "y": int(sim.food[f].y),
      "dir": int(sim.food[f].dir), "speed": int(sim.food[f].speed)})
  var initialPoison = newJArray()
  for q in 0 ..< PoisonCount:
    initialPoison.add(%*{
      "id": poisonId(q), "x": int(sim.poison[q].x), "y": int(sim.poison[q].y),
      "dir": int(sim.poison[q].dir), "speed": int(sim.poison[q].speed)})
  node["initialFood"] = initialFood
  node["initialPoison"] = initialPoison
  $node
