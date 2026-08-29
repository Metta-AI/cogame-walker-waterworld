## An END-TO-END episode writing a replay, re-simulated from the recorded bytes,
## and read back through the Python forensics tool under a STRICT UTF-8 parser.

import std/[json, os, osproc, strutils, unicode]

import helpers
import waterworld/[sim, roster, sensors, intents, control, baselines, replays,
  replay_runtime, broadcast]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

let work = getTempDir() / "waterworld-test-replay"
createDir(work)
let
  replayPath = work / "episode.replay"
  resultsPath = work / "results.json"

# --- record a full four-seat scripted episode ------------------------------
var tank = seatedSim(maxTicks = 720)
# The fixture is FORCED to carry non-ASCII strings so the UTF-8 path is real,
# not hypothetical: a policy label and a `say` with a 4-byte emoji in them.
tank.seatNames[0] = "policy-\u{1F41F}-one"
var writer = openReplayWriter(replayPath, tank.replayConfigJson())
while writer.lastMasks.len < SkimmerCount:
  writer.lastMasks.add(0'u8)
for seat in 0 ..< SkimmerCount:
  writer.writeJoin(tickTime(0), seat, tank.players[seat].address, seat,
    "t" & $seat)
  writer.writeChat(tickTime(0), seat,
    registerRecord(seat, tank.skimmerForSeat(seat), "shoal", "scripted", "shoal"))

var ctl = initControlState()
var seatIntents = newSeq[SkimmerIntent](SkimmerCount)
var haveIntent = newSeq[bool](SkimmerCount)
var turns = 0
var intentRecords = 0
while tank.phase != GameOver:
  let turnTicks = max(1, tank.config.turnTicks)
  let turnIndex = tank.gameTicksElapsed() div turnTicks
  var frames: seq[SensorFrame]
  for seat in 0 ..< SkimmerCount:
    frames.add(tank.frameFor(tank.skimmerForSeat(seat)))
  if tank.phase == Playing and tank.gameTicksElapsed() mod turnTicks == 0:
    inc turns
    for seat in 0 ..< SkimmerCount:
      var intent = shoalIntent(tank, tank.skimmerForSeat(seat), frames[seat],
        turnIndex)
      intent.source = isScripted
      if seat == 0:
        intent.say = sanitizeSay("holding it \u{1F41F} come here")
        intent.note = "a non-ASCII note \u{1F41F} for the UTF-8 path"
      seatIntents[seat] = intent
      haveIntent[seat] = true
      let record = intent.boundedIntentRecord(turnIndex, seat,
        tank.skimmerForSeat(seat))
      writer.writeChat(tickTime(tank.tickCount), seat, record)
      tank.pushFeedIntent(record)
      inc intentRecords
  var cmds: array[SkimmerCount, uint8]
  for i in 0 ..< SkimmerCount:
    let seat = tank.seatForSkimmer(i)
    let intent = if haveIntent[seat]: seatIntents[seat] else: defaultIntent()
    cmds[i] = ctl.thrustCommand(tank, i, frames[seat], intent)
  for i in 0 ..< SkimmerCount:
    writer.writeInputMaskChange(tickTime(tank.tickCount), i, cmds[i])
  tank.step(cmds)
  writer.writeHash(uint32(tank.tickCount), tank.gameHash())
writer.writeChat(tickTime(tank.tickCount), 0,
  "{\"k\":\"result\",\"results\":" & tank.playerResultsJson() & "}")
writer.closeReplayWriter()
writeFile(resultsPath, tank.playerResultsJson() & "\n")

check("the episode wrote a replay", fileExists(replayPath) and
  getFileSize(replayPath) > 1000, $getFileSize(replayPath))
check("the episode wrote results.json", fileExists(resultsPath))
check("the episode produced at least one capture", tank.captures >= 1,
  $tank.captures)
check("the episode produced at least one nibble", tank.nibbles >= 1,
  $tank.nibbles)

# --- parse and re-simulate -------------------------------------------------
let data = parseReplayBytes(readFile(replayPath))
check("parseReplayBytes accepts it", data.hashes.len > 100, $data.hashes.len)
check("the header carries the game name", data.gameName == GameName, data.gameName)
check("the header carries the game version", data.gameVersion == GameVersion,
  data.gameVersion)
check("the stream has exactly 4 joins", data.joins.len == 4, $data.joins.len)

block configJsonIsSelfSufficient:
  let config = parseJson(data.configJson)
  check("the config JSON decodes strictly", config.kind == JObject)
  check("it carries the seed", config{"seed"}.getInt() == 8_821_477)
  check("it carries perm", config{"perm"}.len == SkimmerCount)
  check("it carries the geometry table", config{"tank"}{"rock"}{"r"}.getInt() ==
    int(RockRadius))
  check("it carries the initial plankton table",
    config{"initialFood"}.len == FoodCount)
  check("it carries the initial poison table",
    config{"initialPoison"}.len == PoisonCount)
  check("it carries the REAL policy names spectator-side",
    config{"players"}.len == SkimmerCount)

block reSimulation:
  ## The browser's job, in this process: re-derive the whole episode from the
  ## config and the recorded command bytes and match EVERY recorded hash.
  # A FRESH sim from the recorded config, stepped only from the recorded bytes —
  # exactly the browser's path. mismatchQuit makes a divergence raise rather
  # than degrade, because in a test a mismatch is the finding.
  var replayConfig = defaultGameConfig()
  replayConfig.update(data.configJson)
  var replaySim = initSimServer(replayConfig)
  replaySim.gameEventLoggingEnabled = false
  var player = initReplayPlayer(data)
  player.mismatchQuit = true
  var checked = 0
  var raised = ""
  try:
    while player.hashIndex < data.hashes.len and
        replaySim.tickCount < player.replayMaxTick():
      player.stepReplay(replaySim)
      inc checked
  except ReplayError as error:
    raised = error.msg
  check("re-simulating reproduced every recorded hash", raised.len == 0, raised)
  check("the re-simulation walked the whole episode", checked > 100, $checked)
  check("the re-simulated final score matches the recording",
    replaySim.scoreMicro == tank.scoreMicro,
    $replaySim.scoreMicro & " vs " & $tank.scoreMicro)

  # And the shared replay runtime (the one the wasm entry calls) boots, scans
  # and lands on the spectator start.
  var initialized = initReplayRuntime(data, mismatchQuit = false,
    gameEventLoggingEnabled = false)
  var scanned = initialized.player
  var scanSim = initialized.sim
  var guard = 0
  while not scanned.scanComplete() and guard < 10_000:
    scanned.advanceReplayScan(256)
    inc guard
  check("the precompute walk completes", scanned.scanComplete())
  check("the scan produced a score series", scanned.leadSeries.len >= 2,
    $scanned.leadSeries.len)
  check("the scan produced keyframes", scanned.keyframes.len >= 2,
    $scanned.keyframes.len)
  check("a keyframe seek lands on its tick", (block:
    scanned.seekReplay(scanSim, 300)
    scanSim.tickCount == 300), $scanSim.tickCount)

block chatRecords:
  var registers = 0
  var intents = 0
  var results = 0
  var perTurn: seq[int]
  for chat in data.chats:
    if chat.message.len == 0 or chat.message[0] != '{':
      continue
    let node = parseJson(chat.message)
    case node{"k"}.getStr()
    of "register": inc registers
    of "intent":
      inc intents
      check("every intent record is <= 600 runes",
        chat.message.runeLen <= MaxIntentRecordRunes, $chat.message.runeLen)
    of "result": inc results
    else: discard
  check("the stream contains exactly 4 register records", registers == 4,
    $registers)
  check("the stream contains 4 intent records per turn",
    intents == turns * SkimmerCount, $intents & " for " & $turns & " turns")
  check("the stream contains exactly one result record", results == 1, $results)

block strictUtf8Forensics:
  ## tools/replay_summary.py output must parse under a STRICT UTF-8 JSON parser,
  ## with the fixture carrying a non-ASCII policy label and a non-ASCII note.
  let script = repoRoot() / "tools" / "replay_summary.py"
  check("the forensics tool is present", fileExists(script))
  let (output, code) = execCmdEx("python3 " & quoteShell(script) & " " &
    quoteShell(replayPath))
  check("replay_summary.py exits 0", code == 0, output.strip())
  if code == 0:
    check("its output is valid UTF-8", output.validateUtf8() == -1)
    let summary = parseJson(output)
    check("the protocol is walker-waterworld/v1",
      summary{"protocol"}.getStr() == "walker-waterworld/v1",
      summary{"protocol"}.getStr())
    check("it reports the gameVersion",
      summary{"gameVersion"}.getStr() == GameVersion)
    check("it reports the seed", summary{"seed"}.getInt() == 8_821_477)
    check("it reports the real names spectator-side",
      summary{"names"}.len == SkimmerCount)
    check("it reports the intents", summary{"intents"}.len == turns * SkimmerCount,
      $summary{"intents"}.len)
    check("it reports the results document",
      summary{"results"}{"reason"}.getStr() in
        ["complete", "deadline", "fault"],
      summary{"results"}{"reason"}.getStr())
    check("the results carry the legal endRule enum",
      summary{"results"}{"endRule"}.getStr() in
        ["target_met", "full_time", "wall_clock", "sim_fault", "host_error"])
    check("the action log recorded more than one distinct command byte",
      summary{"distinctCommandBytes"}.getInt() > 1,
      $summary{"distinctCommandBytes"}.getInt())
    check("the non-ASCII policy label survived the round trip",
      "\u{1F41F}" in output, "no emoji in the summary")

# --- the replay-only 1/2x playback speed -----------------------------------
block halfSpeedIsAReplayOnlyCrawl:
  ## Command '5' selects ReplayHalfSpeedIndex: the chrome shows 0.5, every
  ## integer consumer still sees 1, and the step budget spends one tick every
  ## OTHER frame outside a skipped lull.
  var replay = ReplayPlayer()
  replay.speedIndex = 0
  applySpeedCommand(replay.speedIndex, '5')
  check("'5' selects 1/2x", replay.speedIndex == ReplayHalfSpeedIndex,
    $replay.speedIndex)
  check("the chrome speed at 1/2x is 0.5",
    replay.replayDisplaySpeed() == 0.5, $replay.replayDisplaySpeed())
  check("the integer speed clamps to 1x at 1/2x",
    replay.replaySpeed() == 1, $replay.replaySpeed())
  replay.skipLulls = false
  replay.halfPhase = false
  check("an even frame at 1/2x spends no tick", replay.replayStepBudget(0) == 0,
    $replay.replayStepBudget(0))
  replay.halfPhase = true
  check("an odd frame at 1/2x spends one tick", replay.replayStepBudget(0) == 1,
    $replay.replayStepBudget(0))
  applySpeedCommand(replay.speedIndex, '+')
  check("'+' from 1/2x lands on 1x", replay.speedIndex == 0, $replay.speedIndex)
  check("1x shows as 1.0", replay.replayDisplaySpeed() == 1.0,
    $replay.replayDisplaySpeed())
  applySpeedCommand(replay.speedIndex, '-')
  check("'-' from 1x lands on 1/2x",
    replay.speedIndex == ReplayHalfSpeedIndex, $replay.speedIndex)
  applySpeedCommand(replay.speedIndex, '-')
  check("1/2x is the floor", replay.speedIndex == ReplayHalfSpeedIndex,
    $replay.speedIndex)
  applySpeedCommand(replay.speedIndex, '6')
  check("'6' still selects 16x", replay.replayDisplaySpeed() == 16.0,
    $replay.replayDisplaySpeed())

block halfSpeedPlaysTheRealReplayAtHalfPace:
  ## The pace on the REAL playback path: eight frames of advanceReplayPlayback
  ## on the recorded episode spend eight ticks at 1x and four at 1/2x.
  proc ticksOver(frames: int, command: char): int =
    var runtime = initReplayRuntime(data, mismatchQuit = false,
      gameEventLoggingEnabled = false)
    var player = runtime.player
    var sim = runtime.sim
    player.skipLulls = false
    player.playing = true
    player.applyReplayCommand(sim, command)
    let before = sim.tickCount
    let noop = proc () = discard
    for _ in 0 ..< frames:
      player.advanceReplayPlayback(sim, noop, noop)
    sim.tickCount - before
  let full = ticksOver(8, '1')
  let half = ticksOver(8, '5')
  check("1x spends one tick per frame", full == 8, $full)
  check("1/2x spends half as many", half == full div 2, $half & " vs " & $full)

removeDir(work)
if failures > 0:
  quit("test_replay: " & $failures & " failure(s)", 1)
echo "test_replay: ok"
