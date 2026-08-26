## The game server entrypoint. Seed randomisation happens HERE, BEFORE
## `config.update`, so every seed-derived draw — `perm`, the initial particle
## table, every respawn — follows the FINAL seed. A public fixed seed would make
## the particle layout pre-computable by opponents.

import std/[json, os, sysrand]

import bitworld/runtime

import waterworld/sim
import waterworld/server

const LegacyFixedSeed = 8_821_477
  ## The compiled-in default. It doubles as the "nobody chose a seed" sentinel:
  ## a config carrying it (or no seed at all) gets a fresh random seed, so only
  ## a fixture, an A/B battery or a forensic re-run ever plays a pinned seed.

proc seedPinned*(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false                     ## config.update reports the real parse error.

proc randomSeed*(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(WaterworldError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed*(configJson: string): string =
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

when isMainModule:
  let
    runtimeConfig = readRuntimeConfig()
    localReplayPath =
      if runtimeConfig.replayUri.len > 0:
        getTempDir() / ("walker-waterworld-replay-" &
          $getCurrentProcessId() & ".replay")
      else:
        ""

  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(runtimeConfig.config))
    echo "seed not pinned; randomized"

  echo "walker-waterworld config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " num_agents=", config.numAgents,
    " maxTicks=", config.maxTicks,
    " turnTicks=", config.turnTicks,
    " captureTarget=", config.captureTarget,
    " wallClockBudget=", config.wallClockBudgetSeconds, "s"

  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("walker-waterworld-load-" &
        $getCurrentProcessId() & ".replay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  echo "starting walker-waterworld on ", runtimeConfig.host, ":",
    runtimeConfig.port
  runServerLoop(
    runtimeConfig.host,
    runtimeConfig.port,
    config,
    localReplayPath,
    loadReplayPath,
    "",
    runtimeConfig
  )
