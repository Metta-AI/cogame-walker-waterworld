## The intent schema: what a skimmer's operator (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal field is repaired instead of
## rejected. Both policy kinds emit the SAME object, so the two are strictly
## comparable, one validator covers both, and a baseline is legal by
## construction.
##
## RUNE DISCIPLINE. Every cap here is measured in RUNES (Unicode codepoints) and
## every truncation lands on a rune boundary (`runeLen` / `runeSubStr`). Slicing
## a string by BYTE index anywhere on the path to the replay is forbidden: a
## byte-truncated multi-byte character renders fine in a browser and then fails a
## strict UTF-8 parser, which is exactly the class of bug that makes a replay
## unreadable to everything except the one viewer that happened to be lenient.
## `tests/test_intents.nim` pins it with a 4-byte emoji sitting on the boundary.

import std/[json, strutils, unicode]

import sim_types

type
  Mode* = enum
    ## What a skimmer is being told to go for, for the next turn. A CLOSED enum:
    ## an unrecognised mode keeps last turn's, else `sweep` — never nothing, so
    ## no skimmer is ever left uncommanded.
    mHunt = "hunt"
    mEscort = "escort"
    mSweep = "sweep"
    mHold = "hold"
    mAvoid = "avoid"

  IntentSource* = enum
    isLlm = "llm"
    isScripted = "scripted"
    isFallback = "fallback"

  SkimmerIntent* = object
    note*: string          ## <= MaxNoteRunes
    mode*: Mode
    target*: int32         ## plankton index, or -1 for "none"
    partner*: int32        ## skimmer index, or -1 for "none"
    waypointXUm*: int32    ## clamped into the tank, quantised to µm
    waypointYUm*: int32
    leadTicks*: int32      ## 0..24
    standoffMm*: int32     ## 0..2500, quantised to mm
    throttle255*: int32    ## 0..255
    say*: string           ## <= MaxSayRunes, sanitized
    source*: IntentSource
    latencyMs*: int32

  IntentError* = object of ValueError

