## The replay broadcast state channel: the JSON chrome frame the designed
## broadcast client reads, plus the state-delta -> beat-event derivation the
## scrubber, feed and endcard are built from.
##
## Events are derived ONE SIM STEP AT A TIME (`stepEvents`) and accumulated by
## the caller across a playback frame, so attribution stays exact even at 16x —
## never collapsing a whole span into one ambiguous marker. Because they are
## derived from state deltas they cost no replay bytes and read identically live
## and in replay.
##
## Keys above the `ww` fold are the STARTER's (`t, mt, ph, lob, pl, sp, mx, st,
## lp, sk, ff, en, mm, bs, pov, teams, roster, events, lead, beats, lulls, over,
## hold`) and are consumed by the byte-identical `client/chrome_common.js`, so
## its plate rendering, clock, transport, beat markers, lull shading, momentum
## curve, spoilers switch and endcard run unmodified against waterworld values.
## Everything waterworld-specific lives under `ww` and `intents`.

import std/[json, math, strutils]

import sim_types, sim, roster

const
  ScrubberBeatKinds* = ["capture", "poison", "target_met", "gameover"]
    ## The kinds that become clickable scrubber markers. `nibble`, `spawn`,
    ## `near_miss` and `stun_end` are deliberately NOT beats: they fire dozens
    ## of times and would bury the scrubber.

type
  BroadcastTracker* = object
    ## Per-viewer snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    captures: int32
    nibbles: int32
    poisonHits: int32
    scoreMicro: int64
    stun: array[SkimmerCount, int32]
    foodState: array[FoodCount, ParticleState]
    poisonState: array[PoisonCount, ParticleState]
    turnIndex: int
    fxSeen: int

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby
  result.turnIndex = -1

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  tracker.captures = sim.captures
  tracker.nibbles = sim.nibbles
  tracker.poisonHits = sim.poisonHits
  tracker.scoreMicro = sim.scoreMicro
  for i in 0 ..< SkimmerCount:
    tracker.stun[i] = sim.skimmers[i].stun
  for f in 0 ..< FoodCount:
    tracker.foodState[f] = sim.food[f].state
  for q in 0 ..< PoisonCount:
    tracker.poisonState[q] = sim.poison[q].state
  tracker.turnIndex = sim.turnIndex
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots without emitting events, after a seek/loop/skip. The next
  ## `stepEvents` diffs against this frame, so no phantom beats fire.
  tracker.snapshot(sim)

