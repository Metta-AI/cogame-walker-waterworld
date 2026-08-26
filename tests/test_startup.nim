## Startup: a bad config fails cleanly, and the seed is randomised BEFORE
## config.update so every seed-derived draw follows the final seed.

import std/[json, os, strutils]

import helpers
import walker_waterworld
import waterworld/[sim, sim_config]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

block badConfigFailsCleanly:
  var config = defaultGameConfig()
  var message = ""
  try:
    config.update("this is not json")
  except WaterworldError as error:
    message = error.msg
  check("an unparseable config raises a clean, named error",
    message.startsWith("game config is not parseable JSON"), message)
  check("and the message carries no traceback", "\n" notin message.strip(),
    message)
  var arrayMessage = ""
  try:
    config.update("[1,2,3]")
  except WaterworldError as error:
    arrayMessage = error.msg
  check("a non-object config raises a clean error",
    arrayMessage == "game config must be a JSON object", arrayMessage)
  var typeMessage = ""
  try:
    config.update("""{"maxTicks":"soon"}""")
  except WaterworldError as error:
    typeMessage = error.msg
  check("a wrong-typed field raises rather than coercing",
    "maxTicks" in typeMessage, typeMessage)

block seedPinning:
  check("a config with no seed is unpinned", not seedPinned("""{"maxTicks":720}"""))
  check("the compiled-in default is the unpinned sentinel",
    not seedPinned("""{"seed":8821477}"""))
  check("any other seed is pinned", seedPinned("""{"seed":4242}"""))
  check("an empty config is unpinned", not seedPinned(""))
  let stripped = stripUnpinnedSeed("""{"seed":8821477,"maxTicks":720}""")
  check("the sentinel seed is stripped so it cannot clobber the random one",
    not parseJson(stripped).hasKey("seed"), stripped)
  check("and the rest of the config survives",
    parseJson(stripped){"maxTicks"}.getInt() == 720)

block seedOrderMatters:
  ## Randomise BEFORE parsing: config.update resolves nothing seed-derived
  ## itself, but initSimServer draws `perm`, the particle table and every
  ## respawn from config.seed, so a seed applied after the fact would give every
  ## process the same tank.
  var early = defaultGameConfig()
  early.seed = 1234
  early.update("""{"maxTicks":720}""")
  check("a seed set before update survives it", early.seed == 1234, $early.seed)
  var late = defaultGameConfig()
  late.update("""{"seed":9999,"maxTicks":720}""")
  check("a pinned seed is honoured", late.seed == 9999, $late.seed)
  let a = initSimServer(early)
  let b = initSimServer(late)
  check("two different seeds deal two different tanks",
    a.food[0] != b.food[0] or a.perm != b.perm)

block entrypoints:
  let dockerfile = readRepoFile("Dockerfile")
  check("the image builds the game binary",
    "--out:walker-waterworld \\" in dockerfile)
  check("the image builds the player binary",
    "--out:walker-waterworld-player \\" in dockerfile)
  check("both binaries land on PATH",
    "/bin/walker-waterworld" in dockerfile and
      "/bin/walker-waterworld-player" in dockerfile)
  check("the default command is the game",
    "CMD [\"/bin/walker-waterworld\"]" in dockerfile)
  check("the runtime stage carries data/ (the board art and the font)",
    "COPY --from=build /workspace/waterworld/data ./data" in dockerfile)
  check("ONE image serves both entrypoints (no second Dockerfile target)",
    dockerfile.count("FROM ") == 2, $dockerfile.count("FROM "))

if failures > 0:
  quit("test_startup: " & $failures & " failure(s)", 1)
echo "test_startup: ok"
