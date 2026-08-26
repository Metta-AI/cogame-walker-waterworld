## The gameplay core: the resolution order of one tick, exactly and with no
## exceptions, plus the roster and hash machinery it needs. Imports and
## re-exports the other sim modules, so `import waterworld/sim` sees everything.
##
## NO FLOATING POINT.
##
## THE RESOLUTION ORDER (design note §Resolution order). Steps 1 and 2 — the
## turn boundary and the controller compile — happen in the SERVER, outside this
## module and outside the determinism boundary: what arrives here is the array
## of recorded command bytes, which is the only thing the replay carries and the
## only thing the browser re-simulates from.
##
##   3. skimmer dynamics, in SKIMMER INDEX ORDER (never seat order: seat order
##      varies with `perm` and the loop must not)
##   4. particle motion, plankton in id order then poison in id order
##   5. sensor frames (derived state, not hashed — its inputs already are)
##   6. contacts: poison first, then capture/nibble
##   7. thrust cost
##   8. score
##   9. hash
##  10. end checks

import std/random

import sim_types, trig, tank, sensors, sim_config, sim_state
export sim_types, trig, tank, sensors, sim_config, sim_state

proc seatCount*(sim: SimServer): int {.inline.} =
  max(1, min(SkimmerCount, sim.config.numAgents))

proc skimmerForSeat*(sim: SimServer, seat: int): int {.inline.} =
  if seat < 0 or seat >= SkimmerCount: -1 else: int(sim.perm[seat])

proc seatForSkimmer*(sim: SimServer, skimmer: int): int {.inline.} =
  if skimmer < 0 or skimmer >= SkimmerCount: -1 else: int(sim.seatOf[skimmer])

proc initSimServer*(config: GameConfig): SimServer =
  ## A fresh tank. Exactly three things are drawn at t = 0, in this fixed
  ## order, from one stream seeded with `config.seed`: (1) `perm`, (2) the five
  ## plankton, (3) the eight poison blooms.
  result.config = config
  result.phase = Lobby
  result.tickCount = 0
  result.gameStartTick = -1
  result.rng = initRand(config.seed)
  result.endReason = ""
  result.endRule = ""
  result.seatNames = newSeq[string](SkimmerCount)
  result.seatPolicyKind = newSeq[string](SkimmerCount)
  result.llmTurns = newSeq[int32](SkimmerCount)
  result.fallbackTurns = newSeq[int32](SkimmerCount)
  result.turnIndex = -1
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.gameEventLoggingEnabled = true
  for seat in 0 ..< SkimmerCount:
    result.seatPolicyKind[seat] = "scripted"
  result.drawPerm()
  for i in 0 ..< SkimmerCount:
    result.skimmers[i] = Skimmer(
      x: SkimmerSpawnUm[i].x, y: SkimmerSpawnUm[i].y, vx: 0, vy: 0, stun: 0, cmd: 0)
    for f in 0 ..< FoodCount:
      result.skimmers[i].nibbleArmed[f] = true
  for f in 0 ..< FoodCount:
    if f < config.foodCount:
      result.food[f] = result.drawParticle(FoodRadius, FoodSpeedSet, atStart = true)
    else:
      result.food[f] = Particle(state: psRespawning, timer: high(int32) div 2)
  for q in 0 ..< PoisonCount:
    if q < config.poisonCount:
      result.poison[q] = result.drawParticle(PoisonRadius, PoisonSpeedSet, atStart = true)
    else:
      result.poison[q] = Particle(state: psRespawning, timer: high(int32) div 2)

# ---------------------------------------------------------------------------
#  Roster
# ---------------------------------------------------------------------------

proc nextPlayerSlot*(sim: SimServer): int {.inline.} = sim.players.len

proc canAddPlayer*(sim: SimServer): bool {.inline.} =
  sim.players.len < sim.seatCount()

proc resolvePlayerSlot*(
  sim: SimServer, address, token: string, requestedSlot: int
): int =
  ## Which seat a connection is asking for. Joins are strictly
  ## slot-sequential, so the server admits a candidate only when this equals
  ## `nextPlayerSlot()`.
  if requestedSlot >= 0:
    return requestedSlot
  if token.len > 0:
    for i, configured in sim.config.tokens:
      if configured == token:
        return i
  sim.players.len

