#!/usr/bin/env python3
"""Print a strict-UTF-8 JSON summary of one walker-waterworld `.replay` file.

    python3 tools/replay_summary.py /tmp/episode.replay

PYTHON 3 STANDARD LIBRARY ONLY — no Nim, no Docker, no pixie. This is how a
production replay is read: fetch the bytes from S3 and run this. It is also the
phase-60 substitute for the "replay bytes are valid UTF-8 JSON" definition-of-
done check, which cannot apply literally to a coworld whose replay is the
binary `COWLDWWD` format the static wasm viewer parses:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8: ok
    jq -r '.protocol, .results.reason, .results.endRule, .results.captures' /tmp/ep.json
    jq -r '[.intents[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json

The config JSON is recovered by BRACE-MATCHING from the first '{' rather than by
trusting a length prefix, so a truncated or partially-uploaded artifact still
yields whatever prefix it has instead of an exception. Every string is decoded
strictly as UTF-8: a replay that was truncated on a BYTE boundary mid-codepoint
fails here loudly, which is the whole point of the rune discipline upstream.
"""

from __future__ import annotations

import json
import struct
import sys
import zlib

MAGIC = b"COWLDWWD"
FORMAT_VERSION = 1

TICK_HASH = 0x01
INPUT = 0x02
JOIN = 0x03
LEAVE = 0x04
CHAT = 0x05
DEBUG_SPRITE = 0x06


class Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.at = 0

    def left(self) -> int:
        return len(self.data) - self.at

    def take(self, count: int) -> bytes:
        if count < 0 or self.at + count > len(self.data):
            raise EOFError(f"replay truncated at byte {self.at}")
        out = self.data[self.at:self.at + count]
        self.at += count
        return out

    def u8(self) -> int:
        return self.take(1)[0]

    def u16(self) -> int:
        return struct.unpack("<H", self.take(2))[0]

    def i16(self) -> int:
        return struct.unpack("<h", self.take(2))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def string(self) -> str:
        length = self.u16()
        # STRICT: a byte-truncated multi-byte character raises here rather than
        # rendering as a replacement glyph in one lenient viewer and failing
        # everywhere else.
        return self.take(length).decode("utf-8")


def brace_match(text: str) -> str:
    """The outermost balanced {...} starting at the first '{'."""
    start = text.find("{")
    if start < 0:
        return ""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def load(path: str) -> bytes:
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw.startswith(MAGIC):
        return raw
    # Hosted artifacts may arrive gzip- or zlib-compressed.
    for wbits in (47, 15):
        try:
            out = zlib.decompress(raw, wbits)
        except zlib.error:
            continue
        if out.startswith(MAGIC):
            return out
    raise SystemExit(f"{path}: not a {MAGIC.decode()} replay")


def summarize(path: str) -> dict:
    reader = Reader(load(path))
    if reader.take(len(MAGIC)) != MAGIC:
        raise SystemExit("replay magic does not match")
    version = reader.u16()
    if version != FORMAT_VERSION:
        raise SystemExit(f"unsupported replay format version {version}")
    game_name = reader.string()
    game_version = reader.string()
    reader.u64()                          # recorded-at, milliseconds
    config_text = reader.string()
    config = json.loads(brace_match(config_text) or "{}")

    joins: list[dict] = []
    intents: list[dict] = []
    registers: list[dict] = []
    fallbacks = 0
    budget_guards = 0
    results: dict = {}
    inputs = 0
    ticks = 0
    unique_bytes = set()

    while reader.left() > 0:
        try:
            kind = reader.u8()
            if kind == TICK_HASH:
                ticks = max(ticks, reader.u32())
                reader.u64()
            elif kind == INPUT:
                reader.u32()
                reader.u8()
                unique_bytes.add(reader.u8())
                inputs += 1
            elif kind == JOIN:
                reader.u32()
                player = reader.u8()
                name = reader.string()
                slot = reader.i16()
                reader.string()           # token, never reported
                joins.append({"player": player, "name": name, "slot": slot})
            elif kind == LEAVE:
                reader.u32()
                reader.u8()
            elif kind == CHAT:
                reader.u32()
                reader.u8()
                message = reader.string()
                if not message.startswith("{"):
                    continue
                try:
                    record = json.loads(message)
                except ValueError:
                    continue
                what = record.get("k")
                if what == "intent":
                    intents.append({
                        "turn": record.get("turn"),
                        "seat": record.get("seat"),
                        "alias": record.get("alias"),
                        "skimmer": record.get("skimmer"),
                        "source": record.get("source"),
                        "mode": record.get("mode"),
                        "target": record.get("target"),
                        "partner": record.get("partner"),
                        "say": record.get("say"),
                    })
                elif what == "register":
                    registers.append(record)
                elif what == "fallback":
                    fallbacks += 1
                elif what == "budget_guard":
                    budget_guards += 1
                elif what == "result":
                    results = record.get("results") or {}
            elif kind == DEBUG_SPRITE:
                reader.u32()
                reader.u8()
                reader.take(reader.u32())
            else:
                break
        except EOFError:
            break

    return {
        "protocol": f"{game_name}/v{FORMAT_VERSION}",
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "perm": config.get("perm"),
        "names": [join["name"] for join in joins],
        "aliases": results.get("aliases") or [
            reg.get("alias") for reg in sorted(
                registers, key=lambda r: r.get("seat", 0))
        ],
        "skimmers": results.get("skimmers") or [
            reg.get("skimmer") for reg in sorted(
                registers, key=lambda r: r.get("seat", 0))
        ],
        "policyKinds": results.get("policyKinds") or [
            reg.get("kind") for reg in sorted(
                registers, key=lambda r: r.get("seat", 0))
        ],
        "tickCount": ticks,
        "inputRecords": inputs,
        "distinctCommandBytes": len(unique_bytes),
        "intents": intents,
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "results": results,
    }


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <replay path>")
    summary = summarize(sys.argv[1])
    # ensure_ascii=False so the output really is UTF-8 and a non-ASCII `say`
    # exercises the decode path instead of being escaped away.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
