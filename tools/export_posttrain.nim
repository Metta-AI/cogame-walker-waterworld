## Export complete scripted Waterworld games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [default|sprint]

import std/[json, os, osproc, strutils]
import waterworld/[sim, roster, sensors, intents, control, baselines, decide, llm, prompts, evidence]

const OperatorPrompt = "Coordinate the pod using only your own skimmer's sensor frame."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [default|sprint] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "default"
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len >= 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin ["default", "sprint"]:
    quit("variant must be default or sprint", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
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
      engine = initDecisionEngine(sim, selection)
      rows = newJArray()
      latest: array[SkimmerCount, int]
    let family = "walker-waterworld-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
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
          let completion = intent.intentAction()
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
          engine.intents[seat] = parsed
          engine.haveIntent[seat] = true
          let executed = engine.intents[seat].intentAction()
          doAssert executed == completion
          let system = systemPrompt(selection)
          let user = userMessage(OperatorPrompt, views[seat])
          let observation = parseJson(views[seat])
          observation["prompt_template"] = selection.promptMetadata(system, user)
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          let attemptId = $rows.len & "-teacher"
          latest[seat] = rows.len
          rows.add(%*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $rows.len, "decision_index": rows.len,
            "game": "walker-waterworld", "game_version": "source-" & sourceRevision,
            "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
            "observation": observation, "prompt": messages,
            "attempts": [{"attempt_id": attemptId, "policy": "scripted-shoal",
              "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
              "response": $completion, "parsed_action": executed, "accepted": true,
              "request": newJNull(), "platform_call_id": newJNull(),
              "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
            "selected_attempt_id": attemptId, "executed_action": executed,
            "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
      var cmds: array[SkimmerCount, uint8]
      for skimmer in 0 ..< SkimmerCount:
        let seat = sim.seatForSkimmer(skimmer)
        cmds[skimmer] = engine.ctl.thrustCommand(sim, skimmer,
          frames[seat], engine.intents[seat])
      sim.step(cmds)
    let outcome = parseJson(sim.playerResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete and rows.len > 0
    var outcomes = newJObject()
    for seat in 0 ..< SkimmerCount:
      rows[latest[seat]]["terminal"] = %true
      outcomes[$seat] = %*{"score": outcome["sharedScore"]}
    for row in rows: stream.writeLine($row)
    stream.writeLine($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "walker-waterworld", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed", "outcome": outcome,
      "participant_outcomes": outcomes}))
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "score": outcome["sharedScore"], "win": outcome["win"][0]})
  stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "walker-waterworld",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-shoal",
    "operator_prompt": OperatorPrompt,
    "prompt_configuration": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", episodes
