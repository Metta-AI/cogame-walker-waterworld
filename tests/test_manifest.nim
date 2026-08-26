## Manifest assertions. The certifier's validator is strict and its errors
## arrive two phases later, so every rule it enforces is pinned here.

import std/[json, os, sets, strutils, tables]

import helpers
import waterworld/[sim, sim_config]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

let m = manifest()
let game = m{"game"}

block topLevel:
  check("$schema is present", m.hasKey("$schema"))
  check("episode_timeout_minutes is 20",
    m{"episode_timeout_minutes"}.getInt() == 20)
  check("there are at least 3 top-level tags", m{"tags"}.len >= 3,
    $m{"tags"}.len)
  check("there is no top-level version", not m.hasKey("version"))

block gameBlock:
  check("game.name is walker-waterworld",
    game{"name"}.getStr() == "walker-waterworld", game{"name"}.getStr())
  check("game.description is present and a sentence",
    game{"description"}.getStr().len > 40, game{"description"}.getStr())
  check("game.tags does NOT exist (the validator forbids it)",
    not game.hasKey("tags"))
  check("game.owner is present", game{"owner"}.getStr().len > 0)
  check("there is no game.display_name", not game.hasKey("display_name"))
  check("game.runnable.type is game",
    game{"runnable"}{"type"}.getStr() == "game")
  check("the image placeholder is derived from the compose service name",
    game{"runnable"}{"image"}.getStr() == "{{WALKER_WATERWORLD_IMAGE}}",
    game{"runnable"}{"image"}.getStr())
  check("the game entrypoint is the one binary",
    game{"runnable"}{"run"}[0].getStr() == "/bin/walker-waterworld")
  check("source_url points at the public repo",
    game{"runnable"}{"source_url"}.getStr().startsWith(
      "https://github.com/Metta-AI/cogame-walker-waterworld"))

