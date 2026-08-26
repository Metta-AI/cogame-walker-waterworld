## The mummy HTTP/websocket server and the episode loop.
##
## Inherited from `coworld-ctf/src/ctf/server.nim` with the five named edits the
## design note lists:
##
##   1. INPUT SOURCE. Player sockets contribute NO input: every tick the loop
##      calls `control.thrustCommand` for all four skimmers and passes the
##      command-byte array into `sim.step`. Any input mask arriving on a player
##      socket is discarded.
##   2. REPLAY INPUT WRITE. ctf's press/release wrapper is gone (see
##      replays.nim edit 2); the loop calls `writeInputMaskChange` directly with
##      the value byte and the codec's change-only guard does the rest.
##   3. TURN BOUNDARY. Immediately before stepping a tick where
##      `gameTicksElapsed mod turnTicks == 0`, the loop runs `decide.turn`,
##      which enforces the inter-batch floor, issues the ONE parallel
##      four-request batch, applies the two deadlines, installs the intents and
##      writes the intent/fallback records — all inside a monotonic
##      `turnBudgetMs` bound.
##   4. WALL-CLOCK STOP. A `wallClockBudgetSeconds` check at the top of every
##      loop iteration forces GameOver with reason `deadline`, rule
##      `wall_clock`, scores the state as it stands and writes a complete replay
##      up to that tick.
##   5. SHUTDOWN GRACE. `/healthz` and `/global` keep answering for a bounded
##      ~20 s after the artifacts are written, then the process exits: the
##      episode runner pings `/global` with a 2 s deadline AFTER the player pods
##      start, and a short episode can already be gone.

import std/[json, locks, monotimes, nativesockets, os, strutils, tables, times]

import bitworld/client as bitworldClient
import bitworld/runtime
import bitworld/spriteprotocol
import mummy

import sim_types, sim, roster, intents, control, baselines, decide, llm,
  replays, replay_runtime, broadcast, global, events, wire_constants

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  WebSocketAppState = object
    lock: Lock
    replayLoaded: bool
    chatMessages: Table[WebSocket, string]
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    playerViewers: Table[WebSocket, PlayerViewerState]
    globalViewers: Table[WebSocket, GlobalViewerState]
    closedSockets: seq[WebSocket]
    config: GameConfig

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

const
  HealthPath = "/healthz"
  ReplayDataPath = "/replay-data"
  BroadcastFontPath = "/client/font.ttf"
  MaxWsFrameBytes* = 900_000
    ## Hosted replay closes any WS frame larger than 1 MiB (sends 1009); every
    ## outbound sprite packet is chunked under a margin below that.
  ShutdownGraceSeconds = 20

  EmbeddedBroadcastReplayHtml = staticRead("../../client/replay_broadcast.html")
    .replace("<!-- CHROME_COMMON -->",
      "<script>" & staticRead("../../client/chrome_common.js") & "</script>")
    .replace("<!-- BROADCAST_CORE -->",
      "<script>" & staticRead("../../client/broadcast_core.js") & "</script>")
    .spliceWireConstants()
  BroadcastFont = staticRead("../../data/font.ttf")
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/green_1.webp",
      staticRead("../../client/art/lockerroom/green_1.webp")),
    ("/client/art/lockerroom/green_2.webp",
      staticRead("../../client/art/lockerroom/green_2.webp")),
    ("/client/art/lockerroom/green_3.webp",
      staticRead("../../client/art/lockerroom/green_3.webp")),
    ("/client/art/lockerroom/green_5.webp",
      staticRead("../../client/art/lockerroom/green_5.webp")),
    ("/client/art/lockerroom/green_6.webp",
      staticRead("../../client/art/lockerroom/green_6.webp")),
    ("/client/art/lockerroom/blue_1.webp",
      staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("/client/art/lockerroom/blue_2.webp",
      staticRead("../../client/art/lockerroom/blue_2.webp")),
    ("/client/art/lockerroom/blue_3.webp",
      staticRead("../../client/art/lockerroom/blue_3.webp")),
    ("/client/art/lockerroom/blue_5.webp",
      staticRead("../../client/art/lockerroom/blue_5.webp")),
    ("/client/art/lockerroom/blue_6.webp",
      staticRead("../../client/art/lockerroom/blue_6.webp")),
    ("/client/art/lockerroom/yellow_1.webp",
      staticRead("../../client/art/lockerroom/yellow_1.webp")),
    ("/client/art/lockerroom/yellow_2.webp",
      staticRead("../../client/art/lockerroom/yellow_2.webp")),
    ("/client/art/lockerroom/yellow_3.webp",
      staticRead("../../client/art/lockerroom/yellow_3.webp")),
    ("/client/art/lockerroom/yellow_5.webp",
      staticRead("../../client/art/lockerroom/yellow_5.webp")),
    ("/client/art/lockerroom/yellow_6.webp",
      staticRead("../../client/art/lockerroom/yellow_6.webp")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/red_2.webp",
      staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/client/art/lockerroom/red_3.webp",
      staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/client/art/lockerroom/red_5.webp",
      staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/client/art/lockerroom/red_6.webp",
      staticRead("../../client/art/lockerroom/red_6.webp"))
  ]