proc addPlayer*(
  sim: var SimServer, address: string, slot: int, token: string,
  trusted = false
): int =
  ## Seats one connection. `address` is the REAL policy name and stays
  ## spectator-side; the seat's in-game identity is the alias of the body it
  ## drives.
  let seat = if slot >= 0: slot else: sim.players.len
  if seat != sim.players.len:
    raise newException(WaterworldError,
      "player slot " & $seat & " is not the next open seat (" &
        $sim.players.len & ")")
  if seat >= sim.seatCount():
    raise newException(WaterworldError, "player slot " & $seat & " is beyond the pod")
  if not trusted and not sim.config.playerJoinAllowed(address, seat, token):
    raise newException(WaterworldError, "player credentials rejected for slot " & $seat)
  sim.players.add PlayerInfo(
    address: address, joinOrder: int32(seat), token: token, reward: 0)
  if seat < sim.seatNames.len:
    sim.seatNames[seat] = address
  sim.nextJoinOrder = sim.players.len
  seat

proc removePlayerAt*(sim: var SimServer, index: int) =
  ## A seat that drops does NOT lose its skimmer: the pod is fixed for the whole
  ## episode, the seat's intent source degrades to `shoal`, and the seat revives
  ## on reconnect. Deleting the row would renumber every later skimmer
  ## mid-replay, so the roster entry goes and nothing else moves.
  if index >= 0 and index < sim.players.len:
    sim.players.delete(index)
    sim.nextJoinOrder = sim.players.len

proc lobbyJoinTimedOut*(sim: SimServer): bool {.inline.} =
  sim.phase == Lobby and sim.players.len < sim.seatCount() and
    sim.tickCount >= sim.config.lobbyJoinTimeoutTicks

proc gameTicksElapsed*(sim: SimServer): int {.inline.} =
  if sim.gameStartTick < 0: 0 else: max(0, sim.tickCount - sim.gameStartTick)

proc effectiveMaxTicks*(sim: SimServer): int {.inline.} = sim.config.maxTicks

proc turnsPerEpisode*(sim: SimServer): int {.inline.} =
  max(1, sim.config.maxTicks div max(1, sim.config.turnTicks))

# ---------------------------------------------------------------------------
#  One tick
# ---------------------------------------------------------------------------

proc particleVelocity*(p: Particle): tuple[vx, vy: int32] {.inline.} =
  (int32((int64(p.speed) * int64(DirQ12[int(p.dir)].x)) div int64(Q12)),
   int32((int64(p.speed) * int64(DirQ12[int(p.dir)].y)) div int64(Q12)))