proc stepEvents*(sim: SimServer, tracker: var BroadcastTracker, events: JsonNode) =
  ## Appends the beat events produced by the transition from the tracker's last
  ## snapshot to the current sim tick, then advances the tracker.
  if not tracker.initialized:
    tracker.snapshot(sim)
    return
  let tick = sim.tickCount

  if sim.phase != tracker.prevPhase:
    events.add(%*{"t": tick, "k": "phase", "phase": ($sim.phase).toLowerAscii})
    if sim.phase == GameOver:
      events.add(%*{
        "t": tick, "k": "gameover",
        "winner": (if sim.podWon(): "pod" else: ""),
        "draw": false,
        "tl": sim.endRule == EndRuleFullTime,
        "endRule": sim.endRule,
        "reason": sim.endReason,
        "captures": int(sim.captures),
        "score": sim.scoreDouble()
      })

  # The FX ring is the sim's own record of what just happened, in tick order:
  # every capture, nibble, poison hit and near miss the step produced. Reading
  # it here is what keeps the feed's story and the sim's rules the same story.
  for fx in sim.fx:
    if fx.tick <= tracker.prevTick:
      continue
    case fx.kind
    of fxCapture:
      var holders = newJArray()
      for i in 0 ..< SkimmerCount:
        if (fx.holdersMask and (1'u8 shl uint8(i))) != 0'u8:
          holders.add(%i)
      events.add(%*{
        "t": tick, "k": "capture", "skimmers": holders,
        "score": sim.scoreDouble(), "captures": int(sim.captures)})
    of fxNibble:
      events.add(%*{"t": tick, "k": "nibble", "skimmer": int(fx.skimmer)})
    of fxPoison:
      events.add(%*{"t": tick, "k": "poison", "skimmer": int(fx.skimmer)})
    of fxNearMiss:
      events.add(%*{"t": tick, "k": "near_miss"})

  if sim.captures >= int32(sim.config.captureTarget) and
      tracker.captures < int32(sim.config.captureTarget):
    events.add(%*{"t": tick, "k": "target_met", "captures": int(sim.captures)})

  for f in 0 ..< sim.config.foodCount:
    if sim.food[f].state == psLive and tracker.foodState[f] == psRespawning:
      events.add(%*{"t": tick, "k": "spawn", "kind": "food", "id": foodId(f)})
  for q in 0 ..< sim.config.poisonCount:
    if sim.poison[q].state == psLive and tracker.poisonState[q] == psRespawning:
      events.add(%*{"t": tick, "k": "spawn", "kind": "poison", "id": poisonId(q)})

  for i in 0 ..< SkimmerCount:
    if sim.skimmers[i].stun == 0 and tracker.stun[i] > 0:
      events.add(%*{"t": tick, "k": "stun_end", "skimmer": i})

  if sim.turnIndex != tracker.turnIndex and sim.turnIndex >= 0:
    events.add(%*{
      "t": tick, "k": "turn_end", "turn": sim.turnIndex,
      "turns": sim.turnsPerEpisode()})

  tracker.snapshot(sim)

# ---------------------------------------------------------------------------
#  The state frame
# ---------------------------------------------------------------------------

proc rosterJson(sim: SimServer): JsonNode =
  ## SPECTATOR SIDE, and the only place a real policy name reaches a client.
  result = newJArray()
  for seat in 0 ..< SkimmerCount:
    let
      skimmer = sim.skimmerForSeat(seat)
      name =
        if seat < sim.seatNames.len and sim.seatNames[seat].len > 0:
          sim.seatNames[seat]
        else:
          "Baseline (" & $(seat + 1) & ")"
    result.add(%*{
      "s": seat,
      "team": "pod",
      "name": name,
      "pol": name,
      "alias": skimmerAlias(skimmer),
      "skimmer": skimmer,
      "kind": (if seat < sim.seatPolicyKind.len: sim.seatPolicyKind[seat]
               else: "scripted"),
      "assists": int(sim.assists[seat]),
      "nibbles": int(sim.nibblesBySeat[seat]),
      "poison": int(sim.poisonBySeat[seat]),
      "thrustPct": sim.thrustMeanPct(seat),
      "llm": int(sim.llmTurns[seat]),
      "fb": int(sim.fallbackTurns[seat]),
      # `lives` and `alive` exist so chrome_common's inherited team-meter path
      # has something honest to read on a game with no lives: the pod is always
      # four skimmers, all of them in the water.
      "lives": 0,
      "alive": true
    })

proc wwJson(sim: SimServer): JsonNode =
  ## Everything waterworld-specific: the tank, the four skimmers with their
  ## sixteen rays, the particles, the reward decomposition and the bubbles. The
  ## spectator board is PERFECT INFORMATION; the per-seat stream is
  ## sensor-filtered, and that filtering lives in global.nim.
  var skimmers = newJArray()
  for i in 0 ..< SkimmerCount:
    let s = sim.skimmers[i]
    let decoded = decodeThrust(s.cmd)
    let frame = sim.frameFor(i)
    var rays = newJArray()
    for n in 0 ..< SensorCount:
      rays.add(%*{
        "k": $frame.rays[n].kind,
        "d": round(float(frame.rays[n].distUm) / 1_000_000.0, 2)})
    skimmers.add(%*{
      "i": i,
      "p": [round(float(s.x) / 1_000_000.0, 2),
            round(float(int64(ArenaH) - int64(s.y)) / 1_000_000.0, 2)],
      "v": [round(float(s.vx) * float(TargetFps) / 1_000_000.0, 2),
            round(float(-s.vy) * float(TargetFps) / 1_000_000.0, 2)],
      "dir": int(decoded.dir),
      "level": int(decoded.level),
      "stun": int(s.stun),
      "rays": rays})
  var food = newJArray()
  for f in 0 ..< sim.config.foodCount:
    let p = sim.food[f]
    let v = p.particleVelocity()
    var held = newJArray()
    for i in 0 ..< SkimmerCount:
      if p.state == psLive and withinUm(sim.skimmers[i].x, sim.skimmers[i].y,
          p.x, p.y, SkimmerRadius + FoodRadius):
        held.add(%i)
    food.add(%*{
      "id": foodId(f),
      "p": [round(float(p.x) / 1_000_000.0, 2),
            round(float(int64(ArenaH) - int64(p.y)) / 1_000_000.0, 2)],
      "v": [round(float(v.vx) * float(TargetFps) / 1_000_000.0, 2),
            round(float(-v.vy) * float(TargetFps) / 1_000_000.0, 2)],
      "state": (if p.state == psLive: "live" else: "gone"),
      "held": held})
  var poison = newJArray()
  for q in 0 ..< sim.config.poisonCount:
    let p = sim.poison[q]
    poison.add(%*{
      "id": poisonId(q),
      "p": [round(float(p.x) / 1_000_000.0, 2),
            round(float(int64(ArenaH) - int64(p.y)) / 1_000_000.0, 2)],
      "state": (if p.state == psLive: "live" else: "gone")})
  var bubbles = newJArray()
  for bubble in sim.bubbles:
    if bubble.untilTick > sim.tickCount:
      bubbles.add(%*{
        "skimmer": int(bubble.skimmer), "say": bubble.text,
        "until": bubble.untilTick})
  %*{
    "tank": {
      "w": round(float(ArenaW) / 1_000_000.0, 2),
      "h": round(float(ArenaH) / 1_000_000.0, 2),
      "rock": {
        "c": [round(float(RockCentreX) / 1_000_000.0, 2),
              round(float(int64(ArenaH) - int64(RockCentreY)) / 1_000_000.0, 2)],
        "r": round(float(RockRadius) / 1_000_000.0, 2)},
      "sensorRange": round(float(sim.config.sensorRangeUm) / 1_000_000.0, 2),
      "sensors": SensorCount,
      "coop": sim.config.coopNeeded},
    "skimmers": skimmers,
    "food": food,
    "poison": poison,
    "reward": {
      "captures": round(float(CaptureMicro * int64(sim.captures)) / 1_000_000.0, 2),
      "nibbles": round(float(NibbleMicro * int64(sim.nibbles)) / 1_000_000.0, 2),
      "poison": round(float(PoisonMicro * int64(sim.poisonHits)) / 1_000_000.0, 2),
      "thrust": -sim.thrustCostDouble(),
      "score": sim.scoreDouble()},
    "bubbles": bubbles
  }

proc boardRenderScaleFor*(width, height: int): int =
  ## The per-board supersample factor. Kept from the starter verbatim in
  ## SEMANTICS: an oversize board renders at 1x rather than blow the wasm32
  ## viewer's address space. The fixed tank is 1200x800 = 960 000 logical
  ## pixels, so waterworld always renders at RenderScale.
  if width * height > MaxSupersampledMapPixels: 1 else: RenderScale

proc predictedViewerRenderBytes*(width, height: int): int64 =
  ## Load-time capacity preflight for the browser viewer: the render buffers a
  ## board of this size needs. The tank predicts ~84 MB against a 1.6 GB budget.
  let scale = int64(boardRenderScaleFor(width, height))
  int64(width) * int64(height) * scale * scale * 4'i64 * 11'i64

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  # `speed` is the speed the chrome SHOWS (`sp`), which is fractional at the
  # replay-only 1/2x — not the engine's integer PlaybackSpeeds value.
  speed: float,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  leadSeries: seq[seq[int]] = @[],
  startTick = 0,
  endHoldSeconds = 0,
  skipLulls = false,
  fastForwarding = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE (score, captures,
  ## roster, verdict) is always present, so even a frame reached by a seek
  ## hydrates the scorebug and endcard with no events.
  ##
  ## There is exactly ONE `teams` key (`pod`) — this is a cooperative game with
  ## one side — so chrome_common's plate loop renders one team plate and
  ## `#plates-r` is free for the objective plate.
  var teams = newJObject()
  teams["pod"] = %*{
    "lives": 0,
    "score": sim.scoreDouble(),
    "captures": int(sim.captures),
    "target": sim.config.captureTarget,
    "nibbles": int(sim.nibbles),
    "poison": int(sim.poisonHits),
    "thrust": sim.thrustCostDouble(),
    "policies": (block:
      var pols = newJArray()
      for seat in 0 ..< SkimmerCount:
        let name =
          if seat < sim.seatNames.len and sim.seatNames[seat].len > 0:
            sim.seatNames[seat]
          else:
            "Baseline (" & $(seat + 1) & ")"
        pols.add(%name)
      pols)
  }

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": boardRenderScaleFor(MapWidth, MapHeight),
    "pov": -1,
    "teams": teams,
    "roster": sim.rosterJson(),
    "events": (if events.isNil: newJArray() else: events),
    "turn": sim.turnIndex,
    "turns": sim.turnsPerEpisode(),
    "turnTicks": sim.config.turnTicks,
    "ww": sim.wwJson()
  }

  # The intent lines. This is where a spectator SEES the LLM playing: the
  # `note` and `say` each seat issued, live and in replay from one source.
  if sim.feedIntents.len > 0:
    var records = newJArray()
    for record in sim.feedIntents:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["intents"] = records

  if leadSeries.len > 0:
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    var leadTeams = newJArray()
    leadTeams.add(%"pod")
    state["lead"] = %*{"teams": leadTeams, "pts": pts}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  if sim.phase == GameOver:
    var overTeams = newJObject()
    overTeams["pod"] = %*{"captures": int(sim.captures), "lives": 0}
    state["over"] = %*{
      "winner": (if sim.podWon(): "pod" else: ""),
      "draw": false,
      "timeLimit": sim.endRule == EndRuleFullTime,
      "endRule": sim.endRule,
      "reason": sim.endReason,
      "score": sim.scoreDouble(),
      "captures": int(sim.captures),
      "target": sim.config.captureTarget,
      "nibbles": int(sim.nibbles),
      "poisonHits": int(sim.poisonHits),
      "thrust": sim.thrustCostDouble(),
      "ticks": sim.gameTicksElapsed(),
      "teams": overTeams
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state
