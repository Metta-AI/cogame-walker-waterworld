## The `COWLDWWD` replay codec wrapper and the playback machine: keyframes, the
## incremental whole-match precompute walk (momentum series, story beats, lull
## spans), the transport commands, bounded seeks, and the per-tick hash check.
##
## Inherited from `coworld-ctf/src/ctf/replays.nim` with TWO named edits:
##
##   1. `serializeReplaySim`/`deserializeReplaySim` cover waterworld's sim
##      fields — and there is no static-bake swap, because waterworld's render
##      caches live in `global.nim`'s module globals rather than inside
##      SimServer, so a keyframe is already just the world.
##   2. THE ACTION LOG IS A VALUE BYTE, NOT A BUTTON MASK. ctf's press/release
##      wrapper (`writeInputFrameMasks`, `pressedMasks`, `lastAppliedMasks`) is
##      deleted: its repeated-press logic is button semantics and would corrupt
##      a thrust byte. The codec's own change-only guard in
##      `writeInputMaskChange` is the whole of the recording rule, and playback
##      simply holds the last byte per seat until the next change record.

import std/json

import flatty
import bitworld/replays as replayCodec

import sim_types, sim, roster, broadcast

export replayCodec

type
  ReplayKeyframe* = object
    tick*: int
    simBytes*: string
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    cmds*: seq[uint8]
    hashValidationFailed*: bool
    hashMismatchTick*: int

  ReplayScan* = ref object
    ## Working state of the incremental precompute walk: a second sim + player
    ## stepped from tick 0 that derives keyframes, the score series, the story
    ## beats and the lull spans without touching the on-screen playback state.
    sim*: SimServer
    builder*: ReplayPlayer
    beatTracker*: BroadcastTracker
    beatTicks*: seq[int]
    lastScore*: int64
    interval*: int
    maxTick*: int

  ReplayPlayer* = object
    data*: ReplayData
    joinIndex*: int
    leaveIndex*: int
    chatIndex*: int
    inputIndex*: int
    hashIndex*: int
    cmds*: seq[uint8]
    playing*: bool
    looping*: bool
    speedIndex*: int
      ## Index into PlaybackSpeeds, or ReplayHalfSpeedIndex (-1) for the
      ## replay-only 1/2x speed (one sim tick every other frame).
    halfPhase*: bool
      ## Frame parity while at 1/2x: a tick is spent only on the frames this
      ## is true for, toggled once per advanceReplayPlayback frame.
    mismatchQuit*: bool
    hashValidationFailed*: bool
    hashMismatchTick*: int
    keyframes*: seq[ReplayKeyframe]
    startTick*: int
    leadSeries*: seq[seq[int]]
      ## [tick, scoreMilliPoints] change-points across the WHOLE episode: the
      ## pod's cumulative score curve, so the momentum graph draws its whole
      ## shape at once instead of accumulating as it plays.
    endHoldFrames*: int
    pendingSeekTick*: int
    skipLulls*: bool
    lullSpans*: seq[array[2, int]]
    beatEvents*: JsonNode
    scan: ReplayScan
    scanDone: bool

const
  ReplayHalfSpeedIndex* = -1
    ## speedIndex sentinel for 1/2x playback: one sim tick every other frame.
    ## Replay-only — replaySpeed() clamps it back to PlaybackSpeeds[0] (1x) for
    ## every integer consumer.
  ReplayKeyframeTicks* = 100
  ReplayEndHoldSeconds* = 10
  LullLeadTicks* = 2 * ReplayFps
  MinLullTicks* = 6 * ReplayFps
  LullSpeedBoost* = 8
  MaxLullTicksPerFrame* = 64
  SeekTicksPerFrame* = 240
  WaterworldReplayMagic* = "COWLDWWD"
  WaterworldReplayFormatVersion* = 1'u16
  WaterworldReplaySpec* = ReplaySpec(
    magic: WaterworldReplayMagic,
    formatVersion: WaterworldReplayFormatVersion,
    gameName: GameName,
    gameVersion: GameVersion,
    joinKind: rjkNameSlotToken,
    allowChat: true,
    allowCompressed: true,
    hashOrder: rhoStop
  )

