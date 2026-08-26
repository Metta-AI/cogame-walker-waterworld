## Shared test fixtures. Every test drives the game the way the SERVER does —
## sensor frame, intent, controller, command byte, step — so a test can never
## pass against a code path production does not take.

import std/[json, os, random]

import waterworld/[sim, roster, sensors, intents, control, baselines]

export sim, roster, sensors, intents, control, baselines

proc testConfig*(seed = 8_821_477, maxTicks = 1728): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  result.startWaitTicks = 0
  result.gameOverTicks = 0
  result.turnSpacingMs = 0
  result.playerNames = @["alpha", "bravo", "charlie", "delta"]
  result.tokens = @["t0", "t1", "t2", "t3"]

proc seatedSim*(seed = 8_821_477, maxTicks = 1728): SimServer =
  ## A sim with all four seats joined and the tank already Playing.
  result = initSimServer(testConfig(seed, maxTicks))
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< SkimmerCount:
    discard result.addPlayer("policy-" & $seat, seat, "t" & $seat, trusted = true)
  var empty: array[SkimmerCount, uint8]
  while result.phase != Playing:
    result.step(empty)

type ScriptedRun* = object
  ## One fully driven episode: the command-byte log (by skimmer index, exactly
  ## as the replay records it) and the per-tick hash chain.
  cmdLog*: seq[array[SkimmerCount, uint8]]
  hashes*: seq[uint64]
  ticks*: int

proc runScripted*(
  sim: var SimServer, kind = blShoal, ticks = 0,
  params = DefaultBaselineParams
): ScriptedRun =
  ## Plays the pod with one scripted baseline through the REAL controller, for
  ## `ticks` ticks (0 = to the end of the episode).
  var ctl = initControlState()
  var seatIntents = newSeq[SkimmerIntent](SkimmerCount)
  var haveIntent = newSeq[bool](SkimmerCount)
  let limit = if ticks > 0: ticks else: sim.config.maxTicks + 4
  var stepped = 0
  while sim.phase != GameOver and stepped < limit:
    let turnTicks = max(1, sim.config.turnTicks)
    let turnIndex = sim.gameTicksElapsed() div turnTicks
    var frames: seq[SensorFrame]
    for seat in 0 ..< SkimmerCount:
      frames.add(sim.frameFor(sim.skimmerForSeat(seat)))
    if sim.phase == Playing and sim.gameTicksElapsed() mod turnTicks == 0:
      for seat in 0 ..< SkimmerCount:
        seatIntents[seat] = scriptedIntent(
          sim, kind, sim.skimmerForSeat(seat), frames[seat], turnIndex, params)
        haveIntent[seat] = true
    var cmds: array[SkimmerCount, uint8]
    for i in 0 ..< SkimmerCount:
      let seat = sim.seatForSkimmer(i)
      let intent =
        if haveIntent[seat]: seatIntents[seat] else: defaultIntent()
      cmds[i] = ctl.thrustCommand(sim, i, frames[seat], intent)
    result.cmdLog.add(cmds)
    sim.step(cmds)
    result.hashes.add(sim.gameHash())
    inc stepped
  result.ticks = stepped

proc replaySteps*(config: GameConfig, log: seq[array[SkimmerCount, uint8]]): seq[uint64] =
  ## Re-simulates a recorded byte log from a FRESH sim — the browser's job, in
  ## the same process.
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  for seat in 0 ..< SkimmerCount:
    discard sim.addPlayer("policy-" & $seat, seat, "t" & $seat, trusted = true)
  for cmds in log:
    sim.step(cmds)
    result.add(sim.gameHash())

proc mixedRun*(
  sim: var SimServer, kinds: array[SkimmerCount, Baseline], ticks = 0
): ScriptedRun =
  ## The same drive loop with a per-seat baseline, for the cross-play mix.
  var ctl = initControlState()
  var seatIntents = newSeq[SkimmerIntent](SkimmerCount)
  var haveIntent = newSeq[bool](SkimmerCount)
  let limit = if ticks > 0: ticks else: sim.config.maxTicks + 4
  var stepped = 0
  while sim.phase != GameOver and stepped < limit:
    let turnTicks = max(1, sim.config.turnTicks)
    let turnIndex = sim.gameTicksElapsed() div turnTicks
    var frames: seq[SensorFrame]
    for seat in 0 ..< SkimmerCount:
      frames.add(sim.frameFor(sim.skimmerForSeat(seat)))
    if sim.phase == Playing and sim.gameTicksElapsed() mod turnTicks == 0:
      for seat in 0 ..< SkimmerCount:
        seatIntents[seat] = scriptedIntent(
          sim, kinds[seat], sim.skimmerForSeat(seat), frames[seat], turnIndex)
        haveIntent[seat] = true
    var cmds: array[SkimmerCount, uint8]
    for i in 0 ..< SkimmerCount:
      let seat = sim.seatForSkimmer(i)
      let intent = if haveIntent[seat]: seatIntents[seat] else: defaultIntent()
      cmds[i] = ctl.thrustCommand(sim, i, frames[seat], intent)
    result.cmdLog.add(cmds)
    sim.step(cmds)
    inc stepped
  result.ticks = stepped

proc repoRoot*(): string = getCurrentDir()

proc readRepoFile*(path: string): string = readFile(repoRoot() / path)

proc manifest*(): JsonNode =
  parseJson(readRepoFile("coworld_manifest_template.json"))
