## The baseline tuning harness: a bounded grid sweep over the THREE
## BaselineParams numbers, played over a seed panel with four `shoal`s.
##
##   nim c -d:release -r tools/tune_baselines.nim            # print the table
##   nim c -d:release -r tools/tune_baselines.nim --check     # verify the pick
##
## THE PHYSICS CONSTANTS IN src/waterworld/sim_types.nim ARE NOT SWEPT. If four
## `shoal`s cannot capture, these three numbers are wrong, not the tank — that
## is the whole point of having them be a parameter object rather than literals.
## The winning cell is recorded in `tools/ci/baseline_tuning.json` and
## `tests/test_tuning.nim` asserts the shipped defaults still equal it.

import std/[json, math, os, strformat, strutils]

import waterworld/[sim, roster, sensors, intents, control, baselines]

proc playEpisode(seed: int, params: BaselineParams): tuple[
    captures: int, score: float] =
  var config = defaultGameConfig()
  config.seed = seed
  config.startWaitTicks = 0
  config.gameOverTicks = 0
  config.playerNames = @["a", "b", "c", "d"]
  config.tokens = @["t0", "t1", "t2", "t3"]
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  for seat in 0 ..< SkimmerCount:
    discard sim.addPlayer("seat-" & $seat, seat, "t" & $seat, trusted = true)
  var ctl = initControlState()
  var seatIntents = newSeq[SkimmerIntent](SkimmerCount)
  var haveIntent = newSeq[bool](SkimmerCount)
  var guard = 0
  while sim.phase != GameOver and guard < config.maxTicks + 16:
    inc guard
    let turnTicks = max(1, config.turnTicks)
    let turnIndex = sim.gameTicksElapsed() div turnTicks
    var frames: seq[SensorFrame]
    for seat in 0 ..< SkimmerCount:
      frames.add(sim.frameFor(sim.skimmerForSeat(seat)))
    if sim.phase == Playing and sim.gameTicksElapsed() mod turnTicks == 0:
      for seat in 0 ..< SkimmerCount:
        seatIntents[seat] = shoalIntent(
          sim, sim.skimmerForSeat(seat), frames[seat], turnIndex, params)
        haveIntent[seat] = true
    var cmds: array[SkimmerCount, uint8]
    for i in 0 ..< SkimmerCount:
      let seat = sim.seatForSkimmer(i)
      let intent = if haveIntent[seat]: seatIntents[seat] else: defaultIntent()
      cmds[i] = ctl.thrustCommand(sim, i, frames[seat], intent)
    sim.step(cmds)
  (int(sim.captures), sim.scoreDouble())

when isMainModule:
  let record = parseJson(readFile(getCurrentDir() / "tools" / "ci" /
    "baseline_tuning.json"))
  var seeds: seq[int]
  for i in 0 ..< 12:
    seeds.add(1000 + i * 7919)

  var
    best: BaselineParams
    bestMean = -1.0e9
    rows: seq[string]
  for radiusNode in record{"grid"}{"pairJoinRadiusUm"}:
    for standoffNode in record{"grid"}{"standoffMilli"}:
      for leadNode in record{"grid"}{"leadTicks"}:
        let params = BaselineParams(
          pairJoinRadiusUm: int32(radiusNode.getInt()),
          standoffMilli: int32(standoffNode.getInt()),
          leadTicks: int32(leadNode.getInt()))
        var
          total = 0.0
          captures = 0
          hits = 0
        for seed in seeds:
          let outcome = playEpisode(seed, params)
          total += outcome.score
          captures += outcome.captures
          if outcome.captures >= 8:
            inc hits
        let mean = total / float(seeds.len)
        rows.add(&"{params.pairJoinRadiusUm:>9} {params.standoffMilli:>6} " &
          &"{params.leadTicks:>5}  mean {mean:>9.2f}  captures {captures:>4} " &
          &" seeds@8+ {hits:>3}/{seeds.len}")
        if mean > bestMean:
          bestMean = mean
          best = params

  echo "   pairJoin standoff  lead"
  for row in rows:
    echo row
  echo ""
  echo "best cell: pairJoinRadiusUm=", best.pairJoinRadiusUm,
    " standoffMilli=", best.standoffMilli, " leadTicks=", best.leadTicks,
    " (mean ", bestMean.formatFloat(ffDecimal, 2), ")"

  if "--check" in commandLineParams():
    let pick = record{"pick"}
    if int(best.pairJoinRadiusUm) != pick{"pairJoinRadiusUm"}.getInt() or
        int(best.standoffMilli) != pick{"standoffMilli"}.getInt() or
        int(best.leadTicks) != pick{"leadTicks"}.getInt():
      quit("the sweep's winner is not the recorded pick; update " &
        "tools/ci/baseline_tuning.json and DefaultBaselineParams together", 1)
    echo "the sweep's winner is the recorded pick"