const
  WaypointMinUm* = 300_000'i32
  WaypointMaxXUm* = ArenaW - 300_000'i32
  WaypointMaxYUm* = ArenaH - 300_000'i32
  MaxLeadTicks* = 24'i32
  MaxStandoffMm* = 2500'i32
  DefaultLeadTicks* = 6'i32
  DefaultStandoffMm* = 1200'i32
  DefaultThrottle255* = 255'i32

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single place
  ## any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A skimmer's spectator-side line: capped at MaxSayRunes on a rune boundary
  ## FIRST, then run through the printable-ASCII shout filter. In that order the
  ## rune cut never leaves half a codepoint for the ASCII filter to smear.
  ##
  ## Braces are excluded deliberately: the replay chat stream carries the
  ## control records as JSON objects and tells them from a skimmer's line by a
  ## leading '{', so a line that could start with one would make that
  ## discrimination ambiguous.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value < 127 and value != ord('{') and value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The operator's own reasoning line, as it reaches the replay and the match
  ## feed. Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc defaultIntent*(): SkimmerIntent =
  SkimmerIntent(
    note: "", mode: mSweep, target: -1, partner: -1,
    waypointXUm: ArenaW div 2'i32,
    waypointYUm: (ArenaH div 2'i32) - 1_600_000'i32,
    leadTicks: DefaultLeadTicks,
    standoffMm: DefaultStandoffMm,
    throttle255: DefaultThrottle255,
    say: "", source: isScripted, latencyMs: 0)

proc parseMode*(text: string, fallback: Mode): Mode =
  ## Tolerant: case-insensitive, hyphens and spaces normalised to underscores.
  ## Anything still unknown keeps the caller's fallback (last turn's mode, else
  ## `sweep`).
  let key = text.strip().toLowerAscii().replace("-", "_").replace(" ", "_")
  for mode in Mode:
    if $mode == key:
      return mode
  fallback

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown fences
  ## and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is what
  ## recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(IntentError,
      "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readNumber(node: JsonNode): tuple[ok: bool, value: float] =
  ## One numeric field: an int, a float, or a numeric string. Non-finite or
  ## unparseable reports `ok = false` so the caller applies its documented
  ## default rather than inventing a value.
  if node.isNil:
    return (false, 0.0)
  case node.kind
  of JInt:
    (true, float(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e12 or f < -1.0e12: (false, 0.0) else: (true, f)
  of JString:
    let raw = node.getStr().strip().strip(chars = {'%', ' '})
    try:
      let f = parseFloat(raw)
      if f != f: (false, 0.0) else: (true, f)
    except CatchableError:
      (false, 0.0)
  else:
    (false, 0.0)

proc parseTargetId*(text: string): int32 =
  ## `"F2"`, `"f2"`, `"plankton F2"`, `"2"` and `"none"` all parse. Anything
  ## outside F1..F5 is `none`, which makes the controller take the nearest
  ## plankton it can actually sense.
  let raw = text.strip().toLowerAscii()
  if raw.len == 0 or raw == "none" or raw == "null":
    return -1
  var digits = ""
  for ch in raw:
    if ch in {'0' .. '9'}:
      digits.add(ch)
  if digits.len == 0:
    return -1
  try:
    let value = parseInt(digits)
    if value >= 1 and value <= FoodCount:
      return int32(value - 1)
  except ValueError:
    discard
  -1

proc parsePartnerAlias*(text: string, ownSkimmer: int): int32 =
  ## `"SKIM-2"`, `"skim2"`, `"2"` and `"none"` all parse. My OWN alias is
  ## `none` — a skimmer cannot escort itself — and so is anything unrecognised.
  let raw = text.strip().toLowerAscii()
  if raw.len == 0 or raw == "none" or raw == "null":
    return -1
  var digits = ""
  for ch in raw:
    if ch in {'0' .. '9'}:
      digits.add(ch)
  if digits.len == 0:
    return -1
  try:
    let value = parseInt(digits)
    if value >= 1 and value <= SkimmerCount and value - 1 != ownSkimmer:
      return int32(value - 1)
  except ValueError:
    discard
  -1

proc parseIntent*(
  payload: JsonNode,
  previous: SkimmerIntent,
  havePrevious: bool,
  ownSkimmer: int
): SkimmerIntent =
  ## Turns one parsed reply into a legal intent, REPAIRING every field the
  ## schema bounds rather than rejecting the reply. Raises `IntentError` only
  ## when NO usable field can be recovered — the one condition the retry and
  ## then the scripted fallback exist for.
  ##
  ## Tolerances, all of them things models actually emit: markdown fences and
  ## prose (handled by `extractJsonObject`), numeric strings, an integer
  ## PERCENTAGE for `throttle` (divided by 100 above 1), CENTIMETRES for
  ## `standoff_m` and the waypoint (divided by 100 above 30), `waypoint` as
  ## `{"x":…,"y":…}` as well as `[x, y]`, and case-insensitive enums.
  if payload.isNil or payload.kind != JObject:
    raise newException(IntentError, "reply is not a JSON object")
  result = if havePrevious: previous else: defaultIntent()
  result.source = isLlm
  result.latencyMs = 0
  var usable = 0

  if payload.hasKey("note"):
    result.note = sanitizeNote(payload{"note"}.getStr())
    inc usable
  if payload.hasKey("say"):
    result.say = sanitizeSay(payload{"say"}.getStr())
    inc usable

  if payload.hasKey("mode"):
    let fallback = if havePrevious: previous.mode else: mSweep
    result.mode = parseMode(payload{"mode"}.getStr(), fallback)
    inc usable

  if payload.hasKey("target"):
    let node = payload{"target"}
    let text =
      if node.kind == JString: node.getStr().truncateRunes(4)
      elif node.kind == JInt: $node.getBiggestInt()
      else: "none"
    result.target = parseTargetId(text)
    inc usable

  if payload.hasKey("partner"):
    let node = payload{"partner"}
    let text =
      if node.kind == JString: node.getStr().truncateRunes(8)
      elif node.kind == JInt: $node.getBiggestInt()
      else: "none"
    result.partner = parsePartnerAlias(text, ownSkimmer)
    inc usable

  if payload.hasKey("waypoint"):
    let node = payload{"waypoint"}
    var
      rx = (ok: false, value: 0.0)
      ry = (ok: false, value: 0.0)
    if not node.isNil and node.kind == JArray and node.len >= 2:
      rx = readNumber(node[0])
      ry = readNumber(node[1])
    elif not node.isNil and node.kind == JObject:
      rx = readNumber(node{"x"})
      ry = readNumber(node{"y"})
    if rx.ok and ry.ok:
      var
        wx = rx.value
        wy = ry.value
      # Centimetres, not metres: nothing in a 12 x 8 m tank is at 350.
      if wx > 30.0 or wy > 30.0:
        wx = wx / 100.0
        wy = wy / 100.0
      # View metres (origin bottom-left, y up) -> sim µm (origin top-left, y down).
      result.waypointXUm = int32(clamp(wx * 1_000_000.0,
        float(WaypointMinUm), float(WaypointMaxXUm)))
      result.waypointYUm = int32(clamp(float(ArenaH) - wy * 1_000_000.0,
        float(WaypointMinUm), float(WaypointMaxYUm)))
      inc usable

  if payload.hasKey("lead_ticks"):
    let read = readNumber(payload{"lead_ticks"})
    result.leadTicks =
      if read.ok: int32(clamp(read.value + 0.5, 0.0, float(MaxLeadTicks)))
      else: DefaultLeadTicks
    inc usable

  if payload.hasKey("standoff_m"):
    let read = readNumber(payload{"standoff_m"})
    if read.ok:
      var metres = read.value
      if metres > 30.0:                     ## centimetres
        metres = metres / 100.0
      result.standoffMm = int32(clamp(metres * 1000.0, 0.0, float(MaxStandoffMm)))
    else:
      result.standoffMm = DefaultStandoffMm
    inc usable

  if payload.hasKey("throttle"):
    let read = readNumber(payload{"throttle"})
    if read.ok:
      var fraction = read.value
      if fraction > 1.0:                    ## an integer percentage
        fraction = fraction / 100.0
      result.throttle255 = int32(clamp(fraction * 255.0, 0.0, 255.0))
    else:
      result.throttle255 = DefaultThrottle255
    inc usable

  if usable == 0:
    raise newException(IntentError, "reply carried no usable intent field")

proc throttleFraction*(intent: SkimmerIntent): float {.inline.} =
  float(intent.throttle255) / 255.0

proc standoffMetres*(intent: SkimmerIntent): float {.inline.} =
  float(intent.standoffMm) / 1000.0

proc intentRecord*(
  intent: SkimmerIntent, turn, seat, skimmer: int
): JsonNode =
  ## The replay chat record for one turn's intent. Re-applied at playback into
  ## NON-HASHED sim fields only (the feed, the bubbles, the seat counters), so
  ## it can never affect the simulation.
  %*{
    "k": "intent",
    "turn": turn,
    "seat": seat,
    "alias": skimmerAlias(skimmer),
    "skimmer": skimmer,
    "source": $intent.source,
    "latency_ms": int(intent.latencyMs),
    "note": intent.note,
    "mode": $intent.mode,
    "target": (if intent.target >= 0: foodId(int(intent.target)) else: "none"),
    "partner": (if intent.partner >= 0: skimmerAlias(int(intent.partner))
                else: "none"),
    "waypoint": [int(intent.waypointXUm), int(intent.waypointYUm)],
    "lead_ticks": int(intent.leadTicks),
    "standoff_m": int(intent.standoffMm),
    "throttle": int(intent.throttle255),
    "say": intent.say
  }

proc boundedIntentRecord*(
  intent: SkimmerIntent, turn, seat, skimmer: int
): string =
  ## The serialized intent record, guaranteed <= MaxIntentRecordRunes. The note
  ## is the only unbounded-in-practice field, so it is the one that shrinks; the
  ## cut still lands on a rune boundary. NEVER cut the serialized string — that
  ## would emit broken JSON, the exact failure the rune rule exists to prevent.
  var trimmed = intent
  result = $trimmed.intentRecord(turn, seat, skimmer)
  var guard = 0
  while result.runeLen > MaxIntentRecordRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 2))
    result = $trimmed.intentRecord(turn, seat, skimmer)

proc registerRecord*(
  seat, skimmer: int, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's PROMPT is never written:
  ## only the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": skimmerAlias(skimmer),
    "skimmer": skimmer,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc fallbackRecord*(
  turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})
