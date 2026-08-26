## Static assertions over the inherited chrome: what must be byte-identical,
## what must survive the fork, and what must be gone.

import std/[os, strutils]

import crunchy/sha256

import helpers
import waterworld/[sim, broadcast, global]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

let
  page = readRepoFile("client/replay_broadcast.html")
  chrome = readRepoFile("client/chrome_common.js")
  core = readRepoFile("client/broadcast_core.js")
  viewerFlags = readRepoFile("replay-viewer/config.nims")
  staticReplay = readRepoFile("replay-viewer/static_replay.js")
  worker = readRepoFile("replay-viewer/static_replay_worker.js")

const
  ## client/chrome_common.js is inherited from coworld-ctf BYTE FOR BYTE — zero
  ## edits. Its CTF-specific paths (perks, handicaps, lives, the flag story)
  ## stay in the file and are inert because the corresponding state fields are
  ## simply absent from waterworld's stream. This is the SHA-256 of the
  ## starter's copy at the fork point, as the design note specifies; if it
  ## changes, the file was edited and the fork is no longer the starter's
  ## chrome.
  ChromeCommonSha256 =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"

block chromeIsByteIdentical:
  var actual = ""
  for b in sha256(chrome):
    actual.add(toHex(b).toLowerAscii())
  check("chrome_common.js is byte-identical to the starter's copy",
    actual == ChromeCommonSha256, actual & " vs " & ChromeCommonSha256)
  check("chrome_common.js still exposes the shared chrome factory",
    "window.ChromeCommon = function (ctx)" in chrome)

block relayoutIsTheStarters:
  check("relayout() is present", "function relayout() {" in page)
  check("it sets --hudscale on :root",
    "root.style.setProperty('--hudscale'" in page)
  check("it sets --topband on :root",
    "root.style.setProperty('--topband'" in page)
  check("it sets --band on :root",
    "root.style.setProperty('--band'" in page)
  check("the hudscale clamp is the starter's",
    "Math.max(0.5, Math.min(1.6, boardW / 760))" in page)
  check("the tiny threshold is the starter's",
    "stage.classList.toggle('tiny', boardW <= 620)" in page)

block noOverlaySitsInTheTransportBand:
  check("the endcard stops at the transport band",
    "bottom: var(--band, 0px)" in page)
  check("every seek dismisses the endcard",
    "$('endcard').classList.remove('on')" in page)
  check("the game block's overlays are positioned inside #chrome",
    "#ww-legend" in page)

block keptElements:
  for id in ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
      "chrome", "scorebug", "plates-l", "plates-r", "clock", "clock-time",
      "clock-caption", "mmwarn", "bannerlane", "killfeed", "transport",
      "btn-play", "btn-back", "btn-fwd", "btn-end", "btn-restart", "btn-loop",
      "btn-skip", "btn-spoilers", "speedchips", "scrub", "scrub-fill",
      "scrub-head", "scrub-win", "momentum", "lulls", "tick-clock",
      "ffwd-chip", "ffwd-mini", "win-chip", "endcard", "ec-headline", "ec-how",
      "ec-wincond", "ec-teams", "ec-replay", "status"]:
    check("the inherited element #" & id & " survives",
      ("id=\"" & id & "\"") in page, id)

block removedElements:
  for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
      "zoom-in", "zoom-slider", "zoom-read", "fpv", "fpv-canvas", "fpv-hud",
      "fpv-name", "fpv-hp", "fpv-gear", "fpv-map", "fpv-map-canvas", "fpv-cap",
      "fpv-grip", "povBadge"]:
    check("the removed element #" & id & " is gone",
      ("id=\"" & id & "\"") notin page, id)
  for selector in ["#viewpanel {", "#povBadge {", "#fpv {", "#minimap {",
      "#zoombar {"]:
    check("the removed CSS rule " & selector & " is gone",
      selector notin page, selector)
  for wiring in ["$('minimap')", "$('povBadge')", "$('zoom-in')",
      "renderFpv(", "core.attachMinimap("]:
    check("the removed wiring " & wiring & " is gone", wiring notin page, wiring)

block beatMarkersAreLabelledButtons:
  check("the game block builds a <button>, not a div",
    "document.createElement('button')" in page)
  check("every marker carries an aria-label",
    "el.setAttribute('aria-label', label)" in page)
  check("every marker carries a title", "el.title = label;" in page)
  check("a click seeks to that tick", "CTX.send('s:' + tick)" in page)
  # CSS for EVERY kind the sim emits.
  for kind in ScrubberBeatKinds:
    check("there is a .beat-marker CSS rule for the kind " & kind,
      (".beat-marker." & kind) in page, kind)
  check("and the base .beat-marker rule exists", ".beat-marker {" in page)

