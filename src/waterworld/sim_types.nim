## Shared constants and the hashed state types of the waterworld tank.
##
## NO FLOATING POINT LIVES IN THIS FILE, and none may be added: the replay's
## per-tick `gameHash` chain is re-derived by the **emscripten/wasm32** build of
## this same module in the browser and has to match the **native amd64** server
## bit for bit. Integers make that true by construction rather than by an
## argument about two builds of libm agreeing. `tests/test_determinism.nim`
## greps this file (and sim/tank/trig/sensors/sim_config/sim_state) for `float`,
## `sin`, `cos`, `sqrt` and friends and fails on a hit.
##
## The other half of that contract: Nim's `int` is 64-bit natively and **32-bit
## under `--cpu:wasm32`**, so every stored field below is an explicit `int32`,
## `int64`, `uint8`, `bool` or `enum` — never a bare `int` — and every product
## of two sim quantities is computed in `int64` and narrowed with an explicit
## truncating `div`.

import std/random

const
  GameName* = "walker-waterworld"
  GameVersion* = "1"
    ## GV1 (tank rules): four skimmers, 2-of-4 plankton capture, poison,
    ## 16 sensors.
    ##
    ## PREPEND-ONLY CHANGELOG. A new number means the rules that produce a
    ## replay changed, so a recorded replay no longer replays under it; say
    ## WHAT the number means and what it obsoletes, and never reuse a number
    ## for a different rule (`tools/ci/check_gameversion.sh` diffs the headline
    ## above, not the digits).

  TargetFps* = 24
    ## Wall-clock pace of the live loop. Kept at ctf's 24 because every
    ## speed-coupled layer (PlaybackSpeeds, the lull scan, the momentum series,
    ## tickTime, the transport bar) is keyed to it.
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## chrome_common.js carries these as its raw-file fallback; a test pins the
    ## two lists equal so the fallback can never drift from the engine.

  # --- the board ------------------------------------------------------------
  BoardScaleUm* = 10_000'i32   ## µm per logical board pixel (1 px = 1 cm).
  MapWidth* = 1200             ## logical board pixels (12.00 m).
  MapHeight* = 800             ## logical board pixels ( 8.00 m).
  RenderScale* = 2
    ## Supersample factor the spectator board is emitted at. 1200x800 logical
    ## pixels is 960 000, well under MaxSupersampledMapPixels, so the tank
    ## always renders at 2x.
  MaxSupersampledMapPixels* = 8_000_000
  WasmViewerBudgetBytes* = 1_600_000_000

  # --- geometry (fixed; identical every episode) ----------------------------
  ArenaW* = 12_000_000'i32     ## µm (12.00 m)
  ArenaH* = 8_000_000'i32      ## µm ( 8.00 m)
  SkimmerRadius* = 240_000'i32
  FoodRadius* = 160_000'i32
  PoisonRadius* = 160_000'i32
  RockCentreX* = 6_000_000'i32
  RockCentreY* = 4_000_000'i32
  RockRadius* = 900_000'i32
  SensorRange* = 2_400_000'i32
  SensorCount* = 16
  SkimmerCount* = 4
  FoodCount* = 5
  PoisonCount* = 8

  # --- motion ---------------------------------------------------------------
  MaxThrustAccel* = 5_208'i32  ## µm/tick² at thrust level 7 (3.00 m/s²).
  ThrustLevels* = 8
  DragNum* = 39'i32
  DragDen* = 1024'i32
  MaxSkimmerSpeed* = 135_000'i32  ## µm/tick (3.24 m/s).
  WallRestitutionNum* = 2'i32
  WallRestitutionDen* = 5'i32
  FoodSpeedSet* = [28_000'i32, 33_000'i32, 38_000'i32]
  PoisonSpeedSet* = [40_000'i32, 46_000'i32, 52_000'i32]
  RespawnTicks* = 24'i32
  StunTicks* = 12'i32
  CoopNeeded* = 2
  NibbleRearmUm* = 600_000'i32

  # --- scoring, in micro-points (1e-6 of a score point) ---------------------
  CaptureMicro* = 10_000_000'i64
  NibbleMicro* = 50_000'i64
  PoisonMicro* = -2_000_000'i64

  # --- spawn acceptance predicate ------------------------------------------
  SpawnRockClearUm* = 1_200_000'i32
  SpawnWallClearUm* = 300_000'i32
  SpawnSkimmerClearUm* = 2_000_000'i32     ## at t = 0, from every spawn point.
  RespawnSkimmerClearUm* = 1_500_000'i32   ## at a respawn, from every skimmer.
  SpawnAttempts* = 64
  SpawnLatticeStepUm* = 500_000'i32
  MaxLatticeFallbacks* = 8
    ## More than this in one episode is a `fault`: the sampler is degrading and
    ## the tank is telling us its geometry no longer admits a legal spawn.

  # --- defaults the config can move ----------------------------------------
  DefaultMaxTicks* = 1728
  DefaultTurnTicks* = 72
  DefaultCaptureTarget* = 20
  DefaultWallClockBudgetSeconds* = 660
  DefaultTurnBudgetMs* = 16_000
  DefaultAttempt1Ms* = 9_000
  DefaultRetryMs* = 5_000
  DefaultTurnSpacingMs* = 12_000
  DefaultLobbyJoinTimeoutTicks* = 1728
  DefaultStartWaitTicks* = 48
  DefaultGameOverTicks* = 48
  DefaultMaxOutputTokens* = 900

  MaxPlayers* = 4

  # --- rune caps (RUNES, never bytes) --------------------------------------
  MaxNoteRunes* = 160
  MaxSayRunes* = 48
  MaxPolicyLabelRunes* = 48
  MaxFallbackDetailRunes* = 200
  MaxIntentRecordRunes* = 600
  MaxPromptRunes* = 4000

  # --- websocket routes ----------------------------------------------------
  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"

  # --- results enums -------------------------------------------------------
  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"
  EndRuleTargetMet* = "target_met"
  EndRuleFullTime* = "full_time"
  EndRuleWallClock* = "wall_clock"
  EndRuleSimFault* = "sim_fault"
  EndRuleHostError* = "host_error"

  BroadcastChromeSpriteId* = 4090
    ## Reserved never-drawn 1x1 sprite whose LABEL carries the broadcast chrome
    ## JSON on the binary channel — the only channel that survives a hosted
    ## replay.

type
  WaterworldError* = object of CatchableError
  SimGuardError* = object of WaterworldError
    ## A step-10 invariant guard tripped: the episode ends `fault/sim_fault`
    ## with a partial replay rather than dying unattributed.

  GamePhase* = enum
    Lobby
    Starting
    Playing
    GameOver

  ParticleState* = enum
    psLive
    psRespawning

  Particle* = object
    state*: ParticleState
    x*, y*: int32          ## centre, µm
    dir*: uint8            ## 0..31, a DirQ12 index
    speed*: int32          ## µm per tick; constant for the particle's life
    timer*: int32          ## respawn countdown, 0 .. RespawnTicks

  Skimmer* = object
    x*, y*: int32          ## centre, µm
    vx*, vy*: int32        ## µm per tick
    stun*: int32           ## ticks of forced coast left
    cmd*: uint8            ## the command byte applied this tick (presentation
                           ## only: the byte is RECORDED, so it is never mixed
                           ## into gameHash — the state it produced is).
    nibbleArmed*: array[FoodCount, bool]

  PlayerInfo* = object
    ## One seat's roster row. `address` is the REAL policy name and lives on the
    ## spectator side only; the in-game name of the body it drives is
    ## `SKIM-<skimmer+1>` and nothing else.
    address*: string
    joinOrder*: int32      ## the seat slot, 0 .. numAgents-1.
    token*: string
    reward*: int32

  SimEventKind* = enum
    Capture
    Nibble
    PoisonHit
    Spawn
    NearMiss
    Intent
    PhaseChange
    TargetMet

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    source*: int           ## seat slot, or -1
    target*: int
    amount*: int
    x*, y*: int            ## board pixels
    item*: string
    content*: string

  GameConfig* = object
    ## Every field the platform may set. `sim_config.update` reads exactly
    ## these and `tests/test_manifest.nim` asserts `game.config_schema` covers
    ## the set, so a key either appears in the schema or is not settable.
    seed*: int
    tokens*: seq[string]
    playerNames*: seq[string]
    slotAliases*: seq[string]
    closedRoster*: bool
    numAgents*: int
    minPlayers*: int
    maxTicks*: int
    maxGames*: int
    turnTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    startWaitTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    speed*: int
    model*: string
    maxOutputTokens*: int
    captureTarget*: int
    foodCount*: int
    poisonCount*: int
    sensorRangeUm*: int
    coopNeeded*: int
    stunTicks*: int
    respawnTicks*: int

  SimServer* = object
    ## The whole hashed world plus the presentation state the broadcast layer
    ## derives from it. Serialized verbatim into replay keyframes (flatty), so
    ## FIELD ORDER IS SACRED: appending is safe, reordering invalidates every
    ## recorded keyframe.
    config*: GameConfig
    tickCount*: int
    phase*: GamePhase
    gameStartTick*: int
    startWaitTimer*: int
    gameOverTimer*: int
    players*: seq[PlayerInfo]
    nextJoinOrder*: int
    skimmers*: array[SkimmerCount, Skimmer]
    food*: array[FoodCount, Particle]
    poison*: array[PoisonCount, Particle]
    perm*: array[SkimmerCount, int32]        ## seat -> skimmer
    seatOf*: array[SkimmerCount, int32]      ## skimmer -> seat
    captures*, nibbles*, poisonHits*: int32
    assists*: array[SkimmerCount, int32]
    nibblesBySeat*: array[SkimmerCount, int32]
    poisonBySeat*: array[SkimmerCount, int32]
    thrustTicks*: array[SkimmerCount, int32] ## sum of applied levels, per seat
    thrustMicro*: int64
    scoreMicro*: int64
    rngDraws*: int64
    latticeFallbacks*: int32
    rng*: Rand
    endReason*: string
    endRule*: string
    # --- presentation / non-hashed -------------------------------------------
    seatNames*: seq[string]        ## real policy names, spectator side only.
    seatPolicyKind*: seq[string]   ## "llm" | "scripted"
    llmTurns*: seq[int32]
    fallbackTurns*: seq[int32]
    feedIntents*: seq[string]      ## the last few `intent` records, for the feed
    bubbles*: seq[SayBubble]
    fx*: seq[BoardFx]
    turnIndex*: int
    collectEvents*: bool
    events*: seq[SimEvent]
    gameEventLoggingEnabled*: bool
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int

  SayBubble* = object
    ## A spectator-side speech bubble. Never seen by any seat, never hashed.
    skimmer*: int32
    text*: string
    untilTick*: int

  BoardFxKind* = enum
    fxCapture
    fxNibble
    fxPoison
    fxNearMiss

  BoardFx* = object
    kind*: BoardFxKind
    x*, y*: int32          ## µm
    tick*: int
    amount*: int32         ## milli-points, for the popped number
    skimmer*: int32
    holdersMask*: uint8    ## bit i set = skimmer i took part in this capture

const
  # Fixed quadrant centres, at rest, in SIM coordinates (origin top-left, y
  # DOWN). The view metres a policy is told are, in order: (3.00, 2.00),
  # (9.00, 2.00), (3.00, 6.00), (9.00, 6.00).
  SkimmerSpawnUm*: array[SkimmerCount, tuple[x, y: int32]] = [
    (3_000_000'i32, 6_000_000'i32),
    (9_000_000'i32, 6_000_000'i32),
    (3_000_000'i32, 2_000_000'i32),
    (9_000_000'i32, 2_000_000'i32)
  ]

proc thrustMicroFor*(level: int32): int64 {.inline.} =
  ## The thrust bill for one tick at one level: level² * 1000 / 49, so level 7
  ## costs 1000 micro-points (0.001 point) and coasting costs nothing.
  (int64(level) * int64(level) * 1000'i64) div 49'i64

proc skimmerAlias*(skimmer: int): string {.inline.} =
  ## The ANONYMOUS in-game name of a body on the board — which every seat
  ## legitimately knows — and never an entrant. This is one of the two name
  ## spaces; the other (real policy names) exists only spectator-side.
  "SKIM-" & $(skimmer + 1)

proc foodId*(index: int): string {.inline.} = "F" & $(index + 1)
proc poisonId*(index: int): string {.inline.} = "P" & $(index + 1)

proc decodeThrust*(cmd: uint8): tuple[dir: int32, level: int32] {.inline.} =
  ## The command byte uses the WHOLE 0..255 range: 32 directions x 8 levels is
  ## exactly 256, so no value is reserved and no value needs repair.
  (int32(cmd) div 8'i32, int32(cmd) mod 8'i32)

proc encodeThrust*(dir, level: int32): uint8 {.inline.} =
  uint8(((dir mod 32'i32) * 8'i32) + (level mod 8'i32))
