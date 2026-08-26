## GameConfig lifecycle: the defaults, the platform's JSON overlay
## (`config.update`), and the resolved config JSON the replay header carries.
##
## NO FLOATING POINT. Every field is an int, a bool, a string or a seq of them,
## and `update` rejects a value it cannot use rather than silently coercing it —
## a config the platform wrote and the game misread is a whole league of
## episodes played under rules nobody chose.

import std/[json, strutils]

import sim_types

proc defaultGameConfig*(): GameConfig =
  result = GameConfig(
    seed: 8_821_477,
    tokens: @[],
    playerNames: @[],
    slotAliases: @[],
    closedRoster: false,
    numAgents: SkimmerCount,
    minPlayers: SkimmerCount,
    maxTicks: DefaultMaxTicks,
    maxGames: 1,
    turnTicks: DefaultTurnTicks,
    turnBudgetMs: DefaultTurnBudgetMs,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    turnSpacingMs: DefaultTurnSpacingMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    lobbyJoinTimeoutTicks: DefaultLobbyJoinTimeoutTicks,
    startWaitTicks: DefaultStartWaitTicks,
    gameOverTicks: DefaultGameOverTicks,
    fastMode: true,
    showPlayerLabels: false,
    speed: 1,
    model: "",
    maxOutputTokens: DefaultMaxOutputTokens,
    captureTarget: DefaultCaptureTarget,
    foodCount: FoodCount,
    poisonCount: PoisonCount,
    sensorRangeUm: int(SensorRange),
    coopNeeded: CoopNeeded,
    stunTicks: int(StunTicks),
    respawnTicks: int(RespawnTicks)
  )

proc readInt(node: JsonNode, key: string, current: int, lo, hi: int): int =
  ## One integer field, clamped into its schema range. A value of the wrong
  ## JSON kind is a config the platform got wrong: refuse it loudly.
  let value = node{key}
  if value.isNil or value.kind == JNull:
    return current
  case value.kind
  of JInt:
    clamp(int(value.getBiggestInt()), lo, hi)
  of JString:
    try: clamp(parseInt(value.getStr().strip()), lo, hi)
    except ValueError:
      raise newException(WaterworldError,
        "config." & key & " is not an integer: " & value.getStr())
  else:
    raise newException(WaterworldError,
      "config." & key & " must be an integer, got " & $value.kind)

proc readBool(node: JsonNode, key: string, current: bool): bool =
  let value = node{key}
  if value.isNil or value.kind == JNull:
    return current
  case value.kind
  of JBool: value.getBool()
  of JInt: value.getBiggestInt() != 0
  else:
    raise newException(WaterworldError,
      "config." & key & " must be a boolean, got " & $value.kind)

proc readStr(node: JsonNode, key: string, current: string): string =
  let value = node{key}
  if value.isNil or value.kind == JNull:
    return current
  if value.kind != JString:
    raise newException(WaterworldError,
      "config." & key & " must be a string, got " & $value.kind)
  value.getStr()