block noAliasCollision:
  ## The chrome alias block declares the shared beat builder with a hoisted
  ## `var markBeat = C.markBeat`, so a game-block function of that name would be
  ## silently swallowed and the scrubber would end up with unlabelled div
  ## markers that never seek. Assert no game-block TOP-LEVEL name collides.
  let banner = page.find("WALKER-WATERWORLD additions to the inherited")
  check("the game block banner is present", banner > 0)
  # From the block's own <script>, not its banner: the banner NAMES the alias it
  # must not shadow, in prose.
  let scriptAt = page.find("<script>", banner)
  check("the game block carries a script", scriptAt > banner)
  let block2 = page[scriptAt .. ^1]
  const aliases = ["RED", "BLUE", "AMBER", "PAPER", "GREEN", "YELLOW",
    "TEAM_ORDER", "TEAM_COLOR", "teamCol", "activeTeams", "teamOf", "otherTeam",
    "stripSeatSuffix", "teamPolicies", "teamName", "teamHeadline", "rosterName",
    "setName", "esc", "fmt", "setHandicap", "teamPerkGroups", "perkIconsHtml",
    "togglePov", "renderClock", "renderTransport", "ingestLullSpans",
    "renderLullSpans", "markBeat", "killMarkerTeam", "renderBeatMarkers",
    "captureTeam", "ingestBeats", "setVerdict", "ingestLeadSeries",
    "recordMomentum", "renderMomentum", "getSpoilers", "setSpoilers"]
  for alias in aliases:
    for declaration in ["function " & alias & "(", "var " & alias & " =",
        "let " & alias & " =", "const " & alias & " ="]:
      check("the game block does not shadow the chrome alias " & alias,
        declaration notin block2, declaration)

block legibleAt360:
  check("the plate name grows rather than collapsing to an ellipsis",
    "flex: 1 1 auto;" in page and "min-width: 3.2em;" in page)
  check("labels are hidden under the tiny threshold",
    "#stage.tiny" in page)
  check("the ray legend goes at 360 px",
    "#stage.tiny #ww-legend" in page)

block rendererFixtureStillTestsTheCaps:
  ## tools/ci/renderer_fixture.html is the ONLY thing in CI that ever renders a
  ## full-cap LLM `say`/`note` (docker_smoke.sh has no API key, so every seat
  ## there is a scripted baseline with short fixed lines). It self-checks its own
  ## string lengths in the browser, which means a MaxSayRunes/MaxNoteRunes bump
  ## turns the fixture red instead of quietly rendering a short string — but only
  ## after a full wasm build. Catch it here, at the source of truth.
  let fixture = readRepoFile("tools/ci/renderer_fixture.html")

  proc jsRuneLen(literal: string): int =
    ## Rune length of a single-quoted JS string literal, or of several joined by
    ## `+`. Decodes \uXXXX; a surrogate PAIR is ONE rune, which is the whole
    ## point of the emoji in the fixture.
    var i = 0
    var highSurrogate = false
    while i < literal.len:
      case literal[i]
      of '\'':
        # Skip everything between the closing quote and the next opening one
        # (the `' +\n    '` join and its indentation).
        inc i
        while i < literal.len and literal[i] != '\'': inc i
        inc i
      of '\\':
        if i + 5 < literal.len and literal[i + 1] == 'u':
          let cp = parseHexInt(literal[i + 2 .. i + 5])
          if cp >= 0xD800 and cp <= 0xDBFF:
            highSurrogate = true
            inc result
          elif cp >= 0xDC00 and cp <= 0xDFFF and highSurrogate:
            highSurrogate = false   # the pair already counted as one rune
          else:
            inc result
          i += 6
        else:
          inc result
          i += 2
      else:
        highSurrogate = false
        inc result
        inc i

  proc fixtureLiteral(name: string): string =
    let start = fixture.find("var " & name & " = ")
    doAssert start >= 0, name & " is missing from the fixture"
    let quoteAt = fixture.find('\'', start)
    let stop = fixture.find(";\n", quoteAt)
    fixture[quoteAt + 1 ..< stop]

  check("the fixture's say is exactly MaxSayRunes",
    jsRuneLen(fixtureLiteral("SAY")) == MaxSayRunes,
    $jsRuneLen(fixtureLiteral("SAY")) & " != " & $MaxSayRunes)
  check("the fixture's note is exactly MaxNoteRunes",
    jsRuneLen(fixtureLiteral("NOTE")) == MaxNoteRunes,
    $jsRuneLen(fixtureLiteral("NOTE")) & " != " & $MaxNoteRunes)
  check("the fixture names the caps it is pinned to",
    ($MaxSayRunes & "-rune cap") in fixture and
      ($MaxNoteRunes & "-rune cap") in fixture)

block bubblesStayOnTheBoard:
  ## The speech-bubble pill is centred on one of three fixed slots and sized
  ## from the text, so a full-cap `say` of wide glyphs is what runs off the
  ## edge. The slot centre is clamped by the sprite's own width; these are the
  ## edge cases of that clamp.
  const Slots = 3
  let narrow = bubbleSlotX(0, Slots, 200)
  check("a narrow pill sits on its slot centre", narrow == BoardW div 6,
    $narrow)
  for width in [200, 600, 980, BoardW - 2, BoardW, BoardW * 2]:
    for slot in 0 ..< Slots:
      let cx = bubbleSlotX(slot, Slots, width)
      let left = cx - width div 2
      let right = cx + width div 2
      if width <= BoardW:
        check("a " & $width & " px pill in slot " & $slot &
          " never crosses the left edge", left >= 0, $left)
        check("a " & $width & " px pill in slot " & $slot &
          " never crosses the right edge", right <= BoardW, $right)
      else:
        check("a pill wider than the board is centred, not pushed off",
          cx == BoardW div 2, $cx)

