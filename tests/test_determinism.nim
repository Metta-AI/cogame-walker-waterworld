## THE DETERMINISM GATE. If this fails, the physics or a build flag changed —
## fix the code, never the test: the whole replay system rests on the native
## amd64 server and the emscripten/wasm32 browser build producing the SAME hash
## chain from the same seed and the same command bytes.

import std/[json, math, os, strutils]

import helpers
import waterworld/[sim, trig, tank]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

# (a) same seed + same command-byte log => identical hash at EVERY tick, twice
# in one process and once in a fresh sim.
block sameLogSameChain:
  var sim = seatedSim()
  let run = sim.runScripted(blShoal)
  check("the scripted run produced a full episode", run.ticks > 1000, $run.ticks)
  let second = replaySteps(testConfig(), run.cmdLog)
  check("a fresh sim re-simulating the byte log reproduces every hash",
    second == run.hashes,
    "first mismatch at " & (block:
      var at = -1
      for i in 0 ..< min(second.len, run.hashes.len):
        if second[i] != run.hashes[i]:
          at = i
          break
      $at))
  let third = replaySteps(testConfig(), run.cmdLog)
  check("re-simulating twice is identical", third == second)

# (b) a ONE-UNIT change in any command byte changes the final hash.
block oneBitMatters:
  var sim = seatedSim()
  let run = sim.runScripted(blShoal, ticks = 400)
  var mutated = run.cmdLog
  # Perturb a byte in the middle of the run on a skimmer that was thrusting.
  var touched = false
  for i in 200 ..< mutated.len:
    for s in 0 ..< SkimmerCount:
      if mutated[i][s] < 255'u8:
        mutated[i][s] = mutated[i][s] + 1'u8
        touched = true
        break
    if touched: break
  check("found a byte to perturb", touched)
  let perturbed = replaySteps(testConfig(), mutated)
  check("a one-unit command-byte change changes the chain",
    perturbed[^1] != run.hashes[^1])

# (c) The committed golden fixture pins the hash at every 48th tick. It is a
# regression pin on the sim, the controller AND the `shoal` baseline together,
# because the log it replays is the one that baseline produces: re-mint it with
# WATERWORLD_WRITE_GOLDEN=1 whenever any of the three legitimately changes, and
# never to make a red gate go green.
block golden:
  var sim = seatedSim()
  let run = sim.runScripted(blShoal)
  var actual = newJObject()
  var samples = newJArray()
  var tick = 0
  for i, hash in run.hashes:
    inc tick
    if tick mod 48 == 0:
      samples.add(%*{"tick": tick, "hash": $hash})
  actual["seed"] = %8_821_477
  actual["gameVersion"] = %GameVersion
  actual["samples"] = samples
  let path = repoRoot() / "tests" / "data" / "golden_hashes.json"
  if getEnv("WATERWORLD_WRITE_GOLDEN").len > 0:
    writeFile(path, actual.pretty() & "\n")
    echo "wrote ", path
  elif fileExists(path):
    let expected = parseJson(readFile(path))
    check("the golden fixture's GameVersion matches",
      expected{"gameVersion"}.getStr() == GameVersion,
      expected{"gameVersion"}.getStr() & " vs " & GameVersion)
    check("the golden fixture has the same number of samples",
      expected{"samples"}.len == samples.len,
      $expected{"samples"}.len & " vs " & $samples.len)
    var mismatch = -1
    for i in 0 ..< min(expected{"samples"}.len, samples.len):
      if expected{"samples"}[i] != samples[i]:
        mismatch = i
        break
    check("every 48th-tick hash matches the committed golden fixture",
      mismatch < 0,
      (if mismatch >= 0: $samples[mismatch] & " vs " &
        $expected{"samples"}[mismatch] else: ""))
  else:
    # No local Nim toolchain exists in the authoring sandbox, so the fixture is
    # minted by the FIRST CI run: the JSON is printed here and committed from
    # the log. After that this branch never runs again.
    echo "---- BEGIN tests/data/golden_hashes.json ----"
    echo actual.pretty()
    echo "---- END tests/data/golden_hashes.json ----"
    check("the golden fixture exists (printed above; commit it)", false, path)

