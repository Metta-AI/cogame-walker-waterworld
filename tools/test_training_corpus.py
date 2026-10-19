"""Play complete private candidate exports and verify installed-action provenance."""

import argparse
import hashlib
import json
import stat
import subprocess
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="waterworld-training-"))
    families = []
    for variant in ("default", "sprint"):
        destination = root / variant
        subprocess.run([str(args.binary), str(destination), "10", "1", variant, "mixed", "4"], check=True)
        manifest = json.loads((destination / "manifest.json").read_text())
        assert len(manifest["runs"]) == 10
        assert not (destination / "train.jsonl").exists() and not (destination / "validation.jsonl").exists()
        for path in (destination, *destination.iterdir()):
            assert stat.S_IMODE(path.stat().st_mode) == (0o700 if path.is_dir() else 0o600)
        episode_families = set()
        decisions = []
        completed = 0
        for line in (destination / "trajectories.jsonl").read_text().splitlines():
            event = json.loads(line)
            assert event["source_revision"] == manifest["source_revision"]
            if event["event_type"] == "episode":
                assert event["status"] == "completed" and event["outcome"]["reason"] == "complete"
                assert set(event["participant_outcomes"]) == {"0", "1", "2", "3"}
                assert decisions and all(d["episode_id"] == event["episode_id"] for d in decisions)
                latest = {d["seat"]: d for d in decisions}
                assert set(latest) == {"0", "1", "2", "3"} and all(d["terminal"] for d in latest.values())
                assert len(decisions) == manifest["runs"][completed]["decisions"]
                episode_families.add(event["seed_family"])
                decisions = []
                completed += 1
                continue
            assert event["event_type"] == "decision" and event["visibility"] == "private"
            assert event["decision_index"] == len(decisions)
            assert event["action_status"] == "accepted"
            attempt = event["attempts"][0]
            assert attempt["attempt_id"] == event["selected_attempt_id"]
            assert attempt["origin"] == "teacher" and attempt["policy"] == "scripted-shoal"
            assert attempt["accepted"] and attempt["parsed_action"] == event["executed_action"]
            assert json.loads(attempt["response"]) == event["executed_action"]
            assert attempt["prompt"] == event["prompt"]
            assert attempt["request"] is None and attempt["platform_call_id"] is None
            assert attempt["behavior_logprobs"] is None
            system, user = [message["content"] for message in event["prompt"]]
            metadata = event["observation"]["prompt_template"]
            assert metadata == {
                **manifest["prompt_configuration"],
                "system_sha256": hashlib.sha256(system.encode()).hexdigest(),
                "user_sha256": hashlib.sha256(user.encode()).hexdigest(),
            }
            assert metadata["variant"] == "reordered"
            decisions.append(event)
        assert completed == 10 and not decisions
        families.append(episode_families)
        print(variant, "10 complete private candidate games PASS", flush=True)
    assert families[0] == families[1]
    for wording in ("heldout-briefing", "heldout-reference"):
        destination = root / wording
        result = subprocess.run(
            [str(args.binary), str(destination), "10", "1", "default", wording],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0 and "held-out wording" in result.stderr
        assert not destination.exists()
    print("Retained private proof:", root, flush=True)


if __name__ == "__main__":
    main()
