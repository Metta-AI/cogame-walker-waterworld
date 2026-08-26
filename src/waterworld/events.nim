## The tier-2 event WIRE FORMAT (`COGAME_EVENTS_URI`), shared by live emission
## and re-simulation so both paths produce byte-identical rows. `SimEvent` never
## enters `gameHash`, so nothing here can affect determinism.

import std/json

import sim

proc key*(kind: SimEventKind): string =
  case kind
  of Capture: "capture"
  of Nibble: "nibble"
  of PoisonHit: "poison_hit"
  of Spawn: "spawn"
  of NearMiss: "near_miss"
  of Intent: "intent"
  of PhaseChange: "phase"
  of TargetMet: "target_met"

proc jsonRow*(event: SimEvent): JsonNode =
  %*{
    "tick": event.tick,
    "kind": event.kind.key(),
    "source": event.source,
    "target": event.target,
    "amount": event.amount,
    "x": event.x,
    "y": event.y,
    "item": event.item,
    "content": event.content
  }

proc eventsJsonl*(
  events: openArray[SimEvent], ticks: int, summaryExtra: JsonNode = nil
): string =
  ## The full JSON-lines stream: one row per event, then a summary.
  ##
  ## The trailing summary row is part of the CONTRACT, not decoration — it is
  ## how a reader distinguishes "this episode had no events" from "the file was
  ## truncated", and it carries the GameVersion the events were produced under
  ## so a consumer never has to infer it.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
