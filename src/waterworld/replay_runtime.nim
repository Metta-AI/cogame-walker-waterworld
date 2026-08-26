## The deterministic replay host shared by the native replay server and the
## static WASM viewer, so both tell the same story at the end of a match.

import std/json

import sim_types, sim, replays, broadcast, global

type
  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer
    tracker*: BroadcastTracker

proc initReplayRuntime*(
  data: ReplayData,
  mismatchQuit: bool,
  gameEventLoggingEnabled = true
): InitializedReplay =
  ## Constructs and starts replay playback from the RECORDED config: the viewer
  ## re-simulates the episode from the seed and the command bytes, so nothing but
  ## the replay bytes is ever consulted.
  result.config = defaultGameConfig()
  result.config.update(data.configJson)
  result.sim = initSimServer(result.config)
  result.sim.gameEventLoggingEnabled = gameEventLoggingEnabled
  result.player = initReplayPlayer(data)
  result.player.mismatchQuit = mismatchQuit
  # The whole-match precompute walk (seek keyframes, the score series, the story
  # beats, the lull spans) STARTS here and advances a bounded slice per
  # presentation frame; only the short lobby walk to the first Playing tick —
  # the spectator start — is paid up front.
  result.player.initReplayScan(result.sim)
  while result.sim.phase != Playing and
      result.sim.tickCount < result.player.replayMaxTick() and
      result.player.hashIndex < result.player.data.hashes.len and
      not result.player.hashValidationFailed:
    result.player.stepReplay(result.sim)
  if result.player.startTick < 0 and result.sim.phase == Playing:
    result.player.startTick = result.sim.gameStartTick
  result.player.seekReplay(result.sim, result.player.replayStartTick())
  result.player.playing = true
  result.tracker = initBroadcastTracker()

proc advanceReplayFrame*(
  replay: var ReplayPlayer,
  sim: var SimServer,
  tracker: var BroadcastTracker,
  seekTicks: openArray[int],
  commands: openArray[char]
): JsonNode =
  ## Applies viewer controls and advances one public presentation frame.
  var didSeek = false
  for seekTick in seekTicks:
    replay.applyReplaySeek(sim, seekTick)
    didSeek = true
  for command in commands:
    let tickBeforeCommand = sim.tickCount
    replay.applyReplayCommand(sim, command)
    if sim.tickCount != tickBeforeCommand:
      didSeek = true
  if didSeek:
    tracker.resync(sim)
    replay.cancelEndHold()

  let events = newJArray()
  let
    simPtr = sim.addr
    trackerPtr = tracker.addr
  replay.advanceReplayPlayback(
    sim,
    proc () = simPtr[].stepEvents(trackerPtr[], events),
    proc () = trackerPtr[].resync(simPtr[])
  )
  result = events

proc buildReplayViewerPacket*(
  sim: var SimServer,
  replay: ReplayPlayer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode
): seq[uint8] =
  ## The shared replay board + chrome packet for one viewer.
  result = sim.buildSpriteProtocolUpdates(
    state,
    nextState,
    sim.tickCount,
    replay.playing,
    replay.replaySpeed(),
    replay.replayMaxTick(),
    replay.looping,
    true,
    replay.hashMismatchTick
  )
  if result.len == 0:
    return
  # The lead chrome (score series, beat markers, lull spans) waits for the
  # background precompute walk: it ships ONCE per viewer, so sending before the
  # walk finishes would freeze a half-scanned timeline into the HUD. The client
  # keys on presence, not frame number — late is fine.
  let sendLead = not state.momentumSent and replay.scanComplete()
  result.addChromeSprite(sim.buildStateJson(
    events,
    replay.playing,
    replay.replaySpeed(),
    replay.replayMaxTick(),
    replay.looping,
    true,
    replay.hashMismatchTick,
    if sendLead: replay.leadSeries else: @[],
    replay.replayStartTick(),
    replay.endHoldSecondsLeft(),
    replay.skipLulls,
    replay.skipLulls and replay.playing and replay.isLullTick(sim.tickCount),
    if sendLead: replay.lullSpans else: @[],
    if sendLead: replay.beatEvents else: nil
  ))
  if sendLead:
    nextState.momentumSent = true
