## Tolerant parsing and repair, and the RUNE-boundary discipline that keeps a
## replay readable by a strict UTF-8 parser.

import std/[json, strutils, unicode]

import helpers
import waterworld/[sim, intents]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

proc parse(text: string, previous = defaultIntent(), have = false,
           own = 0): SkimmerIntent =
  parseIntent(extractJsonObject(text), previous, have, own)

block prosePrefixed:
  let intent = parse("""Sure! Here is my order:
{"note":"F2 is close","mode":"hunt","target":"F2","throttle":1.0}
Hope that helps.""")
  check("prose-prefixed JSON parses", intent.mode == mHunt)
  check("the target survives", intent.target == 1, $intent.target)
  check("throttle 1.0 is full", intent.throttle255 == 255, $intent.throttle255)

block fenced:
  let intent = parse("```json\n{\"mode\":\"escort\",\"partner\":\"SKIM-3\"}\n```")
  check("fenced JSON parses", intent.mode == mEscort)
  check("the partner alias resolves", intent.partner == 2, $intent.partner)

block percentageThrottle:
  let intent = parse("""{"mode":"sweep","throttle":70}""")
  check("an integer percentage throttle is divided by 100",
    intent.throttle255 >= 170 and intent.throttle255 <= 190, $intent.throttle255)

block centimetres:
  let intent = parse("""{"mode":"sweep","standoff_m":120,"waypoint":[300,200]}""")
  check("a centimetre standoff becomes 1.2 m", intent.standoffMm == 1200,
    $intent.standoffMm)
  check("a centimetre waypoint x becomes 3.00 m",
    abs(intent.waypointXUm - 3_000_000) < 20_000, $intent.waypointXUm)
  check("a centimetre waypoint y becomes view 2.00 m (sim 6.00 m)",
    abs(intent.waypointYUm - 6_000_000) < 20_000, $intent.waypointYUm)

block waypointObject:
  let intent = parse("""{"mode":"sweep","waypoint":{"x":9.0,"y":6.0}}""")
  check("an {x,y} waypoint parses",
    abs(intent.waypointXUm - 9_000_000) < 20_000, $intent.waypointXUm)
  check("view y is flipped into sim y",
    abs(intent.waypointYUm - 2_000_000) < 20_000, $intent.waypointYUm)

block targetSpellings:
  check("plankton F2 parses", parse("""{"target":"plankton F2"}""").target == 1)
  check("a bare number parses", parse("""{"target":"2"}""").target == 1)
  check("an integer target parses", parse("""{"target":3}""").target == 2)
  check("an out-of-set id is none", parse("""{"target":"F9"}""").target == -1)
  check("none is none", parse("""{"target":"none"}""").target == -1)

block unknownModeKeepsLast:
  var previous = defaultIntent()
  previous.mode = mEscort
  check("an unknown mode keeps last turn's",
    parse("""{"mode":"kamikaze"}""", previous, true).mode == mEscort)
  check("an unknown mode with no history is sweep",
    parse("""{"mode":"kamikaze"}""").mode == mSweep)

block selfPartnerIsNone:
  check("my own alias as partner is none",
    parse("""{"partner":"SKIM-2"}""", own = 1).partner == -1)
  check("another skimmer's alias resolves",
    parse("""{"partner":"SKIM-2"}""", own = 0).partner == 1)

block undetectedTarget:
  ## A target the seat cannot sense is `none` to the CONTROLLER, which then
  ## takes the nearest plankton it can actually sense. The parser keeps the id
  ## (it is in range); the controller's fallback is what makes it harmless.
  var sim = seatedSim()
  for f in 0 ..< FoodCount:
    sim.food[f].state = psRespawning
  let frame = sim.frameFor(0)
  check("an undetected plankton is not in the sensor frame",
    frame.foodDetection(1) < 0)

block nonFiniteAndAbsent:
  let intent = parse("""{"mode":"hunt","lead_ticks":"NaN","standoff_m":null,
    "throttle":"abc","waypoint":[null,null]}""")
  check("a non-finite lead falls back to 6", intent.leadTicks == 6,
    $intent.leadTicks)
  check("a null standoff falls back to 1.2 m", intent.standoffMm == 1200,
    $intent.standoffMm)
  check("an unparseable throttle falls back to full", intent.throttle255 == 255,
    $intent.throttle255)

