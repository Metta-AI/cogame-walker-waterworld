## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:waterworld-train-bridge tools/train_bridge.nim

import std/[json, os, posix, strutils]
import waterworld/[sim, roster, sensors, intents, control, baselines, decide, llm]

const
  OperatorPrompt = "Coordinate the pod using only your own skimmer's sensor frame."
  Variants = ["default", "sprint"]
  Modes = ["hunt", "escort", "sweep", "hold", "avoid"]
  RayKinds = ["clear", "food", "poison", "cog", "rock", "wall"]
  Fields = ["mode", "target", "partner", "waypoint_x_cm", "waypoint_y_cm",
    "lead_ticks", "standoff_cm", "throttle255"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  result = newJArray()
  for name in Fields:
    var choices = newJArray()
    case name
    of "mode":
      for value in Modes: choices.add(%value)
    of "target":
      choices.add(%"none")
      for n in 1 .. FoodCount: choices.add(%("F" & $n))
    of "partner":
      choices.add(%"none")
      for n in 1 .. SkimmerCount: choices.add(%("SKIM-" & $n))
    else:
      let high = case name
        of "waypoint_x_cm": 1200
        of "waypoint_y_cm": 800
        of "lead_ticks": 24
        of "standoff_cm": 250
        else: 255
      for value in 0 .. high: choices.add(%value)
    result.add(%*{"name": name, "choices": choices})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  else: raise newException(ValueError, "expected numeric observation")

proc values(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in Variants: result.add(%(if variant == name: 1 else: 0))
  for field in ["turn", "of"]: result.add(%view[field].number())
  for field in ["tick", "of", "left_s"]:
    result.add(%view["clock"][field].number())
  let me = view["you"]
  result.add(%me["skimmer"].number())
  for field in ["pos", "vel"]:
    for value in me[field]: result.add(%value.number())
  for field in ["speed_m_s", "stun_ticks", "max_speed_m_s", "radius_m",
      "sensor_range_m"]:
    result.add(%me[field].number())
  for field in ["w", "h"]: result.add(%view["tank"][field].number())
  for value in view["tank"]["rock"]["c"]: result.add(%value.number())
  result.add(%view["tank"]["rock"]["r"].number())
  for ray in view["sensors"]:
    for kind in RayKinds: result.add(%(if ray["k"].getStr() == kind: 1 else: 0))
    result.add(%(if ray["d"].kind == JNull: 0.0 else: ray["d"].number()))
    result.add(%(if ray["closing"].kind == JNull: 0.0 else: ray["closing"].number()))
  for pair in [("food_detected", FoodCount), ("poison_detected", PoisonCount)]:
    let (field, count) = pair
    let detected = view[field]
    doAssert detected.len <= count
    for index in 0 ..< count:
      result.add(%(if index < detected.len: 1 else: 0))
      if index < detected.len:
        let item = detected[index]
        result.add(%item["id"].getStr().substr(1).parseInt())
        for name in ["deg", "d"]: result.add(%item[name].number())
        for name in ["pos", "vel"]:
          for value in item[name]: result.add(%value.number())
        result.add(%item["closing"].number())
      else:
        for _ in 0 ..< 8: result.add(%0)
  let partners = view["partners"]
  doAssert partners.len == SkimmerCount - 1
  for item in partners:
    result.add(%item["alias"].getStr().substr(5).parseInt())
    for name in ["deg", "d"]: result.add(%item[name].number())
    for name in ["pos", "vel"]:
      for value in item[name]: result.add(%value.number())
    result.add(%item["stun_ticks"].number())
    result.add(%(if item["in_sensors"].getBool(): 1 else: 0))
  for name in ["score", "captures", "target", "nibbles", "poison_hits", "thrust_cost"]:
    result.add(%view["pod"][name].number())
  for name in ["coop_needed", "capture_points", "nibble_points", "poison_points"]:
    result.add(%view["rules"][name].number())
  let last = view["your_last_intent"]
  result.add(%(if last.kind == JNull: 0 else: 1))
  if last.kind == JNull:
    for _ in 0 ..< 12: result.add(%0)
  else:
    for mode in Modes: result.add(%(if last["mode"].getStr() == mode: 1 else: 0))
    let target = last["target"].getStr()
    result.add(%(if target == "none": 0 else: target.substr(1).parseInt()))
    let partner = last["partner"].getStr()
    result.add(%(if partner == "none": 0 else: partner.substr(5).parseInt()))
    for value in last["waypoint"]: result.add(%value.number())
    for name in ["lead_ticks", "standoff_m", "throttle"]:
      result.add(%last[name].number())

proc action(intent: SkimmerIntent): JsonNode =
  %*{"mode": $intent.mode,
    "target": (if intent.target >= 0: "F" & $(intent.target + 1) else: "none"),
    "partner": (if intent.partner >= 0: "SKIM-" & $(intent.partner + 1) else: "none"),
    "waypoint_x_cm": int((intent.waypointXUm + 5_000) div 10_000),
    "waypoint_y_cm": int((ArenaH - intent.waypointYUm + 5_000) div 10_000),
    "lead_ticks": int(intent.leadTicks),
    "standoff_cm": int((intent.standoffMm + 5) div 10),
    "throttle255": int(intent.throttle255)}

proc hostedIntent(candidate: JsonNode): JsonNode =
  %*{"mode": candidate["mode"], "target": candidate["target"],
    "partner": candidate["partner"],
    "waypoint": [candidate["waypoint_x_cm"].getInt().float / 100.0,
      candidate["waypoint_y_cm"].getInt().float / 100.0],
    "lead_ticks": candidate["lead_ticks"],
    "standoff_m": candidate["standoff_cm"].getInt().float / 100.0 + 1e-9,
    "throttle": min(1.0, candidate["throttle255"].getInt().float / 255.0 + 1e-9)}

proc decision(view: JsonNode, seat, id: int): JsonNode =
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "walker-waterworld", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view["turn"],
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(OperatorPrompt, $view)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: waterworld-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var game: SimServer
  var engine: DecisionEngine
  var views: array[SkimmerCount, JsonNode]
  var seat = 0
  var turn = 0
  var id = 0
  let protocolFd = dup(1)
  doAssert protocolFd >= 0 and dup2(2, 1) >= 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == SkimmerCount
      var config = defaultGameConfig()
      config.update($variantConfig)
      config.seed = seedOf(request["seed"].getStr())
      game = initSimServer(config)
      for actor in 0 ..< SkimmerCount:
        discard game.addPlayer("policy-" & $actor, actor, "", trusted = true)
      var idle: array[SkimmerCount, uint8]
      while game.phase != Playing: game.step(idle)
      engine = DecisionEngine(ctl: initControlState(),
        seats: newSeq[SeatPolicy](SkimmerCount),
        intents: newSeq[SkimmerIntent](SkimmerCount),
        haveIntent: newSeq[bool](SkimmerCount))
      for actor in 0 ..< SkimmerCount: engine.intents[actor] = defaultIntent()
      turn = 0
      for actor in 0 ..< SkimmerCount:
        views[actor] = parseJson(engine.seatViewJson(game, actor, turn,
          game.frameFor(game.skimmerForSeat(actor))))
      seat = 0
      id = 0
      response = views[seat].decision(seat, id)
    of "encode":
      doAssert game.phase != GameOver
      response = %*{"decision_id": id,
        "values": views[seat].values(variant), "action_heads": heads()}
    of "teacher":
      doAssert game.phase != GameOver
      let skimmer = game.skimmerForSeat(seat)
      response = %*{"response": $action(scriptedIntent(game, blShoal,
        skimmer, game.frameFor(skimmer), turn))}
    of "step":
      doAssert game.phase != GameOver and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      engine.intents[seat] = parseIntent(candidate.hostedIntent(),
        engine.intents[seat], engine.haveIntent[seat], game.skimmerForSeat(seat))
      engine.haveIntent[seat] = true
      inc id
      inc seat
      var observation: JsonNode
      if seat < SkimmerCount:
        observation = views[seat].decision(seat, id)
      else:
        while game.phase != GameOver:
          var frames: array[SkimmerCount, SensorFrame]
          for actor in 0 ..< SkimmerCount:
            frames[actor] = game.frameFor(game.skimmerForSeat(actor))
          var commands: array[SkimmerCount, uint8]
          for skimmer in 0 ..< SkimmerCount:
            let actor = game.seatForSkimmer(skimmer)
            commands[skimmer] = engine.ctl.thrustCommand(game, skimmer,
              frames[actor], engine.intents[actor])
          game.step(commands)
          if game.phase == Playing and game.gameTicksElapsed() mod game.config.turnTicks == 0:
            turn = game.gameTicksElapsed() div game.config.turnTicks
            break
        if game.phase == GameOver:
          let score = parseJson(game.playerResultsJson())["sharedScore"].number()
          var scores = newJObject()
          var utilities = newJObject()
          for actor in 0 ..< SkimmerCount:
            scores[$actor] = %score
            utilities[$actor] = %max(-1.0, min(1.0, score / 200.0))
          observation = %*{"kind": "terminal", "scores": scores,
            "utilities": utilities}
        else:
          seat = 0
          for actor in 0 ..< SkimmerCount:
            views[actor] = parseJson(engine.seatViewJson(game, actor, turn,
              game.frameFor(game.skimmerForSeat(actor))))
          observation = views[seat].decision(seat, id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.flushFile()
    doAssert dup2(protocolFd, 1) >= 0
    stdout.writeLine($response)
    stdout.flushFile()
    doAssert dup2(2, 1) >= 0
