# Metta post-training data

The native simulator and published `shoal` policy can export supervised
examples for both certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/waterworld-default 10 1 default
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/waterworld-sprint 10 1 sprint
```

Each run uses its published variant config and plays complete seeded,
four-seat games. The exporter records the hosted system prompt, each seat's
sensor-limited observation, and a baseline intent that round-trips through
the game's reply parser. Splits are by game seed. The manifest records source
revision, variant, scores, wins, and row counts. Existing output directories
are never overwritten.

Train either output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/waterworld-default \
  --output /tmp/waterworld-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

The local 10-game default export contained 656 train and 184 validation
examples, with 7/10 wins. Sprint contained 440 train and 128 validation
examples, with 6/10 wins. All 1,408 examples fit a 4096-token smoke model.
One CPU optimizer update reduced validation loss from 1.7444 to 1.7381 on
both variants. This distills a scripted teacher; it does not establish
stronger league play.
