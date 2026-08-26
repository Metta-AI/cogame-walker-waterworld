# cogame-walker-waterworld

WALKER-WATERWORLD

Four thruster drones ("skimmers") patrol a 12.00 m x 8.00 m tank seen from above, feeling for drifting plankton with sixteen short-range proximity sensors each. A plankton particle can only be taken by TWO SKIMMERS TOUCHING IT AT THE SAME INSTANT — one skimmer alone can nudge it and wait, nothing more — and the same water carries eight drifting poison blooms that sting, stun and cost the whole pod points. Nobody can talk. Every seat sees only what its own sensors reach.

The pod's score is ONE number and every seat gets it:
  score = 10.000*captures + 0.050*nibbles - 2.000*poisonHits - thrustCost
Higher is better. Reaching 20 catches ends the run early and wins it. The league ranks a seat by the MEAN of its shared scores across episodes — its cross-play mean — not by Elo: with four identical scores every episode is a four-way draw and Elo cannot separate anybody.

An episode is 1728 ticks (72.0 s) at 24 Hz, divided into 24 decision turns of 72 ticks. Every 3 seconds each seat sets ONE order; a deterministic autopilot runs it 24 times a second, steering, leading a moving target and backing off poison. The order is the policy interface; the per-tick thrust byte is derived server-side, recorded, and replayed.

Policies: `PLAYER_PROMPT=<strategy>` makes a seat an LLM seat, `PLAYER_SCRIPTED=shoal|drifter` makes it scripted, and a seat that sets neither is `shoal`. One image, one player entrypoint, env-switched.

---

## What it looks like

The board is a top-down tank rendered server-side into the Sprite v1 protocol
and blitted by the inherited `client/broadcast_core.js`: dark rippled water, a
lit boulder dead centre, four baked drone hulls whose **thruster plume reads the
command byte** (which is what makes continuous control visible), pale-green
plankton, dark magenta poison blooms — and **all sixteen sensor rays per
skimmer**, drawn as dotted 2.40 m spokes coloured by what each ray found. The
spoke set reads as a live outline of what that skimmer can feel, which is the
whole partial-observation story in one glance.

The character sprites are nano-banana renders of the Softmax cog rebuilt as
thruster drones, one kit per skimmer so the four read apart at board scale with
every label hidden. The source sheets are committed under `scripts/art/source/`
and `scripts/art/split_sheet.py` turns them into the board sprites in `data/art/`.

## Repo layout

| Path | What it is |
|---|---|
| `src/walker_waterworld.nim` | the game server entrypoint (`/bin/walker-waterworld`) |
| `src/walker_waterworld_player.nim` | the thin seat registrar (`/bin/walker-waterworld-player`) |
| `src/waterworld/sim_types.nim` | every constant and every hashed type. **No floating point** |
| `src/waterworld/trig.nim` | the committed 32-entry `DirQ12` table and `isqrt`. The only trigonometry |
| `src/waterworld/tank.nim` | geometry, the seeded draws, the bounded spawn sampler, the swept-contact test |
| `src/waterworld/sensors.nim` | `frameFor` — the ONE function that builds a skimmer's percept |
| `src/waterworld/sim.nim` | the resolution order of one tick |
| `src/waterworld/roster.nim` | join/auth and `playerResultsJson` (where micro-points become doubles) |
| `src/waterworld/intents.nim` | the reply schema, the tolerant parser, the rune discipline |
| `src/waterworld/control.nim` | `thrustCommand` — the deterministic autopilot |
| `src/waterworld/baselines.nim` | `shoal` and `drifter`, and the three swept `BaselineParams` |
| `src/waterworld/llm.nim` | the credential ladder, the single-haiku model list, curly batching |
| `src/waterworld/decide.nim` | the per-turn loop: ONE parallel batch, two deadlines, the budget guard |
| `src/waterworld/replays.nim` | the `COWLDWWD` codec, keyframes, the precompute walk, the transport |
| `src/waterworld/broadcast.nim` | the chrome state frame and the beat derivation |
| `src/waterworld/global.nim` | the board: bakes, sprites, objects, the sensor rays |
| `src/waterworld/server.nim` | mummy, the routes, the episode loop, the artifacts |
| `replay-viewer/` | the emscripten entry, the link flags and the OffscreenCanvas Worker |
| `client/` | the inherited broadcast chrome plus the appended waterworld game block |
| `tools/replay_summary.py` | read any replay with nothing but Python 3 |
| `tools/tune_baselines.nim` | the grid sweep behind `BaselineParams` |

