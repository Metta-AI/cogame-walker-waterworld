# Agent operating guide — cogame-walker-waterworld

Gameplay rules live in [docs/RULES.md](docs/RULES.md); the wire is
[docs/PROTOCOL.md](docs/PROTOCOL.md); the design note this repo implements is
[docs/plans/2026-08-26-walker-waterworld-design.md](docs/plans/2026-08-26-walker-waterworld-design.md).
This file covers the things that are easy to get wrong.

## The determinism boundary is grep-enforced

`src/waterworld/{sim,tank,trig,sensors,sim_types,sim_config,sim_state}.nim`
contain **no floating point at all** — no `sin`, `cos`, `arctan2`, `sqrt`, `pow`,
`float`, `float32`, `float64` — and no draw outside `drawInt`.
`tests/test_determinism.nim` greps for all of it and fails on a hit.

Why: a replay is re-simulated by the **emscripten/wasm32** build of the same
module the **native amd64** server ran, and their per-tick `gameHash` chains must
match bit for bit. Integers make that true by construction. The same file also
carries the other half of the contract — Nim's `int` is 64-bit natively and
**32-bit under `--cpu:wasm32`**, so every stored field is an explicit `int32`,
`int64`, `uint8`, `bool` or `enum`, and every product of two sim quantities is
computed in `int64` and narrowed with an explicit truncating `div`.

Floats are legal in `control.nim`, `global.nim` and the results document,
because none of them enters `gameHash`: the controller's output is a RECORDED
BYTE, the board is pixels, and the results are the platform's, not the sim's.

## A GameVersion bump re-cuts every fixture

`GameVersion` in `sim_types.nim` gates replay compatibility, and its comment is a
**prepend-only** changelog: say what the number means and what it obsoletes.
`tools/ci/check_gameversion.sh` diffs the headline, not the digits, because the
number alone cannot distinguish two branches that both claimed it.

Bumping it invalidates `tests/data/golden_hashes.json`. Re-mint it with:

```bash
WATERWORLD_WRITE_GOLDEN=1 nim r --path:src tests/test_determinism.nim
```

## The chrome is the starter's, not a lookalike

`client/chrome_common.js` is `coworld-ctf`'s file **byte for byte** and
`tests/test_viewer.nim` pins its sha1. `client/replay_broadcast.html` is the
starter's page with the game block appended, and it is regenerated — not
hand-edited — by:

```bash
python3 scripts/fork_broadcast_page.py /path/to/coworld-ctf
```

That script asserts every cut boundary against the starter before touching
anything, so a starter bump fails loudly instead of producing a broken page. Edit
`scripts/waterworld_block.html` (the appended block) or the script's own
replacement constants, then re-run it. Never edit the generated page directly:
the next regeneration would silently drop your change.

## The board is Nim-side

Everything a spectator sees on the tank is baked and placed in
`src/waterworld/global.nim`; `broadcast_core.js` is a dumb compositor. Two
constraints there are load-bearing:

- **Wire budget.** A sprite definition rides one websocket message and the
  hosted replay closes any frame over 1 MiB, so the tank floor is ONE tiled
  400x400 sprite placed 24 times rather than a single 15 MB plate.
- **Static bands.** Every water/rim object sits in the compositor's static-band
  id range (40..99) at `z = -32768`, which is what lets it bake them into a
  cached base and never re-composite them.

Board art is read from `data/` and nowhere else: `data/` is the ONE directory the
emscripten build preloads (`replay-viewer/config.nims`:
`--preload-file data@data`), so a bake that read from `client/` would work
natively and throw in the browser.

## The link flags and the JS bootstrap are a matched pair

This bundle is the paintbot lineage: a **non-modularized** module plus
`Module.onRuntimeInitialized`. Do NOT add `-s MODULARIZE=1` / `-s EXPORT_NAME`
to `replay-viewer/config.nims` — a mixture throws nothing, logs nothing and
hangs on "Loading replay…" forever. `tests/test_viewer.nim` asserts both halves.

## Tests

`ci.yml` runs every `tests/*.nim` in debug AND release. Two are release-only
(the `NIM_TESTS_RELEASE_ONLY` repo variable): `tests/test_perf.nim` and
`tests/test_baselines.nim`, both of which play whole episodes.

The determinism gate (`tests/test_determinism.nim` plus the viewer smoke) is
inviolable: if it fails, the physics or a build flag changed — fix the code,
never the test.

If four `shoal`s stop capturing, the **three `BaselineParams` numbers** are
wrong, not the tank. Re-run the sweep and commit its pick:

```bash
nim c -d:release -r tools/tune_baselines.nim          # print the table
nim c -d:release -r tools/tune_baselines.nim --check  # verify the recorded pick
```

`tools/ci/baseline_tuning.json` records the winning cell and the panel it won
with; `tests/test_tuning.nim` asserts the shipped defaults still equal it.

## Reading a production replay

No Nim, no Docker:

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```