block outOfRangeClamps:
  let intent = parse("""{"lead_ticks":9000,"standoff_m":50.0,"throttle":9.5,
    "waypoint":[-40.0,900.0]}""")
  check("lead_ticks clamps to 24", intent.leadTicks == 24, $intent.leadTicks)
  check("standoff clamps to 2.5 m", intent.standoffMm == MaxStandoffMm,
    $intent.standoffMm)
  check("throttle clamps to full", intent.throttle255 == 255, $intent.throttle255)
  check("the waypoint clamps into the tank",
    intent.waypointXUm >= WaypointMinUm and intent.waypointXUm <= WaypointMaxXUm and
      intent.waypointYUm >= WaypointMinUm and intent.waypointYUm <= WaypointMaxYUm,
    $intent.waypointXUm & "," & $intent.waypointYUm)

block noteCap:
  var long = ""
  for _ in 0 ..< 300:
    long.add("x")
  let intent = parse("""{"note":"""" & long & """"}""")
  check("a 300-character note is cut to 160 runes",
    intent.note.runeLen == MaxNoteRunes, $intent.note.runeLen)

block runeBoundaryEmoji:
  ## The scar this rule exists for: a `say` whose 48th and 49th characters are a
  ## 4-BYTE EMOJI. The cut must land on the RUNE boundary and the result must
  ## still round-trip through a strict UTF-8 JSON parser.
  var text = ""
  for _ in 0 ..< 47:
    text.add("a")
  text.add("\u{1F41F}")     ## 4-byte fish: rune 48
  text.add("\u{1F41F}")     ## rune 49, must be cut
  check("the input really is 49 runes", text.runeLen == 49, $text.runeLen)
  let truncated = text.truncateRunes(MaxSayRunes)
  check("truncation lands on 48 runes", truncated.runeLen == 48,
    $truncated.runeLen)
  check("truncation lands on a rune boundary (validates as UTF-8)",
    truncated.validateUtf8() == -1, $truncated.validateUtf8())
  let record = $(%*{"say": truncated})
  check("the truncated string round-trips through parseJson",
    parseJson(record){"say"}.getStr() == truncated)
  check("the serialized record is valid UTF-8", record.validateUtf8() == -1)
  # And through the full sanitiser, which is what actually reaches the replay.
  let sanitized = sanitizeSay(text)
  check("sanitizeSay never emits a partial codepoint",
    sanitized.validateUtf8() == -1)
  check("sanitizeSay strips a leading brace",
    not sanitizeSay("{oops").startsWith("{"))
  let mixed = sanitizeSay("hold \u{1F41F} it")
  check("sanitizeSay drops non-ASCII whole, never half a codepoint",
    mixed.validateUtf8() == -1 and "\u{1F41F}" notin mixed, mixed)

block noUsableField:
  var raised = false
  try:
    discard parse("""{"unrelated":1}""")
  except IntentError:
    raised = true
  check("a reply with no usable field raises", raised)
  var raisedNoJson = false
  try:
    discard parse("I would rather not.")
  except IntentError:
    raisedNoJson = true
  check("a reply with no JSON object at all raises", raisedNoJson)

block recordCaps:
  var intent = defaultIntent()
  var long = ""
  for _ in 0 ..< 400:
    long.add("n")
  intent.note = long
  intent.say = long
  let record = intent.boundedIntentRecord(9, 2, 3)
  check("the serialized intent record is <= 600 runes",
    record.runeLen <= MaxIntentRecordRunes, $record.runeLen)
  check("the bounded record is still valid JSON",
    parseJson(record){"k"}.getStr() == "intent")
  let registered = registerRecord(0, 2, long, "llm", "shoal")
  check("register.policy is capped at 48 runes",
    parseJson(registered){"policy"}.getStr().runeLen == MaxPolicyLabelRunes)
  let fallback = fallbackRecord(3, 1, 2, "timeout", long)
  check("fallback.detail is capped at 200 runes",
    parseJson(fallback){"detail"}.getStr().runeLen == MaxFallbackDetailRunes)

if failures > 0:
  quit("test_intents: " & $failures & " failure(s)", 1)
echo "test_intents: ok"