## Building and playing it

You do not need a local toolchain: `ci.yml` is the harness. It runs every
`tests/*.nim` in BOTH debug and release, builds the production image and plays a
real four-container episode in raw Docker from the certification fixture, then
builds the static replay-viewer bundle and **executes it in headless chromium**
against the replay that episode produced.

```bash
docker build -t coworld-walker-waterworld:ci .
./tools/ci/docker_smoke.sh coworld-walker-waterworld:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak 12 --strict-text-bounds
```

## Policies

One image, one player entrypoint, env-switched — which is what keeps a champion
and a scripted filler byte-identical apart from their environment:

| name | env | role |
|---|---|---|
| `walker-waterworld-tandemhunt` | `PLAYER_PROMPT` | champion #1: hunt in a fixed pair and never break it |
| `walker-waterworld-relay` | `PLAYER_PROMPT` | champion #2: play zones and relay |
| `walker-waterworld-shoal` | `PLAYER_SCRIPTED=shoal` | filler: pair and hunt |
| `walker-waterworld-drifter` | `PLAYER_SCRIPTED=drifter` | filler: never coordinates, deliberately weaker |

The set lives in `tools/ci/policies.json`; `coworld-release.yml` reads it.

## Determinism

The whole sim runs in **integers** — micrometres, µm/tick, micro-points — with a
committed 32-entry unit-vector table and one integer square root. That is not
tidiness: replays are re-simulated by the **emscripten/wasm32** build of the same
`src/waterworld/sim.nim` the **native amd64** server ran, and their per-tick
`gameHash` chains must match bit for bit. Integers make that true by
construction rather than by an argument about two builds of libm agreeing.

`tests/test_determinism.nim` is the gate: same seed plus same command-byte log
gives the same hash at every tick, a one-unit change in any byte changes it, a
committed golden fixture pins every 48th tick, and a source guard greps the
determinism boundary for `float`, `sin`, `sqrt` and `rand(`.

---

THE TANK

12.00 m x 8.00 m, one submerged rock of radius 0.90 m dead centre at (6.00, 4.00). Coordinates shown to a policy are metres from the BOTTOM-LEFT corner, x right, y up; bearings are degrees counter-clockwise from east (0 = right, 90 = up).

BODIES
  4 skimmers, radius 0.24 m, spawning at rest at (3,2), (9,2), (3,6), (9,6)
  5 plankton, radius 0.16 m, speed 0.67 / 0.79 / 0.91 m/s
  8 poison blooms, radius 0.16 m, speed 0.96 / 1.10 / 1.25 m/s
Skimmers pass through each other: two-on-one-particle is geometrically easy and the TIMING is the hard part. Particles travel at exactly constant speed forever — direction changes only at a bounce.

MOTION
Thrust level 0..7 in one of 32 directions, 3.00 m/s^2 at level 7. Drag 3.81 %/tick, terminal speed 3.24 m/s. A wall returns 40 % of the normal speed; the rock does the same about its outward normal. Thrust costs level^2 * 1000 / 49 micro-points per tick, so full throttle for a whole episode costs 6.912 points and a policy that sprints everywhere loses to one that coasts.

SENSING
Sixteen sensors reaching 2.40 m. A plankton or poison particle is detected iff the distance between CENTRES is at most 2.40 m — nothing hides between rays. The other three skimmers are detected at ANY range (the pod shares a transponder), because capture needs two bodies on one particle at one instant with no communication channel of any kind. A partner beyond 2.40 m occupies no ray.

SCORING
  capture (2+ skimmers on one plankton, same tick)  +10.000
  nibble  (1 skimmer alone on a plankton)            +0.050, re-armed only
                                                     after 0.60 m of separation
  poison hit  -2.000, plus a 0.5 s stun and half your speed
  thrust      -level^2 * 0.000001 * 1000/49 per tick
