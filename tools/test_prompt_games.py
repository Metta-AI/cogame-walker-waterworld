"""Play complete Walker Waterworld games through the production text bridge across wordings."""

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(binary: Path, variant: str, wording: str, prompt_seed: int, seed: int) -> str:
    process = subprocess.Popen(
        [
            str(binary),
            str(Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"),
            variant,
            "--language",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    assert process.stdin is not None and process.stdout is not None
    digest = hashlib.sha256()

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    def record(value: dict) -> None:
        digest.update(json.dumps(value, sort_keys=True).encode())

    try:
        observation = request(
            {
                "kind": "reset",
                "seed": str(seed),
                "players": 4,
                "variant": variant,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "validation",
            }
        )
        decisions = 0
        systems = {}
        while observation["kind"] == "decision":
            view = observation["semantic_view"]
            system, user = [m["content"] for m in observation["messages"]]
            assert f"{view['pod']['target']} catches" in system
            assert view.pop("prompt_template") == {
                "bank": "walker-waterworld-rules-v2",
                "selection": wording,
                "variant": WORDINGS[prompt_seed % 5] if wording == "mixed" else wording,
                "seed": prompt_seed,
                "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
            }
            seat = observation["seat"]
            if seat not in systems:
                systems[seat] = system
            assert system == systems[seat]
            # Rule wording may change throughout the briefing, but never the action contract.
            briefing, separator, schema = system.partition(
                "Reply with a single JSON object"
            )
            assert briefing and separator and schema
            observation["messages"][0]["content"] = separator + schema
            record(observation)
            assert (
                "PRIVATE OPERATOR NOTE" not in user and "SPECTATOR ONLY SAY" not in user
            )
            proposal = json.loads(request({"kind": "teacher"})["response"])
            proposal.update(note="PRIVATE OPERATOR NOTE", say="SPECTATOR ONLY SAY")
            result = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": "```json\n" + json.dumps(proposal) + "\n```",
                }
            )
            assert result["kind"] == "accepted"
            record(result["action"])
            observation = result["observation"]
            decisions += 1
            assert decisions <= 10000
        assert observation["kind"] == "terminal" and decisions > 0
        assert set(observation["scores"]) == {str(i) for i in range(4)}
        record(observation)
        return digest.hexdigest()
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=10) == 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--exporter", type=Path, required=True)
    args = parser.parse_args()
    for variant in ("default", "sprint"):
        for seed in (17,):
            reference = play(args.binary, variant, "canonical", 0, seed)
            for wording, prompt_seed in [(w, 0) for w in WORDINGS[1:]] + [("mixed", 4)]:
                assert (
                    play(args.binary, variant, wording, prompt_seed, seed) == reference
                )
        print(variant, "8 complete games PASS", flush=True)
    for wording in WORDINGS[-2:]:
        rejected = subprocess.run(
            [
                str(args.binary),
                str(
                    Path(__file__).resolve().parents[1]
                    / "coworld_manifest_template.json"
                ),
                "default",
                "--language",
            ],
            input=json.dumps(
                {
                    "kind": "reset",
                    "seed": "7",
                    "players": 4,
                    "promptVariant": wording,
                    "split": "train",
                }
            )
            + "\n",
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert (
            rejected.returncode != 0
            and "held-out wording cannot enter training" in rejected.stderr
        )
    print("16 complete games and held-out exclusion PASS", flush=True)
    with tempfile.TemporaryDirectory(prefix="waterworld-prompts-") as directory:
        destination = Path(directory) / "corpus"
        subprocess.run(
            [str(args.exporter), str(destination), "10", "1", "default", "mixed", "0"],
            check=True,
        )
        manifest = json.loads((destination / "manifest.json").read_text())
        assert len(manifest["runs"]) == 10
        assert [
            run["prompt_configuration"]["variant"] for run in manifest["runs"]
        ] == list(WORDINGS[:5]) * 2
        assert all(
            run["prompt_configuration"]["bank"] == "walker-waterworld-rules-v2"
            for run in manifest["runs"]
        )
        families = {}
        for split in ("train", "validation"):
            rows = [
                json.loads(line)
                for line in (destination / f"{split}.jsonl").read_text().splitlines()
            ]
            assert rows and len(rows) == manifest[f"{split}_examples"]
            families[split] = {row["seed"] for row in rows}
            assert all(row["completion"][0]["role"] == "assistant" for row in rows)
        assert families["train"].isdisjoint(families["validation"])
    print("10 complete export games and disjoint splits PASS", flush=True)


if __name__ == "__main__":
    main()
