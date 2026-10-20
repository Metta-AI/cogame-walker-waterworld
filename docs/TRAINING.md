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

The walker-waterworld-rules-v2 bank has five training briefings (canonical,
plain, numbered, questions, reordered) and two evaluation-only briefings
(heldout-briefing, heldout-reference). They vary the explanation and ordering of
the setting, rewards, sensing, communication and control loop. The JSON action
schema stays identical. Canonical preserves the default game's original bytes;
all wordings take the catch target from configuration (20 default, 14 sprint),
correcting the original prompt's hard-coded 20. Game mechanics,
operator guidance, action parsing and published budgets remain fixed.

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

## Exporting a mixed corpus

The existing exporter writes `train.jsonl`, `validation.jsonl`, and `manifest.json`.
It accepts optional wording and prompt-seed arguments:

```sh
nim c -d:release --path:src -o:/tmp/waterworld-export tools/export_posttrain.nim
/tmp/waterworld-export /tmp/waterworld-default 10 1 default mixed 0
```

Mixed selection cycles independently within training and validation. Fixed
wordings keep the supplied prompt seed. Episode IDs include requested selection, resolved
wording, and prompt seed, so matched exports stay distinct.
Each manifest run records its bank, resolved wording and seed. The existing
split by game seed stays fixed across wordings; held-out wordings are rejected.
The exporter continues to produce scripted-teacher examples. These checks do
not establish improved learned play or resistance to training collapse.

## Validation

`tools/test_prompt_games.py BRIDGE --exporter EXPORTER` plays every wording
through complete default and sprint games, checks fixed action schemas and
identical scripted outcomes, rejects held-out training requests, and verifies
mixed corpus export. Existing numeric bridge, native runtime and replay tests
remain in place. No additional native trace protocol is required.