One score, computed once, copied into all four seats.

ENDINGS
  complete/target_met  20 captures reached
  complete/full_time   1728 ticks played
  deadline/wall_clock  the engine's 660 s stop tripped first (declared
                       acceptable: the hosted LLM was slow, not broken)
  fault/sim_fault      an invariant guard tripped; partial replay written
  fault/host_error     an unexpected server-side exception

A seat that never connects does NOT end the episode: the no-show is reported, its skimmer plays the `shoal` baseline for the whole run, and three skimmers can still capture.

DETERMINISM
The whole sim runs in INTEGERS (micrometres, µm/tick, micro-points) with a committed 32-entry unit-vector table and one integer square root. Replays are re-simulated by the emscripten/wasm32 build of the same module the native server ran, and their per-tick gameHash chains must match bit for bit — integers make that true by construction rather than by an argument about two builds of libm agreeing.

---

WHAT YOU CONTROL

Every 3 seconds you set ONE order for the next 3 seconds. You choose WHAT to go for and HOW hard; a deterministic autopilot does the steering 24 times a second, leads a moving target, swings around poison and never drives into the rock.

  mode hunt    drive at the plankton in `target` (or, if you cannot sense it,
               the nearest plankton you CAN sense; if none, the waypoint),
               aiming where it will be in `lead_ticks`
  mode escort  drive to the skimmer in `partner`, stopping 0.80 m short —
               unless you sense plankton within 1.50 m of that partner, in
               which case you go to the plankton instead. THIS is how two
               skimmers arrive together
  mode sweep   drive to `waypoint` and park there. Searching
  mode hold    brake to a stop where you are. Waiting on a partner
  mode avoid   run from the nearest poison you sense (tank centre if none)

  target      "F1".."F5" or "none" — a plankton you have SENSED. Naming one
              you cannot sense is the same as "none"
  partner     "SKIM-1".."SKIM-4" or "none". Your own alias is "none"
  waypoint    [x, y] in metres from the bottom-left corner
  lead_ticks  0..24 (24 ticks = 1 second)
  standoff_m  0.0..2.5 — how wide the autopilot swings around poison. 0
              ignores it; above 2.0 it will not close on food
  throttle    0.0..1.0 of full speed. Thrust costs points
  note        <=160 runes of your reasoning, for the spectator feed
  say         <=48 runes, spectators only. No skimmer ever sees it

WHAT WINS

A catch needs TWO skimmers on one plankton in the SAME TICK. One skimmer alone on plankton earns +0.05 once and then nothing until it has moved 0.60 m away — sitting on food alone is not a strategy, it is a signal. So the whole game is rendezvous: sense something, decide who else can reach it in three seconds, and be there at the same moment as somebody who cannot hear you. `escort` exists precisely for that: it converges two skimmers to a point 0.80 m apart and then, the instant either of them smells plankton near the other, sends both to the plankton.

Poison costs -2 and half a second of no thrust. -2 is twenty nibbles; it is worth a wide standoff when you are not closing on anything. Thrust is small but real: 6.912 points if you hold full throttle for the whole run, which is most of a catch.

EVERYONE GETS THE SAME SCORE, including the two seats you did not choose and cannot talk to. The ladder ranks you by the mean of those shared scores, so a policy that only works alongside its own twin is exactly the policy the cross-play mean exposes.

---

See `game.protocols.player` for the seat channel and `game.protocols.global` for the spectator channel and the replay layout. In short: a seat registers with one chat frame, receives one sensor-filtered Sprite v1 frame per tick, sends NO inputs, and answers one JSON intent per 72-tick turn. The server computes every per-tick thrust byte, records it, and the static wasm viewer re-derives the whole episode from the seed plus those bytes, checking one gameHash per tick.

The replay is the binary `COWLDWWD` format. `tools/replay_summary.py <file>` prints a strict-UTF-8 JSON summary — protocol, gameVersion, seed, names, aliases, skimmers, policyKinds, tickCount, intents, fallbacks and the full results document — using only the Python 3 standard library, which is how a production replay is read without Nim or Docker.
