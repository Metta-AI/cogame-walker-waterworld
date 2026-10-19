"""Run complete published Walker Waterworld games through four players and native HTTP."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

from replay_summary import Reader, load


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--variant", choices=("default", "sprint"), default="default")
    parser.add_argument("--wording", default="canonical")
    parser.add_argument("--mode", choices=("accepted", "retry", "fallback"), default="accepted")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    config = next(v["game_config"] for v in manifest["variants"] if v["id"] == args.variant)
    config.update(
        seed=7,
        promptVariant=args.wording,
        promptSeed=4,
        tokens=[f"t{i}" for i in range(4)],
        players=[{"name": f"policy-{i}"} for i in range(4)],
    )
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    (output / "config.json").write_text(json.dumps(config))
    requests, counts = {}, {}
    lock = threading.Lock()

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, format, *arguments):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seat = int(self.headers["X-Coworld-Player-Slot"])
            user = body["messages"][0]["content"]
            view, _ = json.JSONDecoder().raw_decode(user[user.index("{") :])
            stage = view["turn"]
            with lock:
                key = (stage, seat)
                counts[key] = counts.get(key, 0) + 1
                attempt = counts[key]
            call_id = str(uuid5(NAMESPACE_URL, f"waterworld-{stage}-{seat}-{attempt}"))
            proposal = {
                "mode": "hunt",
                "target": "F999",
                "partner": view["partners"][0]["alias"],
                "waypoint": [3.1234567, 4.2345678],
                "lead_ticks": 12,
                "standoff_m": 2.3001,
                "throttle": 0.701234,
                "note": "fixture café 🌱 " * 100,
                "say": "spectator café 🌱 " * 100,
            }
            text = json.dumps(proposal)
            if args.mode == "retry" and attempt == 1:
                text = "invalid fixture response"
            status = 429 if args.mode == "fallback" else 200
            response = {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}
            if status == 429:
                response = {"error": {"type": "rate_limit_error", "message": "fixture throttle"}}
            raw = json.dumps(response).encode()
            with lock:
                requests[call_id] = {"seat": seat, "body": body, "raw": raw.decode(), "status": status}
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("X-Coworld-Call-Id", call_id)
            self.end_headers()
            self.wfile.write(raw)

    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    env = os.environ.copy()
    for key in (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_API_KEY_URI",
        "AWS_BEARER_TOKEN_BEDROCK",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
        "PLAYER_SCRIPTED",
    ):
        env.pop(key, None)
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(output / "config.json").as_uri(),
        COGAME_RESULTS_URI=(output / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(output / "replay.bin").as_uri(),
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{provider.server_port}",
        COWORLD_LLM_MODEL="fixture/validation",
        WATERWORLD_HOST_TRACE_PATH=str(output / "host.jsonl"),
        WATERWORLD_SOURCE_REVISION=revision,
    )
    processes, logs = [], []
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        game = subprocess.Popen([str(args.game.resolve())], cwd=root, env=env, stdout=log, stderr=log)
        processes.append(game)
        for _ in range(400):
            assert game.poll() is None
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise RuntimeError("host did not start")
        for seat in range(4):
            player_env = dict(
                env,
                PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Maximize your score.",
                COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
            )
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen([str(args.player.resolve())], cwd=root, env=player_env, stdout=log, stderr=log)
            )
        timeout = config["wallClockBudgetSeconds"]
        assert game.wait(timeout=timeout + 30) == 0
        for player in processes[1:]:
            assert player.wait(timeout=20) == 0
        result = json.loads((output / "results.json").read_text())
        assert result["reason"] == "complete"
        trace = output / "host.jsonl"
        records = [json.loads(line) for line in trace.read_text().splitlines()]
        assert trace.stat().st_mode & 0o777 == 0o600
        assert records[0]["source_revision"] == revision and records[-1]["results"] == result
        decisions = [r for r in records if r["event_type"] == "host_decision"]
        assert decisions and len(decisions) % 4 == 0
        assert len(decisions) <= config["maxTicks"] // config["turnTicks"] * 4
        replay_bytes = load(str(output / "replay.bin"))
        reader = Reader(replay_bytes)
        assert reader.take(8) == b"COWLDWWD" and reader.u16() == 1
        reader.string()
        reader.string()
        reader.u64()
        reader.string()
        replay_intents = []
        while reader.left():
            kind = reader.u8()
            if kind == 1:
                reader.u32()
                reader.u64()
            elif kind == 2:
                reader.u32()
                reader.u8()
                reader.u8()
            elif kind == 3:
                reader.u32()
                reader.u8()
                reader.string()
                reader.i16()
                reader.string()
            elif kind == 4:
                reader.u32()
                reader.u8()
            elif kind == 5:
                reader.u32()
                reader.u8()
                message = reader.string()
                if message.startswith("{"):
                    item = json.loads(message)
                    if item["k"] == "intent":
                        replay_intents.append(item)
            elif kind == 6:
                reader.u32()
                reader.u8()
                reader.take(reader.u32())
            else:
                raise AssertionError(("unknown replay record", kind))
        assert replay_intents == [r["replay_record"] for r in decisions]
        used = set()
        turns = {}
        for row in decisions:
            view = dict(row["observation"])
            metadata = view.pop("prompt_template")
            assert metadata["variant"] == ("reordered" if args.wording == "mixed" else args.wording)
            assert not {"seed", "perm", "note", "say"} & view.keys()
            assert len(view["partners"]) == 3
            for detection in view["food_detected"] + view["poison_detected"]:
                assert detection["d"] <= view["you"]["sensor_range_m"]
            public = (view["clock"], view["pod"], view["rules"])
            turns.setdefault(row["turn"], public)
            assert turns[row["turn"]] == public
            assert len(row["attempts"]) == (2 if args.mode == "retry" else 1)
            for index, attempt in enumerate(row["attempts"]):
                headers = {k.lower(): v for k, v in attempt["response_headers"].items()}
                call_id = headers["x-coworld-call-id"]
                assert call_id not in used
                used.add(call_id)
                receipt = requests[call_id]
                assert receipt["body"] == attempt["request"]["body"] and receipt["seat"] == row["seat"]
                assert receipt["raw"] == attempt["raw_response"] and receipt["status"] == attempt["http_status"]
                assert attempt["prompt"][0]["content"] == receipt["body"]["system"]
                assert attempt["prompt"][1:] == receipt["body"]["messages"]
                for message in attempt["prompt"]:
                    assert (
                        attempt["prompt_configuration"][message["role"] + "_sha256"]
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                if index == 0:
                    assert attempt["prompt_configuration"] == metadata
                user = attempt["prompt"][1]["content"]
                delivered, _ = json.JSONDecoder().raw_decode(user[user.index("{") :])
                assert delivered == view
                for seat in range(4):
                    assert (f"PRIVATE-STRATEGY-{seat}:" in user) == (seat == row["seat"])
                assert "fixture café" not in user and "spectator café" not in user and "policy-" not in user
                assert attempt["accepted"] == (args.mode == "accepted" or args.mode == "retry" and index == 1)
            if args.mode == "fallback":
                assert row["action_origin"] == "fallback" and not row["selected_attempt_id"]
            else:
                assert row["action_origin"] == "llm" and row["selected_attempt_id"] == row["attempts"][-1]["attempt_id"]
                assert row["executed_action"] == row["attempts"][-1]["parsed_action"]
                action, installed = row["executed_action"], row["installed_record"]
                assert action["target"] == "none"
                assert len(action["note"]) <= 160 and len(action["say"]) <= 48
                assert installed["waypoint"] == [3123456, 3765432]
                assert installed["standoff_m"] == 2300 and installed["throttle"] == 178
                assert action["waypoint"] == [3.1234565, 4.2345675]
                assert action["note"].startswith(row["replay_record"]["note"])
        assert used == requests.keys()
        assert b"PRIVATE-STRATEGY-" not in replay_bytes
        (output / "requests.json").write_text(json.dumps(requests) + "\n")
        (output / "proof.json").write_text(
            json.dumps(
                {
                    "source_revision": revision,
                    "variant": args.variant,
                    "wording": args.wording,
                    "mode": args.mode,
                    "decisions": len(decisions),
                    "http_requests": len(requests),
                }
            )
        )
        print(output.name, len(decisions), "decisions;", len(requests), "HTTP requests; PASS", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        for log in logs:
            log.close()
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=10)


if __name__ == "__main__":
    main()
