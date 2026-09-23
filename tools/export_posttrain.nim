## Export complete scripted Waterworld games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [default|sprint]

import std/[json, os, osproc, strutils]
import waterworld/[sim, roster, sensors, intents, control, baselines, decide, llm]

const OperatorPrompt = "Coordinate the pod using only your own skimmer's sensor frame."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [default|sprint]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["default", "sprint"]:
    quit("variant must be default or sprint", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    for seat in 0 ..< SkimmerCount:
      discard sim.addPlayer(config.playerNames[seat], seat, "", trusted = true)
    var empty: array[SkimmerCount, uint8]
    while sim.phase != Playing:
      sim.step(empty)
    var
      engine = initDecisionEngine(sim)
      rows: seq[string]
    while sim.phase != GameOver:
      let turn = sim.gameTicksElapsed() div config.turnTicks
      var frames: array[SkimmerCount, SensorFrame]
      for seat in 0 ..< SkimmerCount:
        frames[seat] = sim.frameFor(sim.skimmerForSeat(seat))
      if sim.gameTicksElapsed() mod config.turnTicks == 0:
        var views: array[SkimmerCount, string]
        var proposed: array[SkimmerCount, SkimmerIntent]
        for seat in 0 ..< SkimmerCount:
          views[seat] = engine.seatViewJson(sim, seat, turn, frames[seat])
          proposed[seat] = scriptedIntent(sim, blShoal,
            sim.skimmerForSeat(seat), frames[seat], turn)
        for seat in 0 ..< SkimmerCount:
          let intent = proposed[seat]
          let record = intent.intentRecord(turn, seat, sim.skimmerForSeat(seat))
          let completion = %*{
            "mode": record["mode"], "target": record["target"],
            "partner": record["partner"],
            "waypoint": [
              (float(intent.waypointXUm) + 0.5) / 1_000_000.0,
              (float(ArenaH - intent.waypointYUm) - 0.5) / 1_000_000.0
            ],
            "lead_ticks": int(intent.leadTicks),
            "standoff_m": float(intent.standoffMm) / 1000.0 + 1e-9,
            "throttle": min(1.0, float(intent.throttle255) / 255.0 + 1e-9),
            "say": intent.say, "note": intent.note
          }
          let parsed = parseIntent(completion, engine.intents[seat],
            engine.haveIntent[seat], sim.skimmerForSeat(seat))
          doAssert parsed.mode == intent.mode
          doAssert parsed.target == intent.target
          doAssert parsed.partner == intent.partner
          doAssert parsed.waypointXUm == intent.waypointXUm
          doAssert parsed.waypointYUm == intent.waypointYUm
          doAssert parsed.leadTicks == intent.leadTicks
          doAssert parsed.standoffMm == intent.standoffMm
          doAssert parsed.throttle255 == intent.throttle255
          rows.add($(%*{
            "episode_id": "walker-waterworld-" & variant & "-" & $seed,
            "seed": "walker-waterworld-" & variant & "-" & $seed,
            "decision_id": turn * SkimmerCount + seat,
            "prompt": [
              {"role": "system", "content": SystemPrompt},
              {"role": "user", "content": userMessage(OperatorPrompt, views[seat])}
            ],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "walker-waterworld",
            "action_schema_revision": "waterworld-intent-v1"
          }))
          engine.intents[seat] = intent
          engine.haveIntent[seat] = true
      var cmds: array[SkimmerCount, uint8]
      for skimmer in 0 ..< SkimmerCount:
        let seat = sim.seatForSkimmer(skimmer)
        cmds[skimmer] = engine.ctl.thrustCommand(sim, skimmer,
          frames[seat], engine.intents[seat])
      sim.step(cmds)
    let outcome = parseJson(sim.playerResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete and rows.len > 0
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": outcome["sharedScore"], "win": outcome["win"][0]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "walker-waterworld",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-shoal",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