var appState: WebSocketAppState
var servedReplayBytes: string

proc initAppState() =
  initLock(appState.lock)
  appState.chatMessages = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.closedSockets = @[]
  appState.config = defaultGameConfig()

proc markSocketClosed(websocket: WebSocket): bool =
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc isWebSocketUpgrade(request: Request): bool =
  request.headers["Sec-WebSocket-Key"].len > 0

proc hasPlayerCredentialParams(request: Request): bool =
  request.queryParams.getOrDefault("name", "").strip().len > 0 or
    request.queryParams.getOrDefault("slot", "").strip().len > 0 or
    request.queryParams.getOrDefault("token", "").strip().len > 0

proc respondForbiddenWebSocket(request: Request, reason: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc playerSlot(request: Request): int =
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerToken(request: Request): string =
  request.queryParams.getOrDefault("token", "").strip()

proc cleanPlayerName(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc playerIdentity(request: Request, slot: int, token: string): string =
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
  if result.len == 0:
    result = "Baseline (" & $(max(0, slot) + 1) & ")"

proc parseRegistration(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"shoal"|null,"policy":"…"}
  ## Anything that is not that object is not a registration, and a seat's chat
  ## is NEVER written to the replay chat stream: the prompt is a secret. What
  ## the replay gets is a redacted `register` record.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc isPlayerReadyPacket(message: string): bool =
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc httpHandler(request: Request) =
  ## The `/client/` routes are registered BEFORE any catch-all asset route and
  ## neither of them opens the player socket: the certifier probes
  ## `/healthz`, `GET /client/player?slot&token`, a bad-token player websocket
  ## and `GET /client/global` BEFORE starting the player pods.
  if request.path == HealthPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      identity = request.playerIdentity(slot, token)
    var allowed = true
    {.gcsafe.}:
      withLock appState.lock:
        allowed = appState.config.playerJoinAllowed(identity, slot, token)
    if not allowed:
      request.respondForbiddenWebSocket(
        "Player credentials do not match configured slot " & $slot & ".")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.playerViewers[websocket] = initPlayerViewerState()
        appState.playerAddresses[websocket] = identity
        appState.playerSlots[websocket] = slot
        appState.playerTokens[websocket] = token
        appState.playerIndices[websocket] = 0x7fffffff
        appState.playerReady[websocket] = false
    echo "player connected: ", identity
  elif (request.path == GlobalWebSocketPath or
      request.path == ReplayWebSocketPath) and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenWebSocket(
        "Viewer websocket cannot include player name, slot, or token.")
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        appState.globalViewers[websocket] = initGlobalViewerState()
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      bitworldClient.GlobalClientRoute,
      bitworldClient.CoworldGlobalClientRoute,
      bitworldClient.PlayerClientRoute,
      bitworldClient.CoworldPlayerClientRoute
    ] and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, EmbeddedBroadcastReplayHtml)
  elif request.path == ReplayDataPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    {.gcsafe.}:
      request.respond(200, headers, servedReplayBytes)
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "font/ttf"
    headers["Cache-Control"] = "public, max-age=3600"
    request.respond(200, headers, BroadcastFont)
  elif request.httpMethod == "GET" and (block:
      var hit = false
      for (path, _) in LockerRoomAssets:
        if request.path == path:
          hit = true
          break
      hit):
    var headers: HttpHeaders
    headers["Content-Type"] =
      if request.path.endsWith(".webp"): "image/webp" else: "image/jpeg"
    headers["Cache-Control"] = "public, max-age=3600"
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        request.respond(200, headers, art)
        break
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "walker-waterworld server")