# (d) THE SOURCE GUARD: no floating point, and no draw outside drawInt, inside
# the determinism boundary.
block sourceGuard:
  const guarded = [
    "sim.nim", "tank.nim", "trig.nim", "sensors.nim", "sim_types.nim",
    "sim_config.nim", "sim_state.nim"
  ]
  const banned = [
    "sin(", "cos(", "tan(", "arctan", "arcsin", "exp(", "ln(", "pow(",
    "sqrt(", "hypot(", "float", "float32", "float64"
  ]
  for name in guarded:
    let source = readRepoFile("src/waterworld/" & name)
    for line in source.splitLines():
      let code = line.strip()
      if code.startsWith("#") or code.startsWith("##"):
        continue
      # Strip trailing comments before looking: the prose in this codebase
      # legitimately talks about float builds of libm.
      let hashAt = code.find('#')
      # `isqrt(` is the ONE square root the sim is allowed, and it is integer:
      # strip it before looking for `sqrt(`.
      let bare = (if hashAt >= 0: code[0 ..< hashAt] else: code)
        .replace("isqrt(", "")
      for needle in banned:
        if needle in bare:
          check("no floating point in src/waterworld/" & name, false,
            needle & " in: " & code)
      if "rand(" in bare:
        check("only drawInt may draw in src/waterworld/" & name, false, code)
  for script in ["tools/build_replay_viewer.sh", "Dockerfile",
      "Dockerfile.replay-viewer"]:
    check("no -ffast-math in " & script,
      "-ffast-math" notin readRepoFile(script))
  check("config.nims carries no -ffast-math",
    "-ffast-math" notin readRepoFile("replay-viewer/config.nims"))
  # And the matched-pair rule the lantern deadlock came from.
  let viewerFlags = readRepoFile("replay-viewer/config.nims")
  check("config.nims declares no MODULARIZE", "MODULARIZE" notin viewerFlags)
  check("config.nims declares no EXPORT_NAME", "EXPORT_NAME=" notin viewerFlags)

# (e) DirQ12 re-derived from math.cos/math.sin, and isqrt exhaustively checked.
block trigTable:
  for d in 0 ..< DirCount:
    let
      angle = degToRad(11.25 * float(d))
      wantX = round(4096.0 * cos(angle))
      wantY = round(-4096.0 * sin(angle))
    check("DirQ12[" & $d & "].x is round(4096*cos)",
      float(DirQ12[d].x) == wantX, $DirQ12[d].x & " vs " & $wantX)
    check("DirQ12[" & $d & "].y is round(-4096*sin)",
      float(DirQ12[d].y) == wantY, $DirQ12[d].y & " vs " & $wantY)
  for v in 0 ..< 65_536:
    let r = isqrt(int64(v))
    if r * r > int64(v) or (r + 1) * (r + 1) <= int64(v):
      check("isqrt is exact below 2^16", false, $v & " -> " & $r)
      break
  var n = 1'i64
  while n * n <= (1'i64 shl 40):
    check("isqrt is exact on the perfect square " & $(n * n),
      isqrt(n * n) == n, $isqrt(n * n))
    n = n * 3 + 1
  check("isqrt(0) is 0", isqrt(0) == 0)
  check("isqrt of a negative is 0", isqrt(-5) == 0)

# (f) perm, the initial particle table and the first 200 respawns are pure
# functions of the seed.
block seededDraws:
  for seed in [1, 8_821_477, 99_999]:
    let a = initSimServer(testConfig(seed))
    let b = initSimServer(testConfig(seed))
    check("perm is a pure function of the seed", a.perm == b.perm)
    var seen: array[SkimmerCount, bool]
    for seat in 0 ..< SkimmerCount:
      check("perm entry is in range",
        a.perm[seat] >= 0 and int(a.perm[seat]) < SkimmerCount)
      seen[int(a.perm[seat])] = true
    for i in 0 ..< SkimmerCount:
      check("perm is a permutation of 0..3", seen[i])
    for f in 0 ..< FoodCount:
      check("the initial plankton table is a pure function of the seed",
        a.food[f] == b.food[f])
    for q in 0 ..< PoisonCount:
      check("the initial poison table is a pure function of the seed",
        a.poison[q] == b.poison[q])
  # 200 respawns from two fresh sims must agree draw for draw.
  var left = initSimServer(testConfig())
  var right = initSimServer(testConfig())
  for _ in 0 ..< 200:
    let one = left.drawParticle(FoodRadius, FoodSpeedSet, atStart = false)
    let two = right.drawParticle(FoodRadius, FoodSpeedSet, atStart = false)
    check("respawn draws agree across two fresh sims", one == two)
  check("the draw counter agrees too", left.rngDraws == right.rngDraws)

# (g) rngDraws is identical between two runs of the same command log.
block drawCounter:
  var one = seatedSim()
  let run = one.runScripted(blShoal, ticks = 600)
  var two = seatedSim()
  for cmds in run.cmdLog:
    two.step(cmds)
  check("rngDraws is identical between two runs of the same log",
    one.rngDraws == two.rngDraws, $one.rngDraws & " vs " & $two.rngDraws)
  check("the sampler never fell through to the lattice",
    one.latticeFallbacks == 0, $one.latticeFallbacks)

if failures > 0:
  quit("test_determinism: " & $failures & " failure(s)", 1)
echo "test_determinism: ok"
