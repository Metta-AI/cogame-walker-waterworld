# Coworld training

The persistent numeric bridge runs the same four-seat native simulator, sensor
view, reply parser, and per-tick controller as the hosted game. It freezes all
four views before applying a turn's intents. Both certified variants are
supported. The eight action heads encode mode, target, partner, centimetre
waypoint coordinates, lead ticks, centimetre standoff, and throttle. The
observation has 317 fixed numeric features, with empty detection slots padded.
Every seat receives the shared score and bounded score/200 utility at the end.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/waterworld-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/waterworld-train-bridge
```

Run the bridge through `recipes.external.coworld_metta_rl.train` for Metta RL,
or `recipes.external.coworld.train` for native PufferLib. Pass the command
`[/tmp/waterworld-train-bridge, /path/to/coworld_manifest_template.json,
default]` or replace `default` with `sprint`, and set `players=4`. Always set
a finite timestep limit. The JSONL protocol exposes the production player
view for an Observatory consumer and a numeric encoding for training.

## Prompt diversity

The walker-waterworld-rules-v1 bank has five training introductions (canonical,
plain, numbered, questions, reordered) and two evaluation-only introductions
(heldout-briefing, heldout-reference). Only the opening description changes.
Canonical preserves the original bytes. Rules, sensors, scoring, operator guidance,
simultaneous turns, action parsing, and published budgets remain fixed.

Runtime config and bridge reset accept promptVariant and promptSeed. Mixed
selection requires an explicit nonnegative prompt seed and chooses one training
wording by modulo five. Selection remains fixed across all seats and turns,
outside simulation randomness and replay hashes. The default is canonical.
Held-out bridge selection requires split=validation.

Add --language to the bridge command to use native JSON extraction and tolerant
intent parsing. Responses report the installed fixed-point intent as a round-trip
language action. Spectator-only note/say fields never enter player observations.
Invalid local responses fail the bridge; native play retains its ordinary retry
and fallback behavior. Private semantic views carry prompt_template metadata
with bank, selection, variant, seed, and exact system/user SHA-256 hashes.

## Complete private candidates

Commit source before exporting. Use a fresh output directory outside the checkout.

```sh
nim c -d:release --path:src -o:/tmp/waterworld-export tools/export_posttrain.nim
/tmp/waterworld-export /tmp/waterworld-default 10 1 default mixed 4
/tmp/waterworld-export /tmp/waterworld-sprint 10 1 sprint plain
```

The optional final arguments select wording and its independent seed. Held-out
wordings are rejected before output creation. The exporter plays full published
games, freezes all four views before installing intents, and records exact
prompts, teacher proposals, installed actions, and all four terminal outcomes.
Private files use exclusive creation and owner-only permissions.

These are candidates, not admitted training rows. Import complete episodes
through the shared Coworld SDK, obtain independent review, and split by seed
family before exporting examples. All wordings and both variants for a game seed
share one family. No train/validation projections are written by this game.

## Private native capture

Set WATERWORLD_HOST_TRACE_PATH and WATERWORLD_SOURCE_REVISION to capture a private
host trace. It records actual request bodies, responses, status/headers, rejected
attempts, selected attempts, pre-turn private views, installed fixed-point
intents, replay records, and final outcomes before results trigger teardown.
It is separate from public spectator artifacts. Native fixture traffic verifies
the protocol; it is not real model inference or evidence of better learned play.

Historical smoke studies distilled the scripted shoal teacher into a 4096-token
model. They do not establish stronger league play or resistance to training
collapse. Matched model studies and production deployment remain separate from
deterministic preservation and local runtime checks.