proc websocketHandler(
  websocket: WebSocket, event: WebSocketEvent, message: Message
) =
  case event
  of OpenEvent:
    discard
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      {.gcsafe.}:
        withLock appState.lock:
          if message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data)
          elif websocket in appState.playerViewers:
            ## A seat sends NO inputs: every command byte comes from the
            ## control layer. Only a registration chat is read; any input mask
            ## is discarded.
            let text = readSpriteInputText(message.data)
            if text.len > 0:
              appState.chatMessages[websocket] = text
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        if markSocketClosed(websocket) and websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc disconnectWebSocket(websocket: WebSocket) =
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc allPlayersReady(
  sockets: openArray[WebSocket], playerIndices: openArray[int], seats: int
): bool =
  var active = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= playerIndices.len or playerIndices[i] < 0 or
            playerIndices[i] >= seats:
          continue
        inc active
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
  active > 0

proc runFrameLimiter(
  previousTick: var MonoTime, fastMode: bool,
  sockets: openArray[WebSocket], playerIndices: openArray[int], seats: int
) =
  ## `fastMode` advances the tick as soon as every player container has
  ## acknowledged the frame, so sim time is not charged against the wall clock —
  ## the decision turns are the pacing.
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      break
    if fastMode and sockets.allPlayersReady(playerIndices, seats):
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
  previousTick = getMonoTime()

