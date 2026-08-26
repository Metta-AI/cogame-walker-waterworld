## Sim-state services shared by the gameplay core and the layers above it: the
## replay hash (`gameHash`/`mixHash`), the tier-2 event sink (`emitEvent`), the
## lobby log lines, and the integer score formatter.
##
## NO FLOATING POINT — `scoreText` formats micro-points by hand precisely so the
## log lines a hosted episode prints cannot drag a float into this file.

import std/strutils

import sim_types

proc logGameEvent*(sim: SimServer, text: string) =
  ## One game event on stdout, for the Docker logs a hosted episode is read
  ## through.
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting*(sim: var SimServer) =
  let
    needed = max(0, sim.config.minPlayers - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and needed == sim.lastLobbyNeededLogged:
    return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.logGameEvent("waiting for players: " & $players & "/" &
    $sim.config.minPlayers & ", need " & $needed & " more")

proc logLobbyCountdown*(sim: var SimServer) =
  if sim.startWaitTimer <= 0 or sim.startWaitTimer mod TargetFps != 0:
    return
  sim.logGameEvent("the tank goes live in " &
    $(sim.startWaitTimer div TargetFps))

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  if sim.phase != Starting or sim.startWaitTimer <= 0:
    return 0
  max(1, (sim.startWaitTimer + TargetFps - 1) div TargetFps)

proc scoreText*(micro: int64): string =
  ## Micro-points as a signed 3-decimal string, by integer arithmetic only.
  let
    negative = micro < 0
    magnitude = if negative: -micro else: micro
    whole = magnitude div 1_000_000'i64
    milli = (magnitude mod 1_000_000'i64) div 1_000'i64
  (if negative: "-" else: "") & $whole & "." & align($milli, 3, '0')

# ---------------------------------------------------------------------------
#  The hash chain
# ---------------------------------------------------------------------------

proc mixHash(hash: var uint64, value: uint64) {.inline.} =
  ## FNV-1a. Deterministic on every target: no float, no platform int width.
  hash = hash xor value
  hash = hash * 1099511628211'u64

proc mixInt(hash: var uint64, value: int64) {.inline.} =
  hash.mixHash(cast[uint64](value))

proc mixBool(hash: var uint64, value: bool) {.inline.} =
  hash.mixInt(int64(ord(value)))

proc gameHash*(sim: SimServer): uint64 =
  ## A deterministic hash of every gameplay field the browser re-derives from
  ## the recorded command bytes. It NEVER mixes sensor frames, FX, bubbles,
  ## feed text, seat names or policy labels: those are presentation, and mixing
  ## them would make a spectator-side change break every recorded replay.
  result = 14695981039346656037'u64
  result.mixInt(int64(sim.tickCount))
  result.mixInt(int64(ord(sim.phase)))
  result.mixInt(int64(sim.gameStartTick))
  result.mixInt(int64(sim.startWaitTimer))
  result.mixInt(int64(sim.gameOverTimer))
  for i in 0 ..< SkimmerCount:
    let s = sim.skimmers[i]
    result.mixInt(int64(s.x))
    result.mixInt(int64(s.y))
    result.mixInt(int64(s.vx))
    result.mixInt(int64(s.vy))
    result.mixInt(int64(s.stun))
    for f in 0 ..< FoodCount:
      result.mixBool(s.nibbleArmed[f])
  for f in 0 ..< FoodCount:
    let p = sim.food[f]
    result.mixInt(int64(ord(p.state)))
    result.mixInt(int64(p.x))
    result.mixInt(int64(p.y))
    result.mixInt(int64(p.dir))
    result.mixInt(int64(p.speed))
    result.mixInt(int64(p.timer))
  for q in 0 ..< PoisonCount:
    let p = sim.poison[q]
    result.mixInt(int64(ord(p.state)))
    result.mixInt(int64(p.x))
    result.mixInt(int64(p.y))
    result.mixInt(int64(p.dir))
    result.mixInt(int64(p.speed))
    result.mixInt(int64(p.timer))
  result.mixInt(int64(sim.captures))
  result.mixInt(int64(sim.nibbles))
  result.mixInt(int64(sim.poisonHits))
  for seat in 0 ..< SkimmerCount:
    result.mixInt(int64(sim.assists[seat]))
    result.mixInt(int64(sim.nibblesBySeat[seat]))
    result.mixInt(int64(sim.poisonBySeat[seat]))
    result.mixInt(int64(sim.thrustTicks[seat]))
  result.mixInt(sim.thrustMicro)
  result.mixInt(sim.scoreMicro)
  result.mixInt(sim.rngDraws)
  result.mixInt(int64(sim.latticeFallbacks))
  # A digest of `perm`, not the array: the seat -> skimmer map is drawn once and
  # never changes, so one mixed value is enough to catch a build that dealt it
  # differently.
  var permDigest = 0'i64
  for seat in 0 ..< SkimmerCount:
    permDigest = permDigest * 4'i64 + int64(sim.perm[seat])
  result.mixInt(permDigest)

# ---------------------------------------------------------------------------
#  The tier-2 event sink
# ---------------------------------------------------------------------------

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  source = -1,
  target = -1,
  amount = 0,
  x = 0,
  y = 0,
  item = "",
  content = ""
) =
  ## Appends one tier-2 analysis event. A no-op unless `collectEvents` is on, so
  ## a live server nobody is analysing pays nothing. `SimEvent` never enters
  ## `gameHash`, so nothing here can affect determinism.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount, kind: kind, source: source, target: target,
    amount: amount, x: x, y: y, item: item, content: content)

proc emitPhaseChange*(sim: var SimServer, newPhase: GamePhase) =
  ## Call BEFORE assigning `sim.phase`, with the phase being switched to.
  if not sim.collectEvents:
    return
  sim.emitEvent(PhaseChange, amount = ord(newPhase),
    content = ($newPhase).toLowerAscii)
