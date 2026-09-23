"""Play both certified Waterworld variants through the numeric protocol."""

import json
import random
import subprocess
import sys
from pathlib import Path


MANIFEST = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"


def run(binary: Path, variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(binary), str(MANIFEST), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"waterworld-{variant}-{teacher}", "players": 4})
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == observation["decision_id"]
            widths.add(len(encoding["values"]))
            heads = encoding["action_heads"]
            assert [len(head["choices"]) for head in heads] == [5, 6, 5, 1201, 801, 25, 251, 256]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == head["choices"]
            view = observation["semantic_view"]
            assert "seed" not in view and "your_last_intent" in view
            assert len(view["sensors"]) == 16
            assert len(view["food_detected"]) <= 5
            assert len(view["poison_detected"]) <= 8
            assert len(view["partners"]) == 3
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {head["name"]: rng.choice(head["choices"]) for head in heads}
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 100
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {str(i) for i in range(4)}
        assert len(set(observation["scores"].values())) == 1
        assert len(set(observation["utilities"].values())) == 1
        assert -1 <= observation["utilities"]["0"] <= 1
        assert len(widths) == 1
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


def check_simultaneous_views(binary: Path) -> None:
    next_views = []
    for mode in ("hunt", "hold"):
        process = subprocess.Popen(
            [str(binary), str(MANIFEST), "default"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert process.stdin is not None and process.stdout is not None

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        request({"kind": "reset", "seed": "waterworld-simultaneous", "players": 4})
        action = {"mode": mode, "target": "none", "partner": "none",
                  "waypoint_x_cm": 600, "waypoint_y_cm": 400, "lead_ticks": 6,
                  "standoff_cm": 120, "throttle255": 255}
        next_views.append(request(
            {"kind": "step", "decision_id": 0, "response": json.dumps(action)}
        )["observation"]["semantic_view"])
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0
    assert next_views[0] == next_views[1]


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    check_simultaneous_views(binary)
    for variant in ("default", "sprint"):
        for teacher in (True, False):
            run(binary, variant, teacher)