proc declarePlayerFailure(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for, so a lobby no-show is charged to the seat that caused it instead
  ## of poisoning the whole episode unattributed. Best effort: outside the
  ## platform (env unset) this is a no-op.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc runServerLoop*(
  host = "0.0.0.0",
  port = 8080,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadReplay(loadReplayPath)
      except CatchableError as e:
        ## A bad or version-mismatched replay must not kill the server: the
        ## viewer would see a dead socket with no explanation. Serve the empty
        ## lobby and say why.
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        ReplayData()
    else:
      ReplayData()
  var initializedReplay =
    if replayLoaded: initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else: InitializedReplay()
  var config =
    if replayLoaded: initializedReplay.config else: initialConfig
  var
    sim =
      if replayLoaded: move(initializedReplay.sim) else: initSimServer(config)
    replayPlayer =
      if replayLoaded: move(initializedReplay.player) else: ReplayPlayer()
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()
  if replayLoaded:
    servedReplayBytes = readFile(loadReplayPath)
  var replayWriter = openReplayWriter(saveReplayPath, sim.replayConfigJson())
  defer: replayWriter.closeReplayWriter()
  appState.replayLoaded = replayLoaded
  appState.config = config

  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0: ""
    elif uri.startsWith("file://"): uri[7 .. ^1]
    else:
      raise newException(ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri)
  sim.collectEvents = eventsPath.len > 0
  var collectedEvents: seq[SimEvent] = @[]

  block:
    # Bake every board sprite BEFORE the listener opens: a viewer's
    # first-message clock starts at its successful connect and the certifier
    # allows only seconds, so nothing may be accepted until every frame the
    # loop will ever build can be assembled instantly.
    let warmStart = getMonoTime()
    warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 4)
  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(serverThread, serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port))
  httpServer.waitUntilReady()

  var
    engine = if replayLoaded: DecisionEngine() else: initDecisionEngine(sim)
    lastTick = getMonoTime()
    episodeStart = getMonoTime()
    deadlineHit = false
    lastTurnIndex = -1
    quitAfterFrame = false
    noShowReported = false
    lastCmds = newSeq[uint8](SkimmerCount)

  while true:
    var
      sockets: seq[WebSocket] = @[]
      socketsToClose: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]

    # --- EDIT 4: the engine's own hard stop, before anything else -----------
    if not replayLoaded and not deadlineHit and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      deadlineHit = true
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode from the state at this tick"
      sim.endEpisode(ReasonDeadline, EndRuleWallClock)
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        for websocket in appState.closedSockets:
          ## A seat that drops does NOT remove its skimmer: the pod is fixed for
          ## the whole episode, its intent source degrades to `shoal`, and the
          ## seat revives on reconnect.
          appState.playerViewers.del(websocket)
          appState.playerIndices.del(websocket)
          appState.playerAddresses.del(websocket)
          appState.playerSlots.del(websocket)
          appState.playerTokens.del(websocket)
          appState.playerReady.del(websocket)
          appState.chatMessages.del(websocket)
          appState.globalViewers.del(websocket)
        appState.closedSockets.setLen(0)

        if not replayLoaded:
          # Joins are strictly slot-sequential: a candidate is admitted only
          # when its resolved slot is exactly the next open seat.
          var progressed = true
          while progressed:
            progressed = false
            for websocket, index in appState.playerIndices.pairs:
              if index != 0x7fffffff:
                continue
              let
                address = appState.playerAddresses.getOrDefault(websocket, "?")
                slot = appState.playerSlots.getOrDefault(websocket, -1)
                token = appState.playerTokens.getOrDefault(websocket, "")
                resolved = sim.resolvePlayerSlot(address, token, slot)
              if resolved != sim.nextPlayerSlot():
                continue
              try:
                appState.playerIndices[websocket] =
                  sim.addPlayer(address, resolved, token)
                while replayWriter.lastMasks.len < SkimmerCount:
                  replayWriter.lastMasks.add(0'u8)
                replayWriter.writeJoin(tickTime(sim.tickCount), resolved,
                  address, resolved, token)
                progressed = true
              except WaterworldError:
                appState.playerIndices[websocket] = -1
                socketsToClose.add(websocket)
              break

          if sim.lobbyJoinTimedOut() and not noShowReported:
            ## A seat that never connects does NOT end the episode: report the
            ## no-show (lowest missing slot only), then start anyway. Its
            ## skimmer is driven by the `shoal` baseline for the whole run and
            ## three skimmers can still capture, so the episode stays
            ## meaningful.
            noShowReported = true
            let stuckSlot = sim.nextPlayerSlot()
            declarePlayerFailure(stuckSlot,
              "player slot " & $stuckSlot & " never joined the lobby within " &
                $config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
                $(config.lobbyJoinTimeoutTicks div TargetFps) &
                "s); its skimmer plays the shoal baseline")
            sim.config.minPlayers = max(1, sim.players.len)
            config.minPlayers = sim.config.minPlayers

          # Registrations. A seat's chat is its REGISTRATION, consumed here and
          # never written to the replay chat stream. Held (not dropped) while
          # its player index does not exist yet: joins are slot-sequential and
          # the lobby sends frames to a socket before it has been admitted, so
          # a champion's first registration can legitimately arrive early.
          var held: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let seat = appState.playerIndices.getOrDefault(websocket, -1)
            let registration = parseRegistration(chatText)
            if not registration.ok:
              continue
            if seat < 0 or seat >= SkimmerCount:
              held.add((websocket, chatText))
              continue
            var policy = engine.seats[seat]
            let first = not policy.registered
            policy.registered = true
            policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
            policy.isLlm = policy.prompt.len > 0
            policy.baseline = parseBaseline(registration.scripted)
            policy.label =
              if registration.policy.len > 0: registration.policy
              elif policy.isLlm: "prompt"
              else: $policy.baseline
            engine.seats[seat] = policy
            if seat < sim.seatPolicyKind.len:
              sim.seatPolicyKind[seat] = engine.policyKind(seat)
            if first:
              replayWriter.writeChat(tickTime(sim.tickCount), seat,
                registerRecord(seat, sim.skimmerForSeat(seat), policy.label,
                  engine.policyKind(seat), $policy.baseline))
              echo "seat ", seat, " registered: kind=",
                engine.policyKind(seat), " baseline=", $policy.baseline
          appState.chatMessages.clear()
          for (websocket, chatText) in held:
            appState.chatMessages[websocket] = chatText

        for websocket, index in appState.playerIndices.pairs:
          sockets.add(websocket)
          playerIndices.add(index)
          playerViewerStates.add(appState.playerViewers.getOrDefault(
            websocket, initPlayerViewerState()))
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1

    for websocket in socketsToClose:
      websocket.disconnectWebSocket()

    var frameEvents = newJArray()
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(
        sim, broadcastTracker, replaySeekTicks, replayCommands)
    elif not quitAfterFrame:
      # --- EDIT 3: the decision turn, then EDIT 1/2: the compiled bytes -----
      # This is the determinism boundary. The control layer and the LLM live on
      # THIS side of it, and only the bytes below are recorded, so the wasm
      # viewer re-derives the whole episode from them without ever running
      # either.
      if sim.phase == Playing:
        let turnTicks = max(1, config.turnTicks)
        let turnIndex = sim.gameTicksElapsed() div turnTicks
        var frames: seq[SensorFrame] = @[]
        for seat in 0 ..< SkimmerCount:
          frames.add(sim.frameFor(sim.skimmerForSeat(seat)))
        if sim.gameTicksElapsed() mod turnTicks == 0 and turnIndex != lastTurnIndex:
          lastTurnIndex = turnIndex
          let elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
          let records = engine.turn(sim, frames, turnIndex, elapsedSeconds)
          for record in records:
            replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
          for seat in 0 ..< sim.seatCount():
            if not engine.haveIntent[seat]:
              continue
            let record = engine.intents[seat].boundedIntentRecord(
              turnIndex, seat, sim.skimmerForSeat(seat))
            replayWriter.writeChat(tickTime(sim.tickCount), seat, record)
            sim.pushFeedIntent(record)
            sim.emitEvent(Intent, source = seat,
              amount = turnIndex, content = engine.intents[seat].note)
        # One command byte per SKIMMER, in index order, every tick.
        var cmds = newSeq[uint8](SkimmerCount)
        for i in 0 ..< SkimmerCount:
          let seat = sim.seatForSkimmer(i)
          let frame = if seat >= 0 and seat < frames.len: frames[seat]
                      else: sim.frameFor(i)
          let intent = engine.intentFor(sim, seat, frame, turnIndex)
          cmds[i] = engine.ctl.thrustCommand(sim, i, frame, intent)
        # The byte is recorded BY SKIMMER INDEX, not by seat: that is the index
        # `sim.step` consumes, so playback needs no translation and cannot get
        # the mapping backwards. (The join stream is by SEAT; the two index
        # spaces coincide in size and `perm` is in the config JSON.)
        for i in 0 ..< SkimmerCount:
          replayWriter.writeInputMaskChange(
            tickTime(sim.tickCount), i, cmds[i])
        lastCmds = cmds
      else:
        for seat in 0 ..< SkimmerCount:
          replayWriter.writeInputMaskChange(tickTime(sim.tickCount), seat, 0'u8)
        lastCmds = newSeq[uint8](SkimmerCount)

      var faultRule = ""
      try:
        sim.step(lastCmds)
      except SimGuardError as guard:
        echo "waterworld: SIM GUARD tripped at tick ", sim.tickCount, ": ",
          guard.msg
        faultRule = EndRuleSimFault
      except CatchableError as error:
        echo "waterworld: HOST ERROR at tick ", sim.tickCount, ": ", error.msg
        faultRule = EndRuleHostError
      if faultRule.len > 0:
        sim.endEpisode(ReasonFault, faultRule)
        quitAfterFrame = true
      replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
      if sim.collectEvents:
        for event in sim.events:
          collectedEvents.add(event)
        sim.events.setLen(0)
      sim.stepEvents(broadcastTracker, frameEvents)
      if sim.phase == GameOver and sim.gameOverTimer <= 0:
        quitAfterFrame = true

    # --- publish the frame -------------------------------------------------
    for i in 0 ..< sockets.len:
      if playerIndices[i] < 0 or playerIndices[i] >= SkimmerCount:
        continue
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i], playerViewerStates[i], nextState)
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
            appState.playerReady[sockets[i]] = false
      try:
        if framePacket.len == 0:
          ## One binary message per tick is the frame contract — clients count
          ## messages to advance. An empty frame still ships.
          sockets[i].send("", BinaryMessage)
        for chunk in chunkSpritePacket(framePacket, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(sockets[i])

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(
            replayPlayer, globalStates[i], nextState, frameEvents)
        else:
          var live = sim.buildSpriteProtocolUpdates(
            globalStates[i], nextState, sim.tickCount, true, 1,
            config.maxTicks, false, false, -1)
          live.addChromeSprite(sim.buildStateJson(
            frameEvents, true, 1, config.maxTicks, false, false, -1))
          live
      if packet.len == 0:
        continue
      try:
        for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              # The websocket thread keeps writing viewer INPUT into this entry
              # while the frame was being built from an earlier snapshot, so
              # merge rather than overwrite: a seek or command landing in
              # between must not be silently lost.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              appState.globalViewers[globalViewers[i]] = merged
      except CatchableError:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if quitAfterFrame:
      ## The `result` control record: the whole results document, written once
      ## into the replay chat stream at episode end, so the replay is
      ## SELF-SUFFICIENT — the outcome would otherwise live only at
      ## COGAME_RESULTS_URI, which a spectator holding the bytes cannot read.
      replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        echo "Replay written: ", saveReplayPath, " (",
          getFileSize(saveReplayPath), " bytes)"
        runtimeConfig.writeReplay(readFile(saveReplayPath))
      if eventsPath.len > 0:
        ## Always written when a sink is configured, even with zero events: the
        ## summary row is how a reader tells "this match had none" from "the
        ## upload never happened".
        writeFile(eventsPath, collectedEvents.eventsJsonl(sim.tickCount))
        echo "Events written: ", eventsPath, " (", collectedEvents.len,
          " events)"
      let scoresJson = sim.playerResultsJson() & "\n"
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults(scoresJson)
      elif saveScoresPath.len > 0:
        writeFile(saveScoresPath, scoresJson)
      echo "results: ", scoresJson
      ## EDIT 5: bounded shutdown grace. The certification runner pings
      ## /healthz and /global AFTER the player pods start, and a short episode
      ## can already have written its artifacts by then. Keep answering for a
      ## bounded window, then exit — the runner waits on process exit anyway.
      let graceUntil =
        getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
      while getMonoTime() < graceUntil:
        sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    runFrameLimiter(lastTick, not replayLoaded and config.fastMode,
      sockets, playerIndices, SkimmerCount)