proc stepSkimmer(sim: var SimServer, i: int, cmd: uint8) =
  var s = sim.skimmers[i]
  let decoded = decodeThrust(cmd)
  var level = decoded.level
  if s.stun > 0:
    level = 0
    dec s.stun
  s.cmd = cmd
  # (2) thrust
  if level > 0:
    let scale = int64(MaxThrustAccel) * int64(level)
    s.vx = int32(int64(s.vx) +
      (int64(DirQ12[int(decoded.dir)].x) * scale) div (7'i64 * int64(Q12)))
    s.vy = int32(int64(s.vy) +
      (int64(DirQ12[int(decoded.dir)].y) * scale) div (7'i64 * int64(Q12)))
  # (3) drag, truncating toward zero so it is symmetric under negation
  s.vx = int32(int64(s.vx) - (int64(s.vx) * int64(DragNum)) div int64(DragDen))
  s.vy = int32(int64(s.vy) - (int64(s.vy) * int64(DragNum)) div int64(DragDen))
  # (4) speed clamp
  let speedSq = int64(s.vx) * int64(s.vx) + int64(s.vy) * int64(s.vy)
  if speedSq > int64(MaxSkimmerSpeed) * int64(MaxSkimmerSpeed):
    let mag = isqrt(speedSq)
    if mag > 0:
      s.vx = int32((int64(s.vx) * int64(MaxSkimmerSpeed)) div mag)
      s.vy = int32((int64(s.vy) * int64(MaxSkimmerSpeed)) div mag)
  # (5) move
  s.x = int32(int64(s.x) + int64(s.vx))
  s.y = int32(int64(s.y) + int64(s.vy))
  # (6) walls: x then y, so a corner resolves deterministically
  if s.x < SkimmerRadius:
    s.x = SkimmerRadius
    s.vx = int32(-(int64(s.vx) * int64(WallRestitutionNum)) div int64(WallRestitutionDen))
  elif s.x > ArenaW - SkimmerRadius:
    s.x = ArenaW - SkimmerRadius
    s.vx = int32(-(int64(s.vx) * int64(WallRestitutionNum)) div int64(WallRestitutionDen))
  if s.y < SkimmerRadius:
    s.y = SkimmerRadius
    s.vy = int32(-(int64(s.vy) * int64(WallRestitutionNum)) div int64(WallRestitutionDen))
  elif s.y > ArenaH - SkimmerRadius:
    s.y = ArenaH - SkimmerRadius
    s.vy = int32(-(int64(s.vy) * int64(WallRestitutionNum)) div int64(WallRestitutionDen))
  # (7) the rock: push out to exactly R, remove the normal velocity component
  # and return 40 % of it
  let
    clearance = RockRadius + SkimmerRadius
    dSq = distSqUm(s.x, s.y, RockCentreX, RockCentreY)
  if dSq < int64(clearance) * int64(clearance):
    let d = isqrt(dSq)
    var nx, ny: int64
    if d == 0:
      nx = int64(DirQ12[0].x)
      ny = int64(DirQ12[0].y)
    else:
      nx = ((int64(s.x) - int64(RockCentreX)) * int64(Q12)) div d
      ny = ((int64(s.y) - int64(RockCentreY)) * int64(Q12)) div d
    s.x = int32(int64(RockCentreX) + (nx * int64(clearance)) div int64(Q12))
    s.y = int32(int64(RockCentreY) + (ny * int64(clearance)) div int64(Q12))
    let vn = (int64(s.vx) * nx + int64(s.vy) * ny) div int64(Q12)
    s.vx = int32(int64(s.vx) - (7'i64 * vn * nx) div (5'i64 * int64(Q12)))
    s.vy = int32(int64(s.vy) - (7'i64 * vn * ny) div (5'i64 * int64(Q12)))
  sim.skimmers[i] = s

proc stepParticle(p: var Particle, radius: int32) =
  ## A live particle moves at EXACTLY constant speed forever: direction changes
  ## only at a bounce, and the whole motion is integer-exact with no energy
  ## drift to renormalise.
  let v = p.particleVelocity()
  p.x = int32(int64(p.x) + int64(v.vx))
  p.y = int32(int64(p.y) + int64(v.vy))
  if p.x < radius:
    p.x = radius
    p.dir = reflectVertical(p.dir)
  elif p.x > ArenaW - radius:
    p.x = ArenaW - radius
    p.dir = reflectVertical(p.dir)
  if p.y < radius:
    p.y = radius
    p.dir = reflectHorizontal(p.dir)
  elif p.y > ArenaH - radius:
    p.y = ArenaH - radius
    p.dir = reflectHorizontal(p.dir)
  let clearance = RockRadius + radius
  if distSqUm(p.x, p.y, RockCentreX, RockCentreY) <
      int64(clearance) * int64(clearance):
    let normal = rockNormalIndex(p.x, p.y)
    pushOutOfRock(p.x, p.y, clearance)
    p.dir = reflectNormal(p.dir, normal)

proc guardInvariants(sim: SimServer) =
  ## Step 10's invariant guard. A trip ends the episode `fault/sim_fault` with a
  ## partial replay — never a silent non-zero exit.
  for i in 0 ..< SkimmerCount:
    let s = sim.skimmers[i]
    if s.x < 0 or s.x > ArenaW or s.y < 0 or s.y > ArenaH:
      raise newException(SimGuardError,
        "skimmer " & $i & " centre left the tank: " & $s.x & "," & $s.y)
    let speedSq = int64(s.vx) * int64(s.vx) + int64(s.vy) * int64(s.vy)
    if speedSq > int64(MaxSkimmerSpeed + 1) * int64(MaxSkimmerSpeed + 1):
      raise newException(SimGuardError, "skimmer " & $i & " exceeded the speed clamp")
    if s.stun < 0 or s.stun > StunTicks:
      raise newException(SimGuardError, "skimmer " & $i & " stun out of range")
  for f in 0 ..< sim.config.foodCount:
    let p = sim.food[f]
    if int(p.dir) > 31:
      raise newException(SimGuardError, "plankton " & $f & " direction out of range")
    if p.timer < 0 or p.timer > int32(sim.config.respawnTicks):
      raise newException(SimGuardError, "plankton " & $f & " timer out of range")
    if p.state == psLive and (p.x < 0 or p.x > ArenaW or p.y < 0 or p.y > ArenaH):
      raise newException(SimGuardError, "plankton " & $f & " left the tank")
  for q in 0 ..< sim.config.poisonCount:
    let p = sim.poison[q]
    if int(p.dir) > 31:
      raise newException(SimGuardError, "poison " & $q & " direction out of range")
    if p.timer < 0 or p.timer > int32(sim.config.respawnTicks):
      raise newException(SimGuardError, "poison " & $q & " timer out of range")
  if sim.latticeFallbacks > MaxLatticeFallbacks:
    raise newException(SimGuardError,
      "the spawn sampler fell through to the lattice " &
        $sim.latticeFallbacks & " times")

proc finishGame(sim: var SimServer, reason, rule: string) =
  if sim.phase == GameOver:
    return
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.endReason = reason
  sim.endRule = rule
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.logGameEvent("game over: " & reason & "/" & rule &
    " — captures " & $sim.captures & ", score " & scoreText(sim.scoreMicro))

proc endEpisode*(sim: var SimServer, reason, rule: string) =
  ## The server's own hard stops (wall clock, host error) end the episode
  ## through the same door the rules do.
  sim.finishGame(reason, rule)

proc pushFx(sim: var SimServer, kind: BoardFxKind, x, y: int32, amount: int32,
            skimmer: int32, holdersMask = 0'u8) =
  ## Presentation only: never hashed, capped so a long episode cannot grow it.
  sim.fx.add BoardFx(kind: kind, x: x, y: y, tick: sim.tickCount,
    amount: amount, skimmer: skimmer, holdersMask: holdersMask)
  if sim.fx.len > 64:
    sim.fx.delete(0)

proc step*(sim: var SimServer, cmds: openArray[uint8]) =
  ## Advances the tank exactly one tick from the recorded command bytes.
  case sim.phase
  of Lobby:
    sim.logLobbyWaiting()
    if sim.players.len >= sim.config.minPlayers:
      sim.emitPhaseChange(Starting)
      sim.phase = Starting
      sim.startWaitTimer = sim.config.startWaitTicks
    inc sim.tickCount
    return
  of Starting:
    if sim.startWaitTimer > 0:
      dec sim.startWaitTimer
      sim.logLobbyCountdown()
    if sim.startWaitTimer <= 0:
      sim.emitPhaseChange(Playing)
      sim.phase = Playing
      # +1 because THIS tick is still the Starting tick: the first tick actually
      # simulated as Playing is the next one, and `gameTicksElapsed` must read 0
      # there or turn 0 would never fire.
      sim.gameStartTick = sim.tickCount + 1
      sim.logGameEvent("the tank is live: 4 skimmers, " &
        $sim.config.foodCount & " plankton, " & $sim.config.poisonCount &
        " poison blooms")
    inc sim.tickCount
    return
  of GameOver:
    if sim.gameOverTimer > 0:
      dec sim.gameOverTimer
    inc sim.tickCount
    return
  of Playing:
    discard

  var
    skimmerStartX: array[SkimmerCount, int32]
    skimmerStartY: array[SkimmerCount, int32]
    foodStartX: array[FoodCount, int32]
    foodStartY: array[FoodCount, int32]
    poisonStartX: array[PoisonCount, int32]
    poisonStartY: array[PoisonCount, int32]
    appliedLevel: array[SkimmerCount, int32]
    foodWasLive: array[FoodCount, bool]
    poisonWasLive: array[PoisonCount, bool]

  for i in 0 ..< SkimmerCount:
    skimmerStartX[i] = sim.skimmers[i].x
    skimmerStartY[i] = sim.skimmers[i].y
  for f in 0 ..< FoodCount:
    foodStartX[f] = sim.food[f].x
    foodStartY[f] = sim.food[f].y
    foodWasLive[f] = sim.food[f].state == psLive
  for q in 0 ..< PoisonCount:
    poisonStartX[q] = sim.poison[q].x
    poisonStartY[q] = sim.poison[q].y
    poisonWasLive[q] = sim.poison[q].state == psLive

  # --- 3. skimmer dynamics, skimmer index order ---------------------------
  for i in 0 ..< SkimmerCount:
    let cmd = if i < cmds.len: cmds[i] else: 0'u8
    appliedLevel[i] = (if sim.skimmers[i].stun > 0: 0'i32
                       else: decodeThrust(cmd).level)
    sim.stepSkimmer(i, cmd)

  # --- 4. particle motion, plankton in id order then poison in id order ----
  for f in 0 ..< sim.config.foodCount:
    if sim.food[f].state == psLive:
      stepParticle(sim.food[f], FoodRadius)
    else:
      if sim.food[f].timer > 0:
        dec sim.food[f].timer
      if sim.food[f].timer <= 0:
        sim.food[f] = sim.drawParticle(FoodRadius, FoodSpeedSet, atStart = false)
        for i in 0 ..< SkimmerCount:
          sim.skimmers[i].nibbleArmed[f] = true
        sim.emitEvent(Spawn, item = "food", content = foodId(f))
  for q in 0 ..< sim.config.poisonCount:
    if sim.poison[q].state == psLive:
      stepParticle(sim.poison[q], PoisonRadius)
    else:
      if sim.poison[q].timer > 0:
        dec sim.poison[q].timer
      if sim.poison[q].timer <= 0:
        sim.poison[q] = sim.drawParticle(PoisonRadius, PoisonSpeedSet, atStart = false)
        sim.emitEvent(Spawn, item = "poison", content = poisonId(q))

  # --- 6a. poison contacts, skimmer index order then poison id order -------
  for i in 0 ..< SkimmerCount:
    for q in 0 ..< sim.config.poisonCount:
      # A particle that RESPAWNED this tick has no swept path: it appeared at a
      # fresh seeded point at least 1.50 m from every live skimmer, so it cannot
      # be touched on the tick it arrives, and sweeping the teleport line would
      # invent contacts along it.
      if sim.poison[q].state != psLive or not poisonWasLive[q]:
        continue
      if not sweptContact(
          skimmerStartX[i], skimmerStartY[i], sim.skimmers[i].x, sim.skimmers[i].y,
          poisonStartX[q], poisonStartY[q], sim.poison[q].x, sim.poison[q].y,
          SkimmerRadius + PoisonRadius):
        continue
      let seat = sim.seatForSkimmer(i)
      sim.pushFx(fxPoison, sim.poison[q].x, sim.poison[q].y,
        int32(PoisonMicro div 1000'i64), int32(i))
      sim.poison[q].state = psRespawning
      sim.poison[q].timer = int32(sim.config.respawnTicks)
      inc sim.poisonHits
      if seat >= 0:
        inc sim.poisonBySeat[seat]
      sim.scoreMicro += PoisonMicro
      sim.skimmers[i].stun = int32(sim.config.stunTicks)
      sim.skimmers[i].vx = sim.skimmers[i].vx div 2'i32
      sim.skimmers[i].vy = sim.skimmers[i].vy div 2'i32
      sim.emitEvent(PoisonHit, source = seat, item = poisonId(q),
        x = int(sim.skimmers[i].x div BoardScaleUm),
        y = int(sim.skimmers[i].y div BoardScaleUm))
      sim.logGameEvent(skimmerAlias(i) & " hits poison " & poisonId(q) &
        " — -2, stunned")

  # --- 6b. capture / nibble, plankton id order -----------------------------
  for f in 0 ..< sim.config.foodCount:
    if sim.food[f].state != psLive or not foodWasLive[f]:
      continue
    var holders: seq[int]
    for i in 0 ..< SkimmerCount:
      if sweptContact(
          skimmerStartX[i], skimmerStartY[i], sim.skimmers[i].x, sim.skimmers[i].y,
          foodStartX[f], foodStartY[f], sim.food[f].x, sim.food[f].y,
          SkimmerRadius + FoodRadius):
        holders.add(i)
    if holders.len >= sim.config.coopNeeded:
      # A stunned skimmer still counts: a body in the water still holds the
      # plankton, and the alternative punishes the pod twice for one mistake.
      var names = ""
      var mask = 0'u8
      for k, i in holders:
        if k > 0: names.add(" + ")
        names.add(skimmerAlias(i))
        mask = mask or (1'u8 shl uint8(i))
        let seat = sim.seatForSkimmer(i)
        if seat >= 0:
          inc sim.assists[seat]
      sim.pushFx(fxCapture, sim.food[f].x, sim.food[f].y,
        int32(CaptureMicro div 1000'i64), int32(holders[0]), mask)
      sim.food[f].state = psRespawning
      sim.food[f].timer = int32(sim.config.respawnTicks)
      inc sim.captures
      sim.scoreMicro += CaptureMicro
      sim.emitEvent(Capture, source = sim.seatForSkimmer(holders[0]),
        amount = holders.len, item = foodId(f),
        x = int(sim.food[f].x div BoardScaleUm),
        y = int(sim.food[f].y div BoardScaleUm))
      sim.logGameEvent(names & " take plankton " & foodId(f) & " — +10")
    elif holders.len == 1:
      let i = holders[0]
      if sim.skimmers[i].nibbleArmed[f]:
        let seat = sim.seatForSkimmer(i)
        sim.pushFx(fxNibble, sim.food[f].x, sim.food[f].y,
          int32(NibbleMicro div 1000'i64), int32(i))
        inc sim.nibbles
        if seat >= 0:
          inc sim.nibblesBySeat[seat]
        sim.scoreMicro += NibbleMicro
        sim.skimmers[i].nibbleArmed[f] = false
        sim.emitEvent(Nibble, source = seat, item = foodId(f))
    if holders.len < sim.config.coopNeeded:
      # NEAR MISS — the drama the game is made of: two skimmers both within
      # 1.00 m of one plankton in the same tick without capturing it.
      var close = 0
      for i in 0 ..< SkimmerCount:
        if withinUm(sim.skimmers[i].x, sim.skimmers[i].y,
            sim.food[f].x, sim.food[f].y, 1_000_000'i32):
          inc close
      if close >= 2:
        sim.pushFx(fxNearMiss, sim.food[f].x, sim.food[f].y, 0, -1)
        sim.emitEvent(NearMiss, item = foodId(f))
    # Re-arm a nibble the first tick the centres are more than NibbleRearmUm
    # apart. This is what stops a lone skimmer farming +0.050 a tick.
    for i in 0 ..< SkimmerCount:
      if not sim.skimmers[i].nibbleArmed[f] and
          not withinUm(sim.skimmers[i].x, sim.skimmers[i].y,
            sim.food[f].x, sim.food[f].y, NibbleRearmUm):
        sim.skimmers[i].nibbleArmed[f] = true

  # --- 7. thrust cost, skimmer index order ---------------------------------
  for i in 0 ..< SkimmerCount:
    let level = appliedLevel[i]
    if level > 0:
      sim.thrustMicro += thrustMicroFor(level)
      let seat = sim.seatForSkimmer(i)
      if seat >= 0:
        sim.thrustTicks[seat] += level

  # --- 8. score ------------------------------------------------------------
  sim.scoreMicro =
    CaptureMicro * int64(sim.captures) +
    NibbleMicro * int64(sim.nibbles) +
    PoisonMicro * int64(sim.poisonHits) -
    sim.thrustMicro

  inc sim.tickCount

  # --- 10. end checks, in this order --------------------------------------
  if sim.captures >= int32(sim.config.captureTarget):
    sim.emitEvent(TargetMet, amount = int(sim.captures))
    sim.finishGame(ReasonComplete, EndRuleTargetMet)
    return
  if sim.gameTicksElapsed() >= sim.config.maxTicks:
    sim.finishGame(ReasonComplete, EndRuleFullTime)
    return
  sim.guardInvariants()
