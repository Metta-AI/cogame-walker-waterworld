## The tuning pin's own integrity: the sweep's recorded pick and the shipped
## defaults are the same three numbers, and the grid the sweep covered contains
## that pick.

import std/[json, strutils]

import helpers
import waterworld/baselines

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))

check("the tuning record names the harness that produced it",
  tuning{"swept"}.getStr() == "tools/tune_baselines.nim",
  tuning{"swept"}.getStr())
check("the tuning record says the physics constants are NOT swept",
  "NOT SWEPT" in tuning{"note"}.getStr())

for (key, shipped) in [
    ("pairJoinRadiusUm", int(DefaultBaselineParams.pairJoinRadiusUm)),
    ("standoffMilli", int(DefaultBaselineParams.standoffMilli)),
    ("leadTicks", int(DefaultBaselineParams.leadTicks))]:
  check("the shipped " & key & " equals the sweep's pick",
    tuning{"pick"}{key}.getInt() == shipped,
    $tuning{"pick"}{key}.getInt() & " vs " & $shipped)
  var inGrid = false
  for candidate in tuning{"grid"}{key}:
    if candidate.getInt() == shipped:
      inGrid = true
  check("the shipped " & key & " is a cell the sweep actually covered",
    inGrid, $shipped)

check("the tuning harness is committed",
  readRepoFile("tools/tune_baselines.nim").len > 500)

if failures > 0:
  quit("test_tuning: " & $failures & " failure(s)", 1)
echo "test_tuning: ok"