proc update*(config: var GameConfig, configJson: string) =
  ## Overlays the platform's episode config. Absent keys keep their default;
  ## `tests/test_manifest.nim` asserts `game.config_schema` declares exactly
  ## the set this function reads.
  if configJson.strip().len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(WaterworldError,
      "game config is not parseable JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(WaterworldError, "game config must be a JSON object")

  config.seed = node.readInt("seed", config.seed, 0, high(int32))
  config.numAgents = node.readInt("num_agents", config.numAgents, 1, SkimmerCount)
  config.minPlayers = node.readInt("minPlayers", config.numAgents, 1, SkimmerCount)
  config.maxTicks = node.readInt("maxTicks", config.maxTicks, 1, 200_000)
  config.maxGames = node.readInt("maxGames", config.maxGames, 1, 1)
  config.turnTicks = node.readInt("turnTicks", config.turnTicks, 1, 10_000)
  config.turnBudgetMs = node.readInt("turnBudgetMs", config.turnBudgetMs, 1000, 120_000)
  config.attempt1Ms = node.readInt("attempt1Ms", config.attempt1Ms, 1000, 60_000)
  config.retryMs = node.readInt("retryMs", config.retryMs, 1000, 60_000)
  config.turnSpacingMs = node.readInt("turnSpacingMs", config.turnSpacingMs, 0, 120_000)
  config.wallClockBudgetSeconds = node.readInt(
    "wallClockBudgetSeconds", config.wallClockBudgetSeconds, 10, 720)
  config.lobbyJoinTimeoutTicks = node.readInt(
    "lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks, 1, 100_000)
  config.startWaitTicks = node.readInt("startWaitTicks", config.startWaitTicks, 0, 10_000)
  config.gameOverTicks = node.readInt("gameOverTicks", config.gameOverTicks, 0, 10_000)
  config.fastMode = node.readBool("fastMode", config.fastMode)
  config.showPlayerLabels = node.readBool("showPlayerLabels", config.showPlayerLabels)
  config.closedRoster = node.readBool("closedRoster", config.closedRoster)
  config.speed = node.readInt("speed", config.speed, 1, 16)
  config.model = node.readStr("model", config.model)
  config.maxOutputTokens = node.readInt(
    "maxOutputTokens", config.maxOutputTokens, 64, 8192)
  config.captureTarget = node.readInt("captureTarget", config.captureTarget, 1, 1000)
  config.foodCount = node.readInt("foodCount", config.foodCount, 1, FoodCount)
  config.poisonCount = node.readInt("poisonCount", config.poisonCount, 0, PoisonCount)
  config.sensorRangeUm = node.readInt(
    "sensorRangeUm", config.sensorRangeUm, 100_000, int(ArenaW))
  config.coopNeeded = node.readInt("coopNeeded", config.coopNeeded, 1, SkimmerCount)
  config.stunTicks = node.readInt("stunTicks", config.stunTicks, 0, 1000)
  config.respawnTicks = node.readInt("respawnTicks", config.respawnTicks, 0, 1000)

  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      config.tokens.add(item.getStr())
  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.playerNames = @[]
    for item in players:
      if item.kind == JObject:
        config.playerNames.add(item{"name"}.getStr())
      else:
        config.playerNames.add(item.getStr())
  let slots = node{"slots"}
  if not slots.isNil and slots.kind == JArray:
    config.slotAliases = @[]
    for item in slots:
      if item.kind == JObject:
        config.slotAliases.add(item{"alias"}.getStr())
      else:
        config.slotAliases.add(item.getStr())

  if config.minPlayers > config.numAgents:
    config.minPlayers = config.numAgents
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(WaterworldError,
      "config: attempt1Ms + retryMs (" & $(config.attempt1Ms + config.retryMs) &
        ") exceeds turnBudgetMs (" & $config.turnBudgetMs & ")")

proc configuredPlayerName*(config: GameConfig, slot: int, token: string): string =
  ## The roster name the platform pinned for one slot, if any.
  if slot >= 0 and slot < config.playerNames.len:
    return config.playerNames[slot]
  if token.len > 0:
    for i, configured in config.tokens:
      if configured == token and i < config.playerNames.len:
        return config.playerNames[i]
  ""

proc playerJoinAllowed*(
  config: GameConfig, address: string, slot: int, token: string
): bool =
  ## Token/slot admission. A closed roster admits only declared slots; an open
  ## one admits any slot inside the seat count.
  if slot >= MaxPlayers:
    return false
  if slot >= 0 and slot < config.tokens.len and config.tokens[slot].len > 0:
    return token == config.tokens[slot]
  if config.closedRoster and slot >= config.numAgents:
    return false
  true

proc configJson*(config: GameConfig): string =
  ## The RESOLVED config, written into the replay header. Everything the wasm
  ## viewer needs to re-simulate lives here (seed, geometry, physics, reward
  ## constants, the roster's REAL names); the seeded initial particle table and
  ## `perm` are appended by sim.nim's `replayConfigJson`, which knows them.
  var names = newJArray()
  for name in config.playerNames:
    names.add(%*{"name": name})
  var aliases = newJArray()
  for i in 0 ..< SkimmerCount:
    aliases.add(%*{"alias": skimmerAlias(i)})
  var spawns = newJArray()
  for spawn in SkimmerSpawnUm:
    spawns.add(%*{"x": int(spawn.x), "y": int(spawn.y)})
  var foodSpeeds = newJArray()
  for value in FoodSpeedSet:
    foodSpeeds.add(%int(value))
  var poisonSpeeds = newJArray()
  for value in PoisonSpeedSet:
    poisonSpeeds.add(%int(value))
  $(%*{
    "gameName": GameName,
    "gameVersion": GameVersion,
    "seed": config.seed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "turnTicks": config.turnTicks,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "captureTarget": config.captureTarget,
    "foodCount": config.foodCount,
    "poisonCount": config.poisonCount,
    "sensorRangeUm": config.sensorRangeUm,
    "coopNeeded": config.coopNeeded,
    "stunTicks": config.stunTicks,
    "respawnTicks": config.respawnTicks,
    "players": names,
    "slots": aliases,
    "tank": {
      "w": int(ArenaW), "h": int(ArenaH), "boardScaleUm": int(BoardScaleUm),
      "mapWidth": MapWidth, "mapHeight": MapHeight,
      "rock": {"x": int(RockCentreX), "y": int(RockCentreY), "r": int(RockRadius)},
      "skimmerRadius": int(SkimmerRadius),
      "foodRadius": int(FoodRadius),
      "poisonRadius": int(PoisonRadius),
      "sensorCount": SensorCount,
      "spawns": spawns
    },
    "physics": {
      "maxThrustAccel": int(MaxThrustAccel),
      "thrustLevels": ThrustLevels,
      "dragNum": int(DragNum), "dragDen": int(DragDen),
      "maxSkimmerSpeed": int(MaxSkimmerSpeed),
      "wallRestitutionNum": int(WallRestitutionNum),
      "wallRestitutionDen": int(WallRestitutionDen),
      "foodSpeedSet": foodSpeeds,
      "poisonSpeedSet": poisonSpeeds,
      "nibbleRearmUm": int(NibbleRearmUm)
    },
    "reward": {
      "captureMicro": int(CaptureMicro),
      "nibbleMicro": int(NibbleMicro),
      "poisonMicro": int(PoisonMicro),
      "thrustMicroLevel7": int(thrustMicroFor(7))
    }
  })
