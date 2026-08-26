# Wire protocol

See `game.protocols.player` for the seat channel and `game.protocols.global` for the spectator channel and the replay layout. In short: a seat registers with one chat frame, receives one sensor-filtered Sprite v1 frame per tick, sends NO inputs, and answers one JSON intent per 72-tick turn. The server computes every per-tick thrust byte, records it, and the static wasm viewer re-derives the whole episode from the seed plus those bytes, checking one gameHash per tick.

The replay is the binary `COWLDWWD` format. `tools/replay_summary.py <file>` prints a strict-UTF-8 JSON summary — protocol, gameVersion, seed, names, aliases, skimmers, policyKinds, tickCount, intents, fallbacks and the full results document — using only the Python 3 standard library, which is how a production replay is read without Nim or Docker.

## The player channel

WALKER-WATERWORLD PLAYER PROTOCOL

One seat drives one skimmer. The seat's websocket is ws://<game>/player?slot=<N>&token=<T>; a bad slot or token is refused with HTTP 403 before the upgrade.

REGISTRATION. A seat sends exactly ONE Sprite v1 chat message (0x81), its registration:
  {"type":"register","prompt":"<strategy text or empty>","scripted":"shoal"|"drifter"|null,"policy":"<free label>"}
A non-empty `prompt` makes the seat an LLM seat; `scripted` names a baseline; a seat that sends neither is `shoal`. `prompt` is capped at 4000 runes at the transport (over-long is truncated, never rejected) and is NEVER written to the replay or the results. The registration is re-sent on the first ~10 s of frames because joins are slot-sequential and a seat's index may not exist yet; the server holds an unappliable registration rather than dropping it.

FRAMES. Each seat receives one binary Sprite v1 frame per tick at 24 Hz, sensor-filtered by the same predicate the sensor frame uses: the tank, the rock, its own skimmer with its sixteen rays, the other three skimmers (the pod shares a transponder, so partners are visible at any range), and plankton/poison ONLY while their centres are within 2.40 m of this skimmer's centre. Everything else is dark. Board labels carry only SKIM-1..SKIM-4; a seat never receives a real policy name on any channel.

SEATS SEND NO INPUTS. Every per-tick thrust byte is computed server-side by the deterministic controller from the seat's standing intent, and that byte is what the replay records. An input mask arriving on a player socket is discarded. A seat sends the Sprite v1 Ready packet (0x85) after each received frame so a fastMode server can advance the tick.

THE DECISION. Every 72 ticks (3.0 s) the GAME server composes this seat's sensor frame as JSON and asks the seat's LLM policy for ONE intent. All four seats' calls go out as one parallel batch per turn. Coordinates in that JSON are metres from the tank's bottom-left corner, x right, y up; bearings are degrees counter-clockwise from east; everything is rounded to 2 decimals. The reply must be a single JSON object beginning with '{':
  {"note":"<=160 runes","mode":"hunt"|"escort"|"sweep"|"hold"|"avoid","target":"F1".."F5"|"none","partner":"SKIM-1".."SKIM-4"|"none","waypoint":[x,y],"lead_ticks":0..24,"standoff_m":0.0..2.5,"throttle":0.0..1.0,"say":"<=48 runes"}
Parsing is tolerant (markdown fences, prose prefixes, numeric strings, percentages for throttle, centimetres for standoff_m and the waypoint, {"x":..,"y":..} waypoints, case-insensitive enums) and every out-of-range field is REPAIRED, not rejected: an unknown mode keeps last turn's, an undetected target becomes `none`, a self partner becomes `none`, a bad waypoint keeps last turn's. Two consecutive failures for a seat mean the `shoal` intent for that turn plus a `fallback` record. Every recorded string is truncated on RUNE boundaries, never bytes.

NOBODY CAN TALK. `say` and `note` are one-way to the spectator feed; no skimmer ever sees either, and there is no inter-seat channel of any kind.

## The global / spectator channel

WALKER-WATERWORLD GLOBAL/SPECTATOR PROTOCOL

/global (websocket) streams the spectator board as Sprite v1 binary frames: one map layer at 2400x1600 (the 1200x800 logical tank at RenderScale 2), the tiled water and rim as static-band objects, then per frame the rock, the four skimmer hulls with thruster plumes that read the command byte, ALL SIXTEEN SENSOR RAYS PER SKIMMER coloured by what each ray found, the plankton and poison blooms, capture/nibble rings, score pops and the speech bubbles in a reserved band at the top of the tank. The spectator board is PERFECT INFORMATION; the per-seat stream is sensor-filtered.

The chrome rides the SAME binary channel, as the label of a reserved never-drawn 1x1 sprite (id 4090) — the only channel that survives a hosted replay. Its payload is one JSON object per frame: the starter's keys (t, mt, ph, lob, pl, sp, mx, st, lp, sk, ff, en, mm, bs, pov, teams, roster, events, lead, beats, lulls, over, hold) plus `turn`, `turns`, `turnTicks`, `intents` and `ww`. `teams` has exactly one key, `pod`, carrying score/captures/target/nibbles/poison/thrust. `roster` is spectator-side and carries the REAL policy names, the anonymous alias, the skimmer index and the per-seat counters. `ww` carries the tank geometry, the four skimmers with their rays, the particles, the reward decomposition and the live speech bubbles.

REPLAY BYTES (`COWLDWWD`): magic + format version + game name/version + timestamp + the RESOLVED config JSON (seed, perm, num_agents, the whole geometry and physics table, the reward constants, the SEEDED INITIAL PARTICLE TABLE, players[].name with the real names, slots[].alias), then the record stream — joins/leaves, the ACTION LOG (one command byte per skimmer per tick, written on change only), chat records (`register`, `intent`, `fallback`, `budget_guard`, `result`) and ONE gameHash per tick. Everything the viewer needs is in the bytes: it re-simulates the episode from the seed and the recorded bytes and compares its own gameHash against the recorded one every tick, so one divergent bit is caught at the tick it happens.

The replay viewer is a STATIC wasm bundle (`game.replay_viewer.bundle = static-replay-viewer`), never a pod: the same src/waterworld/sim.nim compiles to wasm32 under emscripten and re-derives every frame in the browser. `tools/replay_summary.py` (Python 3 stdlib only) prints a strict-UTF-8 JSON summary of any replay file for forensics.