proc tickTime*(tick: int): uint32 =
  replayCodec.tickTime(tick, ReplayFps)

proc writeInputMaskChange*(
  replayWriter: var ReplayWriter, time: uint32, seat: int, cmd: uint8
) =
  ## Writes one replay input event when a skimmer's applied COMMAND BYTE
  ## changes. Lives here rather than in server.nim because the byte log IS the
  ## replay's action stream: the tests that prove the recorded bytes re-simulate
  ## to the identical hash chain have to write it exactly the way the server
  ## does, and two copies of this would be two chances to drift.
  if seat < 0 or seat >= replayWriter.lastMasks.len:
    return
  if replayWriter.lastMasks[seat] == cmd:
    return
  replayWriter.writeInput(ReplayInput(time: time, player: uint8(seat), keys: cmd))
  replayWriter.lastMasks[seat] = cmd

proc openReplayWriter*(path: string, configJson: string): ReplayWriter =
  replayCodec.openReplayWriter(path, configJson, WaterworldReplaySpec)

proc parseReplayBytes*(bytes: string): ReplayData =
  replayCodec.parseReplayBytes(bytes, WaterworldReplaySpec)

proc loadReplay*(path: string): ReplayData =
  replayCodec.loadReplay(path, WaterworldReplaySpec)

proc serializeReplaySim*(sim: var SimServer): string =
  ## One sim state for a replay keyframe. Keyframes are how the viewer seeks, so
  ## every field the step loop reads has to survive the round trip; the static
  ## geometry and `perm` are excluded from nothing here only because they are
  ## part of SimServer — the CONFIG JSON carries them too, which is what a
  ## viewer reads before the first keyframe exists.
  sim.toFlatty()

proc deserializeReplaySim*(bytes: string): SimServer =
  bytes.fromFlatty(SimServer)

proc initReplayPlayer*(data: ReplayData): ReplayPlayer =
  result.data = data
  result.cmds = @[]
  result.playing = true
  result.looping = true
  result.speedIndex = 0
  result.skipLulls = true
  result.hashMismatchTick = -1
  result.pendingSeekTick = -1
  result.startTick = -1
  result.beatEvents = newJArray()

