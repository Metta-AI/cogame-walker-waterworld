## The server contract: registration, the two name spaces, the client routes and
## the artifact writes. Everything here is exercised through the same functions
## the running server calls.

import std/[json, os, strutils]

import helpers
import waterworld/[sim, roster, sensors, intents, decide, llm, broadcast,
  server, wire_constants]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

block registrationParsing:
  ## THE SERVER'S OWN PARSER, imported from `waterworld/server` rather than
  ## re-declared here: a copy would pass while the shipped one drifted.
  ## Anything that is not the register object is not a registration, and a
  ## seat's chat is never written to the replay chat stream.
  let llmSeat = parseRegistration(
    """{"type":"register","prompt":"hunt in pairs","scripted":null,"policy":"tandemhunt"}""")
  check("an LLM registration parses", llmSeat.ok)
  check("its prompt is read", llmSeat.prompt == "hunt in pairs")
  check("its baseline is empty", llmSeat.scripted.len == 0)
  check("its label is read", llmSeat.policy == "tandemhunt")
  let scriptedSeat = parseRegistration(
    """{"type":"register","prompt":"","scripted":"drifter","policy":"drifter"}""")
  check("a scripted registration parses", scriptedSeat.ok)
  check("its baseline is read", parseBaseline(scriptedSeat.scripted) == blDrifter)
  check("a non-registration chat is dropped",
    not parseRegistration("""{"type":"taunt","text":"hi"}""").ok)
  check("plain text is dropped", not parseRegistration("hello").ok)
  check("malformed JSON is dropped", not parseRegistration("{oops").ok)
  # An over-long prompt is TRUNCATED at the transport, never rejected.
  var long = ""
  for _ in 0 ..< 5000:
    long.add("p")
  let capped = long.truncateRunes(MaxPromptRunes)
  check("a prompt over 4000 runes is truncated, not rejected",
    capped.len == MaxPromptRunes, $capped.len)

block tokenAdmission:
  var config = testConfig()
  check("the configured token admits its slot",
    config.playerJoinAllowed("alpha", 0, "t0"))
  check("a bad token is refused (the 403 path)",
    not config.playerJoinAllowed("alpha", 0, "wrong"))
  check("a slot beyond the pod is refused",
    not config.playerJoinAllowed("alpha", 9, "t0"))
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  check("joins are strictly slot-sequential", sim.nextPlayerSlot() == 0)
  var raised = false
  try:
    discard sim.addPlayer("alpha", 2, "t2")
  except WaterworldError:
    raised = true
  check("a join out of slot order is refused", raised)
  discard sim.addPlayer("alpha", 0, "t0")
  check("and the next open seat advances", sim.nextPlayerSlot() == 1)

block twoNameSpaces:
  ## IN-GAME every skimmer is SKIM-1..SKIM-4 and nothing else; real policy names
  ## live only in the replay config JSON, roster[].name, the DOM scorebug and
  ## results.names.
  var sim = seatedSim()
  for seat in 0 ..< SkimmerCount:
    sim.seatNames[seat] = "SECRET-POLICY-" & $seat
    sim.seatPolicyKind[seat] = "llm"
  var engine = initDecisionEngine(sim)
  for seat in 0 ..< SkimmerCount:
    engine.seats[seat].isLlm = true
    engine.seats[seat].prompt = "guidance"
  for seat in 0 ..< SkimmerCount:
    let
      frame = sim.frameFor(sim.skimmerForSeat(seat))
      message = userMessage(engine.seats[seat].prompt,
        engine.seatViewJson(sim, seat, 0, frame))
    for other in 0 ..< SkimmerCount:
      check("no real name reaches the composed LLM message",
        ("SECRET-POLICY-" & $other) notin message, "seat " & $seat)
    check("the seat is told its own ANONYMOUS alias",
      skimmerAlias(sim.skimmerForSeat(seat)) in message)
  # The chrome, by contrast, MUST carry them.
  let state = parseJson(sim.buildStateJson(newJArray(), true, 1.0, 720, false,
    true, -1))
  var namesInChrome = 0
  for row in state{"roster"}:
    if row{"name"}.getStr().startsWith("SECRET-POLICY-"):
      inc namesInChrome
    check("the chrome roster also carries the anonymous alias",
      row{"alias"}.getStr().startsWith("SKIM-"))
  check("the chrome roster carries all four real names", namesInChrome == 4,
    $namesInChrome)
  let results = parseJson(sim.playerResultsJson())
  var namesInResults = 0
  for name in results{"names"}:
    if name.getStr().startsWith("SECRET-POLICY-"):
      inc namesInResults
  check("results.names carries the real names", namesInResults == 4,
    $namesInResults)
  for alias in results{"aliases"}:
    check("results.aliases carries the in-game names",
      alias.getStr().startsWith("SKIM-"))