block boardAspect:
  check("the page derives the fixed tank's aspect from the stream",
    "var BOARD_W = 1200, BOARD_H = 800;" in page)
  check("the board render scale is the starter's rule",
    boardRenderScaleFor(MapWidth, MapHeight) == RenderScale)
  check("the viewer capacity preflight has orders of magnitude of headroom",
    predictedViewerRenderBytes(MapWidth, MapHeight) < WasmViewerBudgetBytes,
    $predictedViewerRenderBytes(MapWidth, MapHeight))

block broadcastCoreIsTheStarters:
  ## broadcast_core.js differs from the starter's copy in the WATERWORLD_WIRE
  ## identifier and one source-path comment, and nothing else.
  check("the core reads WATERWORLD_WIRE",
    "window.WATERWORLD_WIRE && window.WATERWORLD_WIRE.chromeSpriteId" in core)
  check("the core still keys the chrome sprite at 4090", "|| 4090;" in core)
  check("the core keeps its zoom/pan code, simply never driven",
    "function zoomAt(factor, cssX, cssY)" in core)
  check("the core keeps its minimap code", "attachMinimap" in core)

block staticBundleMarkers:
  check("static_replay.js sets data-replay-loaded on the first drawn frame",
    "setAttribute('data-replay-loaded', 'true')" in staticReplay)
  check("static_replay.js sets data-replay-error on failure",
    "'data-replay-error'" in staticReplay)
  check("static_replay.js reports a hash mismatch tick",
    "'data-replay-mismatch-tick'" in staticReplay)
  check("the loaded marker is set from the Worker's loaded message, not rAF",
    "message.type === 'loaded'" in staticReplay)
  check("the worker name was renamed with the bundle",
    "waterworld-static-replay" in staticReplay)
  check("the adapter global was renamed with the bundle",
    "window.WaterworldStaticReplay" in staticReplay)

block matchedPairFlagsAndBootstrap:
  ## The emscripten link flags and the JS bootstrap are a MATCHED PAIR. This
  ## bundle is the paintbot lineage: a non-modularized module plus
  ## Module.onRuntimeInitialized. A MODULARIZE/EXPORT_NAME mixture throws
  ## nothing, logs nothing and hangs on "Loading replay..." forever.
  check("config.nims declares no MODULARIZE", "MODULARIZE" notin viewerFlags)
  check("config.nims declares no EXPORT_NAME", "EXPORT_NAME=" notin viewerFlags)
  check("the worker uses the onRuntimeInitialized bootstrap",
    "Module.onRuntimeInitialized = function" in worker)
  check("the worker declares a plain Module object", "var Module = {};" in worker)
  check("the worker importScripts the emitted module",
    "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./waterworld_replay.js')" in worker)
  check("config.nims emits waterworld_replay.js",
    "waterworld_replay.js" in viewerFlags)
  for exported in ["_waterworld_load_replay", "_waterworld_frame",
      "_waterworld_input", "_waterworld_packet_ptr", "_waterworld_packet_len",
      "_waterworld_mismatch_tick", "_waterworld_error_ptr",
      "_waterworld_error_len", "_waterworld_stage_ptr", "_waterworld_stage_len"]:
    check("config.nims exports " & exported, exported in viewerFlags, exported)
  check("the wasm entry keeps the ABORTING_MALLOC diagnostics",
    "ABORTING_MALLOC" in viewerFlags)
  check("the wasm entry keeps the live-runtime lifetime",
    "emscripten_exit_with_live_runtime" in
      readRepoFile("replay-viewer/waterworld_replay.nim"))

block noStarterIdentifiersSurvive:
  ## No ctf_/CTF_/paintball identifier survives in client/, replay-viewer/ or
  ## src/ — EXCEPT inside client/chrome_common.js, which is inherited byte for
  ## byte by contract (the sha256 above is the stronger assertion, and the file's
  ## `window.CTF_WIRE` read falls back to literals this test pins to the engine).
  for dir in ["client", "replay-viewer", "src"]:
    for path in walkDirRec(repoRoot() / dir):
      if path.endsWith("chrome_common.js"):
        continue
      if not (path.endsWith(".nim") or path.endsWith(".js") or
          path.endsWith(".html") or path.endsWith(".nims")):
        continue
      let body = readFile(path)
      for needle in ["ctf_", "CTF_", "paintball", "Paintball", "PB_MODE"]:
        check("no " & needle & " identifier in " & path.extractFilename(),
          needle notin body, needle)

if failures > 0:
  quit("test_viewer: " & $failures & " failure(s)", 1)
echo "test_viewer: ok"