block secretNamespaceEqualsGameName:
  ## The namespace must equal game.name EXACTLY: upload 400s otherwise and
  ## certify cannot see it.
  let uri = game{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr()
  check("the game runnable receives the anthropic secret", uri.len > 0)
  check("the secret namespace equals game.name",
    uri == "secret://coworld/" & game{"name"}.getStr() & "/anthropic_api_key",
    uri)

block composeDerivation:
  let compose = readRepoFile("compose.yaml")
  check("compose declares exactly one service named for the coworld",
    "  walker-waterworld:" in compose)
  check("the compose image is coworld-walker-waterworld:latest",
    "image: coworld-walker-waterworld:latest" in compose)
  check("the platform is pinned", "platform: linux/amd64" in compose)
  check("the build context and network are declared",
    "context: ." in compose and "network: host" in compose)
  # The placeholder IS the service name, uppercased with '-' -> '_'.
  let derived = "{{" & "walker-waterworld".toUpperAscii().replace("-", "_") &
    "_IMAGE}}"
  check("the manifest placeholder is the derivation of the service name",
    game{"runnable"}{"image"}.getStr() == derived, derived)

block replayViewer:
  check("the replay viewer is the STATIC bundle, nested under game",
    game{"replay_viewer"}{"bundle"}.getStr() == "static-replay-viewer",
    game{"replay_viewer"}{"bundle"}.getStr())
  check("there is no top-level replay_viewer", not m.hasKey("replay_viewer"))

block configSchema:
  let schema = game{"config_schema"}
  check("config_schema is a real JSON Schema object",
    schema{"type"}.getStr() == "object")
  check("it forbids additional properties",
    not schema{"additionalProperties"}.getBool())
  check("tokens and players are required",
    schema{"required"}.len == 2)
  let props = schema{"properties"}
  check("num_agents is settable and bounded 1..4",
    props{"num_agents"}{"maximum"}.getInt() == 4)
  # EVERY array property must declare minItems AND maxItems.
  for key, prop in props:
    if prop{"type"}.getStr() == "array":
      check("array property " & key & " declares minItems",
        prop.hasKey("minItems"))
      check("array property " & key & " declares maxItems",
        prop.hasKey("maxItems"))
  # And the schema must cover every field sim_config.update reads: if a key is
  # not here it is not settable, and a manifest that sets it is silently ignored.
  let source = readRepoFile("src/waterworld/sim_config.nim")
  var declared = initHashSet[string]()
  for key, _ in props:
    declared.incl(key)
  for line in source.splitLines():
    let at = line.find("node.read")
    if at < 0:
      continue
    let quoteStart = line.find('"', at)
    if quoteStart < 0:
      continue
    let quoteEnd = line.find('"', quoteStart + 1)
    if quoteEnd < 0:
      continue
    let key = line[quoteStart + 1 ..< quoteEnd]
    check("config_schema covers the field sim_config.update reads: " & key,
      declared.contains(key), key)
  for key in ["tokens", "players", "slots"]:
    check("config_schema covers the roster field " & key,
      declared.contains(key))

block resultsSchemaMatchesTheDocument:
  ## The schema is additionalProperties:false and the certifier rejects any
  ## unknown field, so the two key sets must be IDENTICAL.
  var sim = seatedSim(maxTicks = 120)
  discard sim.runScripted(blShoal)
  let
    document = parseJson(sim.playerResultsJson())
    schema = game{"results_schema"}
    props = schema{"properties"}
  check("the results schema forbids additional properties",
    not schema{"additionalProperties"}.getBool())
  var documentKeys = initHashSet[string]()
  for key, _ in document:
    documentKeys.incl(key)
  var schemaKeys = initHashSet[string]()
  for key, _ in props:
    schemaKeys.incl(key)
  check("the document has 22 keys", documentKeys.len == 22, $documentKeys.len)
  for key in documentKeys:
    check("results_schema declares the document key " & key,
      schemaKeys.contains(key))
  for key in schemaKeys:
    check("playerResultsJson emits the schema key " & key,
      documentKeys.contains(key))
  for key in ["names", "scores", "win", "reason", "endRule", "sharedScore",
      "captures"]:
    var required = false
    for item in schema{"required"}:
      if item.getStr() == key:
        required = true
    check("results_schema requires " & key, required)
  check("reason is a closed enum of exactly three values",
    props{"reason"}{"enum"}.len == 3, $props{"reason"}{"enum"}.len)
  check("endRule is a closed enum of exactly five values",
    props{"endRule"}{"enum"}.len == 5, $props{"endRule"}{"enum"}.len)
  for key, prop in props:
    if prop{"type"}.getStr() == "array":
      check("per-seat array " & key & " is bounded minItems 4",
        prop{"minItems"}.getInt() == 4)
      check("per-seat array " & key & " is bounded maxItems 4",
        prop{"maxItems"}.getInt() == 4)

block protocols:
  check("game.protocols carries BOTH player and global",
    game{"protocols"}.hasKey("player") and game{"protocols"}.hasKey("global"))
  for which in ["player", "global"]:
    let node = game{"protocols"}{which}
    check("protocols." & which & " is a {type,value} object, not a bare string",
      node.kind == JObject and node{"type"}.getStr() == "text")
    check("protocols." & which & " is non-empty text",
      node{"value"}.getStr().len > 400, $node{"value"}.getStr().len)

block docs:
  let docs = game{"docs"}
  check("docs.readme is a {type,value} object",
    docs{"readme"}{"type"}.getStr() == "text")
  check("docs.readme is non-empty", docs{"readme"}{"value"}.getStr().len > 400)
  check("docs.pages has three entries", docs{"pages"}.len == 3,
    $docs{"pages"}.len)
  var ids: seq[string]
  for page in docs{"pages"}:
    check("every page has an id", page{"id"}.getStr().len > 0)
    check("every page has a title", page{"title"}.getStr().len > 0)
    check("every page's content is a {type,value} object",
      page{"content"}{"type"}.getStr() == "text")
    check("every page's content is non-empty text",
      page{"content"}{"value"}.getStr().len > 200,
      page{"id"}.getStr() & " " & $page{"content"}{"value"}.getStr().len)
    ids.add(page{"id"}.getStr())
  check("the three pages are rules, protocol and orders",
    "rules.md" in ids and "protocol.md" in ids and "orders.md" in ids,
    $ids)

block bundledPlayers:
  check("there is exactly one bundled player entry", m{"player"}.len == 1)
  let entry = m{"player"}[0]
  check("it has an id", entry{"id"}.getStr() == "baseline")
  check("it has type player", entry{"type"}.getStr() == "player")
  check("it has a name", entry{"name"}.getStr().len > 0)
  check("it has a description", entry{"description"}.getStr().len > 0)
  check("it runs the one player entrypoint",
    entry{"run"}[0].getStr() == "/bin/walker-waterworld-player")
  check("it is the shoal baseline",
    entry{"env"}{"PLAYER_SCRIPTED"}.getStr() == "shoal")
  check("its cpu limit is exactly \"1\" (below that is a 400 at upload)",
    entry{"resources"}{"limits"}{"cpu"}.getStr() == "1",
    entry{"resources"}{"limits"}{"cpu"}.getStr())
  check("its requests are the starter's",
    entry{"resources"}{"requests"}{"cpu"}.getStr() == "100m" and
      entry{"resources"}{"requests"}{"memory"}.getStr() == "64Mi")
  # EVERY declared player entry must occupy at least one certification slot.
  var seated = initHashSet[string]()
  for seat in m{"certification"}{"players"}:
    seated.incl(seat{"player_id"}.getStr())
  for declared in m{"player"}:
    check("declared player " & declared{"id"}.getStr() & " occupies a cert slot",
      seated.contains(declared{"id"}.getStr()))

block variants:
  check("there are two variants", m{"variants"}.len == 2, $m{"variants"}.len)
  var ids: seq[string]
  for variant in m{"variants"}:
    ids.add(variant{"id"}.getStr())
    check("every variant has a name", variant{"name"}.getStr().len > 0)
    check("every variant has a description (required)",
      variant{"description"}.getStr().len > 0, variant{"id"}.getStr())
    let config = variant{"game_config"}
    check("NUM_AGENTS IS 4 IN VARIANT " & variant{"id"}.getStr(),
      config{"num_agents"}.getInt() == 4, $config{"num_agents"}.getInt())
    check("it seats four players",
      config{"players"}.len == 4 and config{"slots"}.len == 4)
    check("fastMode is on", config{"fastMode"}.getBool())
    check("maxGames is 1", config{"maxGames"}.getInt() == 1)
    check("maxTicks is a whole number of turns",
      config{"maxTicks"}.getInt() mod config{"turnTicks"}.getInt() == 0,
      $config{"maxTicks"}.getInt() & " / " & $config{"turnTicks"}.getInt())
    check("attempt1Ms + retryMs fits inside turnBudgetMs",
      config{"attempt1Ms"}.getInt() + config{"retryMs"}.getInt() <=
        config{"turnBudgetMs"}.getInt())
    check("wallClockBudgetSeconds is inside 60 % of episodeTimeoutSeconds",
      config{"wallClockBudgetSeconds"}.getInt() <= 720,
      $config{"wallClockBudgetSeconds"}.getInt())
    # The whole-episode wall-clock arithmetic must fit the stop.
    let
      turns = config{"maxTicks"}.getInt() div config{"turnTicks"}.getInt()
      worst = (turns - 1) * config{"turnSpacingMs"}.getInt() div 1000 +
        config{"turnBudgetMs"}.getInt() div 1000 + 72 + 2 + 20 + 30
    check("the variant's worst case fits inside its own stop",
      worst < config{"wallClockBudgetSeconds"}.getInt(),
      $worst & " vs " & $config{"wallClockBudgetSeconds"}.getInt())
  check("the variants are default and sprint",
    "default" in ids and "sprint" in ids, $ids)
  check("sprint changes only the run length and the target, never the seats",
    m{"variants"}[1]{"game_config"}{"num_agents"}.getInt() ==
      m{"variants"}[0]{"game_config"}{"num_agents"}.getInt())

block certificationFixture:
  let cert = m{"certification"}
  let config = cert{"game_config"}
  check("NUM_AGENTS IS 4 IN THE CERTIFICATION FIXTURE",
    config{"num_agents"}.getInt() == 4, $config{"num_agents"}.getInt())
  check("certification.players names four seats", cert{"players"}.len == 4,
    $cert{"players"}.len)
  check("certification.game_config.players names four seats",
    config{"players"}.len == 4, $config{"players"}.len)
  check("every seat is the bundled baseline", (block:
    var all = true
    for seat in cert{"players"}:
      if seat{"player_id"}.getStr() != "baseline":
        all = false
    all))
  check("the fixture pins a seed", config{"seed"}.getInt() > 0)
  check("the fixture is 720 ticks = 30.0 s of playback, longer than the " &
    "12 s viewer soak", config{"maxTicks"}.getInt() == 720,
    $config{"maxTicks"}.getInt())
  check("the fixture pays no inter-batch floor offline",
    config{"turnSpacingMs"}.getInt() == 0)
  check("captureTarget stays 20 so the fixture cannot end early",
    config{"captureTarget"}.getInt() == 20)
  check("there are no runner-managed tokens in the cert fixture",
    not config.hasKey("tokens"))
  # 720 ticks at 24 Hz is 30 s of PLAYBACK; the fixture's own wall cost is
  # connect + ~1 s of physics + the shutdown grace, which is why the release
  # workflow passes --timeout-seconds 300 rather than shrinking the fixture.
  check("the release workflow gives certify a long enough timeout",
    "--timeout-seconds 300" in readRepoFile(
      ".github/workflows/coworld-release.yml"))

block smokeSeatCrossCheck:
  let smoke = readRepoFile("tools/ci/docker_smoke.sh")
  check("SMOKE_SEATS is substituted to 4",
    "seats_expected=\"${SMOKE_SEATS:-4}\"" in smoke)
  check("the smoke does not require a JSON replay (binary COWLDWWD)",
    "SMOKE_REQUIRE_REPLAY_JSON: \"0\"" in readRepoFile(
      ".github/workflows/ci.yml"))
  check("no unsubstituted placeholder survives in the smoke script",
    "<slug>" notin smoke and "<IMAGE>" notin smoke and "<SEATS>" notin smoke)

block policySet:
  let policies = parseJson(readRepoFile("tools/ci/policies.json"))
  check("there are four policies", policies.len == 4, $policies.len)
  var prompts = 0
  var scripted = 0
  for policy in policies:
    check("every policy runs the ONE player entrypoint",
      policy{"run"}.getStr() == "/bin/walker-waterworld-player",
      policy{"run"}.getStr())
    check("every policy name is namespaced to the game",
      policy{"name"}.getStr().startsWith("walker-waterworld-"),
      policy{"name"}.getStr())
    if policy{"env"}.hasKey("PLAYER_PROMPT"):
      inc prompts
      check("a champion's prompt is substantial",
        policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 400)
    if policy{"env"}.hasKey("PLAYER_SCRIPTED"):
      inc scripted
      check("a filler names a real baseline",
        policy{"env"}{"PLAYER_SCRIPTED"}.getStr() in ["shoal", "drifter"])
  check("there are exactly two LLM prompt champions", prompts == 2, $prompts)
  check("and two scripted fillers", scripted == 2, $scripted)
  check("the two champion prompts differ",
    policies[0]{"env"}{"PLAYER_PROMPT"}.getStr() !=
      policies[1]{"env"}{"PLAYER_PROMPT"}.getStr())
  check("champion #2 carries the daveey-1 player id",
    policies[1]{"player"}.getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
    policies[1]{"player"}.getStr())

if failures > 0:
  quit("test_manifest: " & $failures & " failure(s)", 1)
echo "test_manifest: ok"