block chromeFrameShape:
  var sim = seatedSim()
  discard sim.runScripted(blShoal, ticks = 200)
  let state = parseJson(sim.buildStateJson(newJArray(), true, 2.0, 720, true,
    true, -1))
  for key in ["t", "mt", "ph", "lob", "pl", "sp", "mx", "st", "lp", "sk", "ff",
      "en", "mm", "bs", "pov", "teams", "roster", "events", "ww"]:
    check("the chrome frame carries the inherited key " & key, state.hasKey(key))
  check("there is exactly ONE team key", state{"teams"}.len == 1,
    $state{"teams"}.len)
  check("and it is the pod", state{"teams"}.hasKey("pod"))
  check("the board render scale is reported", state{"bs"}.getInt() == RenderScale)
  check("the tank block carries the sensor range",
    state{"ww"}{"tank"}{"sensorRange"}.getFloat() > 2.0)
  check("the tank block carries four skimmers",
    state{"ww"}{"skimmers"}.len == SkimmerCount)
  check("each skimmer carries sixteen rays",
    state{"ww"}{"skimmers"}[0]{"rays"}.len == SensorCount)
  check("the reward decomposition is present",
    state{"ww"}{"reward"}.hasKey("score"))

block wireConstants:
  ## chrome_common.js still reads window.CTF_WIRE (it is the starter's file plus
  ## the replay-transport patch), so it runs on its documented fallbacks. Those
  ## fallbacks must equal the engine: the integer PlaybackSpeeds, with the
  ## replay-only 0.5 (command '5') ahead of them.
  check("the wire block declares WATERWORLD_WIRE",
    WireConstantsJs.startsWith("window.WATERWORLD_WIRE={"), WireConstantsJs)
  check("it carries the playback speeds behind the 1/2x replay speed",
    "speeds:[0.5,1,2,3,4,8,16]" in WireConstantsJs, WireConstantsJs)
  check("it carries the fps", "fps:24" in WireConstantsJs)
  check("it carries the chrome sprite id", "chromeSpriteId:4090" in WireConstantsJs)
  let chrome = readRepoFile("client/chrome_common.js")
  check("chrome_common's speed fallback equals the wire block's speeds",
    "SPEEDS = WIRE.speeds || [0.5, 1, 2, 3, 4, 8, 16]" in chrome)
  check("chrome_common maps the 1/2x chip onto command '5'",
    "map = { 0.5: '5', 1: '1'" in chrome)
  check("chrome_common's fps fallback equals ReplayFps",
    "FPS = WIRE.fps || 24" in chrome)
  check("the splice marker survives in the served page",
    WireConstantsMarker in readRepoFile("client/replay_broadcast.html"))

block clientRoutesServeRealPages:
  ## The certifier probes /client/global and /client/player BEFORE starting the
  ## player pods, so both must serve a real page — and neither may open the
  ## player socket.
  let page = readRepoFile("client/replay_broadcast.html")
  check("the served page is a real document", page.startsWith("<!DOCTYPE html>"))
  check("it carries the board canvas", "id=\"board\"" in page)
  check("it carries the transport", "id=\"transport\"" in page)
  check("it never opens a player socket", "/player?" notin page)
  let server = readRepoFile("src/waterworld/server.nim")
  check("the /client/ routes are served before any catch-all",
    server.find("bitworldClient.GlobalClientRoute") <
      server.find("walker-waterworld server"))
  check("the shutdown grace is bounded",
    "ShutdownGraceSeconds = 20" in server)
  check("/healthz keeps answering through the grace",
    "HealthPath" in server)

block artifactWrites:
  ## The COGAME_* contract, through file:// URIs.
  let work = getTempDir() / "waterworld-test-artifacts"
  createDir(work)
  var sim = seatedSim(maxTicks = 240)
  discard sim.runScripted(blShoal)
  let resultsPath = work / "results.json"
  writeFile(resultsPath, sim.playerResultsJson() & "\n")
  check("results.json is written", fileExists(resultsPath))
  let parsed = parseJson(readFile(resultsPath))
  check("and parses as UTF-8 JSON", parsed.kind == JObject)
  check("with four names", parsed{"names"}.len == 4)
  removeDir(work)

if failures > 0:
  quit("test_server: " & $failures & " failure(s)", 1)
echo "test_server: ok"
