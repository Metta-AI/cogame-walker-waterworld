## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Each client used to re-type these as literals and
## nothing enforced agreement — a retuned PlaybackSpeeds would silently desync
## every client. This module renders them ONCE, from the same Nim consts the
## engine runs on; server.nim splices the block into every served client page and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.
##
## Clients read `window.WATERWORLD_WIRE`. `client/chrome_common.js` is inherited
## from the starter BYTE FOR BYTE and still reads the STARTER's wire global, so
## it runs on its own documented fallbacks (`[1,2,3,4,8,16]`, fps 24) —
## `tests/test_viewer.nim` pins those literals equal to `PlaybackSpeeds` and
## `ReplayFps`, so the fallback can never drift from the engine.

import std/strutils

import sim_types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.WATERWORLD_WIRE={speeds:" & jsIntArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",boardW:" & $(MapWidth * RenderScale) &
  ",boardH:" & $(MapHeight * RenderScale) &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before any
  ## script that reads the wire constants).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker, "<script>" & WireConstantsJs & "</script>")
