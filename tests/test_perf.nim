## The perf floor. Release-only: 1728 ticks of physics plus 6 912 controller
## evaluations plus 6 912 sensor frames must complete well inside a CI runner's
## patience — the design targets under 5 s and this bounds it at 60.

import std/[monotimes, times]

import helpers
import waterworld/[sim, baselines]

var sim = seatedSim()
let started = getMonoTime()
let run = sim.runScripted(blShoal)
let elapsed = (getMonoTime() - started).inMilliseconds.int

echo "perf: ", run.ticks, " ticks, ", run.ticks * SkimmerCount,
  " controller evaluations and sensor frames in ", elapsed, " ms"

if run.ticks < 500:
  quit("test_perf: the episode ended after only " & $run.ticks & " ticks", 1)
if elapsed > 60_000:
  quit("test_perf: " & $elapsed & " ms exceeds the 60 s bound", 1)
echo "test_perf: ok"