proc replaySpeed*(replay: ReplayPlayer): int =
  ## The integer playback speed (1 while at 1/2x — the fractional pace lives in
  ## replayStepBudget's frame parity, not in this number).
  PlaybackSpeeds[clamp(replay.speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(replay: ReplayPlayer): float =
  ## The speed the chrome shows and highlights a chip for: 0.5 at 1/2x, else
  ## the integer speed.
  if replay.speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(replay.replaySpeed())

proc replayMaxTick*(replay: ReplayPlayer): int =
  if replay.data.hashes.len == 0:
    return 0
  int(replay.data.hashes[^1].tick)

proc replayStartTick*(replay: ReplayPlayer): int =
  clamp(max(0, replay.startTick), 0, replay.replayMaxTick())

proc resetReplay*(replay: var ReplayPlayer) =
  replay.joinIndex = 0
  replay.leaveIndex = 0
  replay.chatIndex = 0
  replay.inputIndex = 0
  replay.hashIndex = 0
  replay.hashValidationFailed = false
  replay.hashMismatchTick = -1
  replay.cmds = @[]

proc saveReplayKeyframe(replay: ReplayPlayer, sim: var SimServer): ReplayKeyframe =
  ReplayKeyframe(
    tick: sim.tickCount,
    simBytes: serializeReplaySim(sim),
    joinIndex: replay.joinIndex,
    leaveIndex: replay.leaveIndex,
    chatIndex: replay.chatIndex,
    inputIndex: replay.inputIndex,
    hashIndex: replay.hashIndex,
    cmds: replay.cmds,
    hashValidationFailed: replay.hashValidationFailed,
    hashMismatchTick: replay.hashMismatchTick
  )

proc restoreReplayKeyframe(
  replay: var ReplayPlayer, sim: var SimServer, keyframe: ReplayKeyframe
) =
  let logging = sim.gameEventLoggingEnabled
  var restored = deserializeReplaySim(keyframe.simBytes)
  restored.gameEventLoggingEnabled = logging
  sim = move(restored)
  replay.joinIndex = keyframe.joinIndex
  replay.leaveIndex = keyframe.leaveIndex
  replay.chatIndex = keyframe.chatIndex
  replay.inputIndex = keyframe.inputIndex
  replay.hashIndex = keyframe.hashIndex
  replay.cmds = keyframe.cmds
  replay.hashValidationFailed = keyframe.hashValidationFailed
  replay.hashMismatchTick = keyframe.hashMismatchTick

proc replayKeyframeIndex(replay: ReplayPlayer, tick: int): int =
  for i, keyframe in replay.keyframes:
    if keyframe.tick > tick:
      break
    result = i

proc ensureSeat(replay: var ReplayPlayer, seat: int) =
  while replay.cmds.len <= seat:
    replay.cmds.add(0'u8)

proc applyReplayEvents(replay: var ReplayPlayer, sim: var SimServer) =
  ## Applies replay joins, leaves, command bytes and chat records for the
  ## current tick.
  let time = tickTime(sim.tickCount)
  while replay.leaveIndex < replay.data.leaves.len and
      replay.data.leaves[replay.leaveIndex].time <= time:
    let leave = replay.data.leaves[replay.leaveIndex]
    ## A leave does NOT shift the command array: the skimmers are fixed for the
    ## whole episode and the recorded bytes are indexed BY SKIMMER INDEX (the
    ## index `sim.step` consumes -- see server.nim's write loop), so deleting a
    ## row would silently re-point every later byte at the wrong skimmer.
    if int(leave.player) >= 0 and int(leave.player) < sim.players.len:
      sim.removePlayerAt(int(leave.player))
    inc replay.leaveIndex

  while replay.joinIndex < replay.data.joins.len and
      replay.data.joins[replay.joinIndex].time <= time:
    let join = replay.data.joins[replay.joinIndex]
    if int(join.player) != sim.players.len:
      raise newException(ReplayError, "Replay player join order is invalid")
    discard sim.addPlayer(join.name, join.slot, join.token, trusted = true)
    replay.ensureSeat(int(join.player))
    inc replay.joinIndex

  while replay.inputIndex < replay.data.inputs.len and
      replay.data.inputs[replay.inputIndex].time <= time:
    let input = replay.data.inputs[replay.inputIndex]
    replay.ensureSeat(int(input.player))
    replay.cmds[int(input.player)] = input.keys
    inc replay.inputIndex

  while replay.chatIndex < replay.data.chats.len and
      replay.data.chats[replay.chatIndex].time <= time:
    let chat = replay.data.chats[replay.chatIndex]
    ## CONTROL records (register / intent / fallback / budget_guard / result)
    ## ride the chat stream as JSON objects and are NOT applied as gameplay:
    ## the live server never applied them as gameplay either, so applying them
    ## here would move the hash chain. `intent` records feed the presentation
    ## layer (the match feed, the speech bubbles, the seat counters) and
    ## nothing else.
    if chat.message.len > 0 and chat.message[0] == '{':
      sim.pushFeedIntent(chat.message)
    inc replay.chatIndex

proc checkReplayHash(replay: var ReplayPlayer, sim: SimServer) =
  if replay.hashValidationFailed:
    if sim.tickCount >= replay.replayMaxTick():
      replay.playing = false
    return
  if replay.hashIndex >= replay.data.hashes.len:
    replay.playing = false
    return
  let expected = replay.data.hashes[replay.hashIndex]
  if int(expected.tick) < sim.tickCount:
    let message = "Replay hash tick is missing at tick " & $sim.tickCount & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  if int(expected.tick) > sim.tickCount:
    return
  let hash = sim.gameHash()
  if hash != expected.hash:
    let message = "Replay hash mismatch at tick " & $sim.tickCount &
      "; expected " & $expected.hash & ", got " & $hash & "."
    if replay.mismatchQuit:
      raise newException(ReplayError, message)
    echo message
    replay.hashValidationFailed = true
    replay.hashMismatchTick = sim.tickCount
    return
  inc replay.hashIndex

proc stepReplay*(replay: var ReplayPlayer, sim: var SimServer) =
  ## Advances replay by one simulation tick, from the RECORDED bytes only.
  replay.applyReplayEvents(sim)
  while replay.cmds.len < SkimmerCount:
    replay.cmds.add(0'u8)
  sim.step(replay.cmds)
  replay.checkReplayHash(sim)

proc buildLullSpans*(
  beatTicks: seq[int], startTick, maxTick: int
): seq[array[2, int]] =
  ## The quiet spans between beats, keeping LullLeadTicks of context on both
  ## sides and dropping spans shorter than MinLullTicks: skipping a short
  ## breather is more jarring than watching it.
  var prevBeat = startTick
  for i in 0 .. beatTicks.len:
    let nextBeat =
      if i < beatTicks.len: beatTicks[i]
      else: maxTick + LullLeadTicks + 1
    let
      a = prevBeat + LullLeadTicks + 1
      b = min(nextBeat - LullLeadTicks - 1, maxTick)
    if b - a + 1 >= MinLullTicks:
      result.add([a, b])
    if i < beatTicks.len:
      prevBeat = nextBeat

proc scanComplete*(replay: ReplayPlayer): bool = replay.scanDone

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int)

proc initReplayScan*(
  replay: var ReplayPlayer, initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  replay.keyframes = @[]
  replay.leadSeries = @[]
  replay.lullSpans = @[]
  replay.beatEvents = newJArray()
  replay.scanDone = false
  var scan = ReplayScan(interval: max(interval, 1))
  scan.sim = initialSim
  scan.sim.gameEventLoggingEnabled = false
  scan.builder = initReplayPlayer(replay.data)
  scan.builder.looping = false
  scan.builder.mismatchQuit = replay.mismatchQuit
  scan.maxTick = scan.builder.replayMaxTick()
  replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
  scan.lastScore = scan.sim.scoreMicro
  replay.leadSeries.add(@[scan.sim.tickCount, int(scan.sim.scoreMicro div 1000'i64)])
  scan.beatTracker = initBroadcastTracker()
  scan.beatTracker.resync(scan.sim)
  replay.startTick =
    if scan.sim.phase == Playing: scan.sim.gameStartTick else: -1
  replay.scan = scan
  replay.advanceReplayScan(0)

proc advanceReplayScan*(replay: var ReplayPlayer, maxTicks: int) =
  ## Advances the precompute walk by up to `maxTicks` ticks; when it stops it
  ## derives the lull spans from whatever prefix it covered and marks the lead
  ## chrome ready. No-op once finished.
  if replay.scan == nil:
    return
  let scan = replay.scan
  var stepsLeft = maxTicks
  while stepsLeft > 0 and scan.builder.playing and
      scan.sim.tickCount < scan.maxTick:
    try:
      scan.builder.stepReplay(scan.sim)
    except SimGuardError, ReplayError:
      if replay.mismatchQuit:
        raise
      echo "replay scan stopped at tick ", scan.sim.tickCount
      scan.builder.playing = false
      break
    if replay.startTick < 0 and scan.sim.phase == Playing:
      replay.startTick = scan.sim.gameStartTick
    if scan.sim.scoreMicro != scan.lastScore:
      replay.leadSeries.add(
        @[scan.sim.tickCount, int(scan.sim.scoreMicro div 1000'i64)])
      scan.lastScore = scan.sim.scoreMicro
    var stepBeats = newJArray()
    scan.sim.stepEvents(scan.beatTracker, stepBeats)
    for event in stepBeats:
      if event["k"].getStr() in ScrubberBeatKinds:
        replay.beatEvents.add(event)
    for event in stepBeats:
      if event["k"].getStr() != "spawn":
        scan.beatTicks.add(scan.sim.tickCount)
        break
    if scan.sim.tickCount mod scan.interval == 0 or
        scan.sim.tickCount == scan.maxTick:
      replay.keyframes.add(scan.builder.saveReplayKeyframe(scan.sim))
    dec stepsLeft
  if scan.builder.playing and scan.sim.tickCount < scan.maxTick:
    return
  if replay.leadSeries.len == 0 or
      replay.leadSeries[^1][0] != scan.sim.tickCount:
    replay.leadSeries.add(
      @[scan.sim.tickCount, int(scan.lastScore div 1000'i64)])
  replay.lullSpans = buildLullSpans(
    scan.beatTicks, replay.replayStartTick(), scan.maxTick)
  replay.scan = nil
  replay.scanDone = true

proc replayScanTicksPerFrame*(sim: SimServer): int = 96

proc buildReplayKeyframes*(
  replay: var ReplayPlayer, initialSim: SimServer,
  interval = ReplayKeyframeTicks
) =
  ## The whole precompute walk, synchronously (tests and offline tools; the
  ## hosted viewer advances it a slice per frame instead).
  replay.initReplayScan(initialSim, interval)
  replay.advanceReplayScan(int.high)

proc isLullTick*(replay: ReplayPlayer, tick: int): bool =
  for span in replay.lullSpans:
    if tick < span[0]:
      return false
    if tick <= span[1]:
      return true
  false

proc replayStepBudget*(replay: ReplayPlayer, tick: int): int =
  ## How many ticks playback may advance this frame: the chosen speed, boosted
  ## inside a lull while skip-lulls is on. At 1/2x — outside the lull boost, so
  ## a skipped lull still flies — a tick is spent only every other frame.
  let speed = replay.replaySpeed()
  if replay.skipLulls and replay.isLullTick(tick):
    return min(speed * LullSpeedBoost, MaxLullTicksPerFrame)
  if replay.speedIndex == ReplayHalfSpeedIndex:
    return (if replay.halfPhase: 1 else: 0)
  speed

proc seekReplay*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(tick)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  while sim.tickCount < tick and replay.hashIndex < replay.data.hashes.len:
    replay.stepReplay(sim)

proc convergeSeek*(replay: var ReplayPlayer, sim: var SimServer): bool =
  ## Walks a pending seek up to SeekTicksPerFrame ticks closer to its target, so
  ## a scrub past the keyframed prefix costs one bounded slice per frame instead
  ## of stalling the viewer for seconds.
  if replay.pendingSeekTick < 0:
    return false
  var stepped = 0
  while sim.tickCount < replay.pendingSeekTick and
      replay.hashIndex < replay.data.hashes.len and
      stepped < SeekTicksPerFrame:
    replay.stepReplay(sim)
    inc stepped
  if sim.tickCount >= replay.pendingSeekTick or
      replay.hashIndex >= replay.data.hashes.len:
    replay.pendingSeekTick = -1
  stepped > 0

proc beginSeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  ## Land on the newest keyframe at or before `tick` (instant, which is what
  ## makes a scrubber click visible in the very next frame) and record the
  ## target; convergence happens a bounded slice at a time.
  let target = clamp(tick, replay.replayStartTick(), replay.replayMaxTick())
  if replay.keyframes.len > 0:
    replay.restoreReplayKeyframe(
      sim, replay.keyframes[replay.replayKeyframeIndex(target)])
  else:
    let logging = sim.gameEventLoggingEnabled
    sim = initSimServer(sim.config)
    sim.gameEventLoggingEnabled = logging
    replay.resetReplay()
  replay.pendingSeekTick = target

proc applyReplaySeek*(replay: var ReplayPlayer, sim: var SimServer, tick: int) =
  replay.playing = false
  replay.beginSeek(sim, tick)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## One playback speed command. '5' selects the replay-only 1/2x speed, which
  ## is also where '-' now floors.
  case command
  of '+', '=': speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_': speedIndex = max(speedIndex - 1, ReplayHalfSpeedIndex)
  of '5': speedIndex = ReplayHalfSpeedIndex
  of '1': speedIndex = 0
  of '2': speedIndex = 1
  of '3': speedIndex = 2
  of '4': speedIndex = 3
  of '8': speedIndex = 4
  of '6': speedIndex = 5
  else: discard

proc cancelEndHold*(replay: var ReplayPlayer) =
  replay.endHoldFrames = 0

proc applyReplayCommand*(
  replay: var ReplayPlayer, sim: var SimServer, command: char
) =
  case command
  of ' ': replay.playing = not replay.playing
  of 'p': replay.playing = true
  of 'P': replay.playing = false
  of '+', '=', '-', '_', '1', '2', '3', '4', '5', '8', '6':
    applySpeedCommand(replay.speedIndex, command)
  of ',', '<':
    replay.playing = false
    replay.pendingSeekTick = -1
    replay.seekReplay(sim, replay.replayStartTick())
  of 'b':
    replay.playing = false
    replay.beginSeek(sim, max(replay.replayStartTick(), sim.tickCount - 1))
  of 'e':
    replay.playing = false
    replay.beginSeek(sim, replay.replayMaxTick())
  of 'r': replay.looping = not replay.looping
  of 'f': replay.skipLulls = not replay.skipLulls
  of '.', '>':
    replay.playing = false
    replay.beginSeek(sim, sim.tickCount + ReplayFps * 5)
  else: discard

proc endHoldSecondsLeft*(replay: ReplayPlayer): int =
  if replay.endHoldFrames <= 0: 0
  else: (replay.endHoldFrames + ReplayFps - 1) div ReplayFps

proc advanceReplayPlayback*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  onStep: proc () {.closure.},
  onJump: proc () {.closure.}
) =
  ## One real-time playback frame. A LOOPING replay does NOT restart the moment
  ## playback stops: the final game-over frame holds for ReplayEndHoldSeconds so
  ## the end segment is readable instead of flashing for one frame.
  ##
  ## The 1/2x frame parity flips FIRST, so it advances on every real frame —
  ## including the frames a pending seek or an end-hold owns.
  replay.halfPhase = not replay.halfPhase
  if replay.pendingSeekTick >= 0:
    # A seek the viewer asked for OWNS the frame: converging it takes priority
    # over the background precompute walk and over playback.
    if replay.convergeSeek(sim):
      onJump()
    return
  replay.advanceReplayScan(sim.replayScanTicksPerFrame())
  if replay.playing and replay.endHoldFrames > 0:
    replay.endHoldFrames = 0
    replay.seekReplay(sim, replay.replayStartTick())
    onJump()
  if replay.playing:
    replay.endHoldFrames = 0
    var stepsTaken = 0
    while replay.playing and stepsTaken < replay.replayStepBudget(sim.tickCount):
      replay.stepReplay(sim)
      onStep()
      inc stepsTaken
    if replay.looping and not replay.playing:
      replay.endHoldFrames = ReplayEndHoldSeconds * ReplayFps
  elif replay.endHoldFrames > 0:
    dec replay.endHoldFrames
    if replay.endHoldFrames == 0 and replay.looping:
      replay.seekReplay(sim, replay.replayStartTick())
      replay.playing = true
      onJump()

proc playbackSpeed*(speedIndex: int): int =
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]
