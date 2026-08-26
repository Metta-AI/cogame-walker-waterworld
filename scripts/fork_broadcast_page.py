#!/usr/bin/env python3
"""Fork coworld-ctf's broadcast page into walker-waterworld's viewer.

Run from the repo root with the starter checkout available:

    python3 scripts/fork_broadcast_page.py /path/to/coworld-ctf

This script exists so the fork is REVIEWABLE as a diff against the starter
rather than as a new file. `client/replay_broadcast.html` is the starter's page
with, and only with:

  (a) the removed starter elements the design note names, cut out by line range:
      `#viewpanel` and its children (`#minimap`, `#minimap-canvas`, `#zoombar`,
      `#zoom-out`, `#zoom-in`, `#zoom-slider`, `#zoom-read`), `#fpv` and its
      children, and `#povBadge` — markup, CSS and wiring. The tank is fixed and
      the 1200x800 board always fits the frame, so the zoom bar and minimap
      exist for nothing; broadcast_core.js keeps its zoom/pan code verbatim and
      is simply never driven by a panel;
  (b) the five mode branches the starter's own note says branch on the game
      mode — the scorebug plates' CONTENTS and the endcard's stat columns and
      verdict — rewritten from paintball's to waterworld's;
  (c) a handful of copy and identifier edits (title, board aspect, the static
      bundle's global, the locker-room captions, PB_MODE -> WW_MODE);
  (d) the paintball game block replaced by `scripts/waterworld_block.html`.

Everything else is byte-for-byte the starter's page.
"""

import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 1-based inclusive line ranges to DELETE, in the starter's own numbering.
# Verified against coworld-ctf @ bb1bf7b by the boundary assertions below.
CUTS = [
    (528, 833),     # CSS: #povBadge, #fpv*, #viewpanel/#minimap/#zoombar
    (1452, 1459),   # CSS: the ?viewpanel=0 opt-out
    (1506, 1522),   # markup: #viewpanel
    (1525, 1549),   # markup: #povBadge + #fpv
    (1641, 1658),   # JS: the eye-level cog art prose the FPV billboards needed
    (1676, 1701),   # JS: the eye-level cog art the FPV billboards blitted
    (1876, 1884),   # JS: the ?viewpanel=0 param
    (2083, 2116),   # JS: ingestFpMap (the FPV tactical minimap bake)
    (2347, 3465),   # JS: renderPov + the whole first-person picture-in-picture
    (3954, 3955),   # JS: the povBadge click handler
    (4151, 4244),   # JS: the zoom cluster + minimap wiring
]

SCOREBUG_ENSURE_WW = """      if (WW_MODE) {
        // WATERWORLD: one cooperative side, so ONE team plate — the pod, with
        // the live shared score as its headline number. That leaves #plates-r
        // free, so the objective plate (CAUGHT n / target, poison, thrust) is
        // built into it here. The plate, the sides and the clock column are the
        // starter's.
        plate.innerHTML =
          '<div class="team-id">' +
          '<div class="lives-line">' +
          '<span class="team-name plate-name" id="name-' + team + '">THE POD</span>' +
          '<span class="hcap" id="hcap-' + team + '" style="display:none"></span>' +
          '<span class="ww-score" id="ww-score">0.000</span>' +
          '</div>' +
          '<div class="ww-sub">' +
          '<span id="ww-skimmers">4 skimmers</span>' +
          '<span class="ww-nibbles" id="ww-nibbles">0 nibbles</span>' +
          '</div>' +
          '</div>';
        sides[0].appendChild(plate);
        var bar = '';
        for (var seg = 0; seg < 20; seg++) bar += '<i></i>';
        var objective = document.createElement('div');
        objective.className = 'plate pod side-r';
        objective.innerHTML =
          '<div class="ww-obj">' +
          '<span class="ww-caught" id="ww-caught">CAUGHT 0 / 20</span>' +
          '<div class="ww-bar" id="ww-bar">' + bar + '</div>' +
          '<div class="ww-sub">' +
          '<span id="ww-poison">poison 0</span>' +
          '<span class="ww-thrust" id="ww-thrust">thrust 0.00</span>' +
          '</div>' +
          '</div>';
        sides[1].appendChild(objective);
        return;
      }"""

SCOREBUG_RENDER_WW = """      if (WW_MODE) {
        var t = tr[team] || {};
        var podScore = t.score != null ? t.score : 0;
        var caught = t.captures || 0;
        var target = t.target || 20;
        var scoreEl = $('ww-score');
        if (scoreEl) {
          scoreEl.textContent = podScore.toFixed(3);
          scoreEl.className = 'ww-score ' + (podScore >= 0 ? 'up' : 'down');
        }
        // The plate caption is the SIDE, not a policy: four policies share one
        // score. The real names ride this element's title and the endcard.
        var nameEl = $('name-' + team);
        if (nameEl) {
          nameEl.textContent = 'THE POD';
          nameEl.title = (s.roster || []).map(function (p) {
            return p.name + ' (' + p.alias + ')';
          }).join(' \\u00b7 ');
        }
        var skimEl = $('ww-skimmers');
        if (skimEl) skimEl.textContent = (s.roster || []).length + ' skimmers';
        var nibEl = $('ww-nibbles');
        if (nibEl) nibEl.textContent = (t.nibbles || 0) + ' nibbles';
        var caughtEl = $('ww-caught');
        if (caughtEl) caughtEl.textContent = 'CAUGHT ' + caught + ' / ' + target;
        var bar = $('ww-bar');
        if (bar && bar.children.length) {
          for (var seg = 0; seg < bar.children.length; seg++) {
            var lit = Math.round((seg + 1) * Math.max(1, target) /
              bar.children.length) <= caught;
            if (bar.children[seg].classList.contains('on') !== lit) {
              bar.children[seg].classList.toggle('on', lit);
            }
          }
        }
        var poisonEl = $('ww-poison');
        if (poisonEl) poisonEl.textContent = 'poison ' + (t.poison || 0);
        var thrustEl = $('ww-thrust');
        if (thrustEl) {
          thrustEl.textContent = 'thrust \\u2212' + (t.thrust || 0).toFixed(2);
        }
        var podPlate = document.querySelector('.plate[data-team="' + team + '"]');
        if (podPlate) {
          podPlate.classList.toggle('leader', podScore > 0 && s.ph === 'playing');
        }
        return;
      }"""

ENDCARD_SORT_WW = """    // WATERWORLD sorts by ASSISTS: in a cooperative run nobody has kills, and
    // an assist is the only per-seat record of having been there for a catch.
    var wwEndcardOrder = function (a, b) {
      return (b.assists || 0) - (a.assists || 0) ||
        (b.nibbles || 0) - (a.nibbles || 0) || a.s - b.s;
    };
    var rows = (s.roster || []).filter(function (p) { return p.team === team; })
      .slice().sort(WW_MODE ? wwEndcardOrder : endcardOrder);"""

ENDCARD_ROWS_WW = """      if (WW_MODE) {
        // WATERWORLD: the row is a SEAT, by REAL policy name, with the body it
        // drove and the four things that decide a cooperative run — assists,
        // nibbles, poison hits and how hard it thrust — plus its LLM/fallback
        // turn split, which is where a spectator sees whether the champion was
        // really playing.
        return '<div class="ec-row' + (mvp ? ' mvp' : '') + '">' +
          '<span class="pcell">' +
          '<span class="pname" title="' + esc(p.name) + '">' +
          esc(p.name) + '</span> ' +
          '<span class="ww-alias">' + esc(p.alias || '') + '</span>' +
          '</span>' +
          '<span class="n">' + (p.assists || 0) + '</span>' +
          '<span class="n">' + (p.nibbles || 0) + '</span>' +
          '<span class="n">' + (p.poison || 0) + '</span>' +
          '<span class="n">' + (p.thrustPct || 0) + '%</span>' +
          '<span class="n clstr">' + (p.llm || 0) + '/' + (p.fb || 0) + '</span>' +
          '</div>';
      }"""

ENDCARD_TEAMS_WW = """      el.innerHTML = WW_MODE
        ? '<div class="ec-tname ' + team + '" id="ec-tname-' + team + '">THE POD</div>' +
          '<div class="ec-lives">' +
          '<span class="fl-num ' + team + '" id="ec-' + team + '">0.000</span>' +
          '<span class="fl-cap">Shared score</span>' +
          '</div>' +
          '<div class="ec-thead"><span>Policy</span><span>Ast</span>' +
          '<span>Nib</span><span>Psn</span><span>Thr</span><span>LLM</span></div>' +
          '<div id="ec-rows-' + team + '"></div>'
        : '<div class="ec-tname ' + team + '" id="ec-tname-' + team + '">' + team.toUpperCase() + '</div>' +
          '<div class="ec-lives">' +
          '<span class="fl-num ' + team + '" id="ec-' + team + '">0</span>' +
          '<span class="fl-cap">Lives left</span>' +
          '</div>' +
          '<div class="ec-thead"><span>Player</span><span>K</span><span>D</span><span>Clstr</span><span>Cap</span></div>' +
          '<div id="ec-rows-' + team + '"></div>';"""

ENDCARD_NUMERAL_WW = """      $('ec-' + team).textContent = WW_MODE
        ? ((o.score != null ? o.score : 0).toFixed(3))
        : overLives(o, team);"""

ENDCARD_VERDICT_WW = """    if (WW_MODE) {
      // WATERWORLD: the verdict is the SHARED score and the rule the server
      // applied. There is no winner and no draw — one cooperative side.
      var caughtLine = o.captures + ' caught \\u00b7 ' + (o.nibbles || 0) +
        ' nibbles \\u00b7 ' + (o.poisonHits || 0) + ' poison hits \\u00b7 thrust \\u2212' +
        (o.thrust || 0).toFixed(2);
      head.className = 'headline pod';
      head.textContent = o.endRule === 'target_met'
        ? 'TARGET MET in ' + fmt((o.ticks || 0) / FPS) + ' \\u00b7 score ' +
          o.score.toFixed(3)
        : o.captures + ' CAUGHT \\u00b7 score ' + o.score.toFixed(3);
      $('ec-wincond').textContent =
        'Two skimmers on one plankton at the same tick \\u2014 ' +
        (o.target || 20) + ' catches ends the run early and wins it';
      var why = {
        target_met: 'the pod reached the catch target and the run ended there.',
        full_time: 'full time on the tank clock.',
        wall_clock: 'the engine hit its wall-clock budget and scored the tank ' +
          'as it stood at that tick.',
        sim_fault: 'a sim invariant tripped; the run was scored where it stopped.',
        host_error: 'the host raised; the run was scored where it stopped.'
      }[o.endRule] || 'the run ended.';
      how.textContent = caughtLine + ' \\u2014 ' + why;
      return;
    }"""

# 1-based inclusive line ranges REPLACED wholesale, in the starter's numbering.
REPLACES = [
    (2213, 2234, SCOREBUG_ENSURE_WW),
    (2263, 2294, SCOREBUG_RENDER_WW),
    (3719, 3720, ENDCARD_SORT_WW),
    (3726, 3741, ENDCARD_ROWS_WW),
    (3782, 3796, ENDCARD_TEAMS_WW),
    (3833, 3835, ENDCARD_NUMERAL_WW),
    (3841, 3878, ENDCARD_VERDICT_WW),
]

VIEW_UI_STUB = """  // The zoom bar and minimap panel (#viewpanel) are REMOVED for
  // walker-waterworld: the tank is fixed and the 1200x800 board always fits the
  // frame, so there is never anything off-screen to locate.
  // broadcast_core.js keeps its zoom/pan code verbatim -- pinch and drag still
  // work -- and this is all that is left of the panel's wiring: keep the
  // touch-action and the cursor honest.
  function syncViewUi(t) {
    t = t || core.getTransform();
    if (!t) return;
    syncTouchAction(t);
    if (!dragging) {
      canvas.style.cursor =
        (t.zoom || 1) > (t.minZoom || 1) + 1e-6 ? 'grab' : '';
    }
  }
"""

# Plain string replacements applied after the cuts and range replacements. Each
# must match EXACTLY ONCE unless a count is given; the script fails loudly
# otherwise, so a starter bump cannot silently skip an edit.
EDITS = [
    ("<title>Ctf — Broadcast Replay</title>",
     "<title>Walker Waterworld — Broadcast Replay</title>", 1),
    # The board aspect: the fixed tank is 1200x800 logical pixels.
    ("  var BOARD_W = 1235, BOARD_H = 659;",
     "  var BOARD_W = 1200, BOARD_H = 800;", 1),
    # The static-bundle adapter's global was renamed with the bundle.
    ("window.CtfStaticReplay only exists",
     "window.WaterworldStaticReplay only exists", 1),
    ("  var COG_BASE = window.CtfStaticReplay",
     "  var COG_BASE = window.WaterworldStaticReplay", 1),
    ("  var replayAdapter = window.CtfStaticReplay || null;",
     "  var replayAdapter = window.WaterworldStaticReplay || null;", 1),
    ("window.parent.postMessage({ src: 'ctf-replay',",
     "window.parent.postMessage({ src: 'waterworld-replay',", 1),
    ("if (!m || m.src !== 'ctf-shell') return;",
     "if (!m || m.src !== 'waterworld-shell') return;", 1),
    # The mode flag, the game block's name, and what latches it. `ww` rides
    # every waterworld frame and no other.
    ("  // PAINTBALL mode: latched on the first frame that carries a squad-game\n"
     "  // field (`regime` only rides squad frames). Classic frames never set it.\n"
     "  var PB_MODE = false;\n"
     "  var PB_CTX = null;             // filled at the end of this IIFE (hoisted)",
     "  // WATERWORLD mode: latched on the first frame that carries the tank\n"
     "  // block (`ww` rides every waterworld frame and no other).\n"
     "  var WW_MODE = false;\n"
     "  var WW_CTX = null;            // filled at the end of this IIFE (hoisted)",
     1),
    ("    if (!PB_MODE && s.regime !== undefined) PB_MODE = true;",
     "    if (!WW_MODE && s.ww !== undefined) WW_MODE = true;", 1),
    ("    // PAINTBALL additions run last, over the classic chrome's own render.\n"
     "    if (PB_MODE && window.PaintballChrome) window.PaintballChrome.frame(s, PB_CTX, jumped);",
     "    // WATERWORLD additions run last, over the inherited chrome's own render.\n"
     "    if (WW_MODE && window.WaterworldChrome)\n"
     "      window.WaterworldChrome.frame(s, WW_CTX, jumped);", 1),
    ("    if (PB_MODE && window.PaintballChrome &&\n"
     "        window.PaintballChrome.event(e, s, PB_CTX)) {",
     "    if (WW_MODE && window.WaterworldChrome &&\n"
     "        window.WaterworldChrome.event(e, s, WW_CTX)) {", 1),
    ("    // PAINTBALL: every beat goes through the appended game block, which draws\n"
     "    // LABELLED, CLICKABLE buttons on the scrubber (pbBeat) instead of\n"
     "    // chrome_common's unlabelled div markers. When the block handles a kind\n"
     "    // it returns true, so the classic switch never doubles it; classic\n"
     "    // replays never enter this branch at all.\n",
     "    // WATERWORLD: every beat goes through the appended game block, which\n"
     "    // draws LABELLED, CLICKABLE buttons on the scrubber (wwMarkBeat)\n"
     "    // instead of chrome_common's unlabelled div markers. When the block\n"
     "    // handles a kind it returns true, so the inherited switch never\n"
     "    // doubles it.\n", 1),
    ("  PB_CTX = {", "  WW_CTX = {", 1),
    ("  if (window.PaintballChrome) window.PaintballChrome.install(PB_CTX);",
     "  if (window.WaterworldChrome) window.WaterworldChrome.install(WW_CTX);", 1),
    ("(PB_MODE ? '|pb' : '')", "(WW_MODE ? '|ww' : '')", 2),
    ("    renderPov(s);\n", "", 1),
    ("    ingestFpMap(s);\n", "", 1),
    # The locker-room curtain keeps the starter's art and gains the tank's copy.
    ("Filling hoppers with fresh paint&hellip;", "Flooding the tank&hellip;", 1),
    ("    <div class=\"lk-sub\">Bot locker room &middot; Loading replay</div>",
     "    <div class=\"lk-sub\">Four skimmers, one tank, nothing catches alone"
     " &middot; Loading replay</div>", 1),
    ("UNDER the arena: the four cogs prepping their paintball markers",
     "UNDER the tank: the four skimmers priming their thrusters", 1),
    ("    // Keyed on team set AND mode: paintball frames arrive after the first\n"
     "    // classic-built frame, so the plates rebuild once when the mode is known.",
     "    // Keyed on team set AND mode: the first frame can land before `ww` has\n"
     "    // been seen, so the plates rebuild once when the mode is known.", 1),
    ("""      'Filling hoppers with fresh paint…',
      'Pump check: one, two. One, two…',
      'Polishing visors to a mirror shine…',
      'Shaking the paint pods awake…',
      'Squats. Even robots warm up…',
      'Topping off the CO₂…',
      'Chalking up the wheels…',
      'Reviewing the game plan…'""",
     """      'Flooding the tank…',
      'Priming thrusters. One, two. One, two…',
      'Calibrating sixteen sensors…',
      'Seeding the plankton…',
      'Counting the poison blooms…',
      'Checking the transponder…',
      'Polishing hulls to a mirror shine…',
      'Nobody catches anything alone…'""", 1),
]

BOUNDARIES = {
    528: "/* POV eye badge shown when a slot is inspected",
    832: "#zoom-read.zoomed",
    1452: "Opt-OUT of the #viewpanel overlay",
    1459: "body[data-noviewpanel] #viewpanel",
    1506: "<!-- View controls: zoom the board",
    1525: 'id="povBadge"',
    1641: "---- eye-level cog art for the EYES PiP billboards ----",
    1658: "//",
    1676: "var COG_ART = {}, COG_ART_GUN = {};",
    1701: "var cogScratch = document.createElement",
    1876: "?viewpanel=0 hides the #viewpanel overlay",
    2083: "The server ships the static minimap wall silhouette ONCE",
    2213: "if (PB_MODE) {",
    2234: "}",
    2263: "if (PB_MODE) {",
    2294: "}",
    2347: "---------- pov + mismatch ----------",
    3465: "}",
    3719: "var rows = (s.roster || []).filter",
    3720: ".slice().sort(endcardOrder);",
    3726: "if (PB_MODE) {",
    3741: "}",
    3782: "el.innerHTML = PB_MODE",
    3796: '<div id="ec-rows-\' + team + \'"></div>\';',
    3833: "$('ec-' + team).textContent = PB_MODE",
    3835: ": overLives(o, team);",
    3841: "if (PB_MODE) {",
    3878: "}",
    3955: "$('povBadge').addEventListener",
    4151: "var minimapBox = $('minimap');",
    4244: "minimapBox.addEventListener('pointercancel'",
}


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <path to coworld-ctf checkout>")
    source = os.path.join(sys.argv[1], "client", "replay_broadcast.html")
    with open(source, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    # Check every boundary before touching anything: a starter bump that moved a
    # block must fail here, not produce a broken page.
    for line_no, needle in BOUNDARIES.items():
        actual = lines[line_no - 1]
        if needle not in actual:
            raise SystemExit(
                f"starter drift at line {line_no}: expected {needle!r}, "
                f"got {actual!r}")

    # The paintball game block is everything from its banner to the end of the
    # document; it is REPLACED, because the paintball rules leave this repo.
    banner = None
    for i, line in enumerate(lines):
        if "PAINTBALL additions to the inherited coworld-ctf chrome" in line:
            banner = i - 1        # the "<!-- ====" opener above it
            break
    if banner is None:
        raise SystemExit("could not find the paintball game block banner")

    # Apply the range replacements and the cuts in one pass over the head.
    replacement_at = {start: text for start, _, text in REPLACES}
    drop = set()
    for start, end in CUTS:
        drop.update(range(start, end + 1))
    for start, end, _ in REPLACES:
        drop.update(range(start, end + 1))
    head = []
    for i, line in enumerate(lines[:banner], start=1):
        if i in replacement_at:
            head.append(replacement_at[i])
        if i not in drop:
            head.append(line)
    text = "\n".join(head)

    for needle, replacement, count in EDITS:
        found = text.count(needle)
        if found != count:
            raise SystemExit(
                f"edit matched {found} times, expected {count}: {needle[:70]!r}")
        text = text.replace(needle, replacement)

    # Put the view-controls stub back where the cut removed syncViewUi.
    marker = "  canvas.addEventListener('dblclick', function (ev) {"
    if text.count(marker) != 1:
        raise SystemExit("could not anchor the view-controls stub")
    text = text.replace(marker, VIEW_UI_STUB + "\n" + marker)

    with open(os.path.join(REPO, "scripts", "waterworld_block.html"),
              encoding="utf-8") as fh:
        block = fh.read()

    # Checked on the INHERITED half only: the appended block's own banner
    # names the removed elements in prose, which is documentation, not markup.
    for banned in ('id="fpv"', 'id="viewpanel"', 'id="povBadge"',
                   'id="minimap"', 'id="zoombar"', 'id="fpv-canvas"',
                   'id="zoom-slider"', "#povBadge {", "#viewpanel {", "#fpv {",
                   "#minimap {", "#zoombar {", "$('povBadge')", "$('minimap')",
                   "$('zoom-in')", "$('fpv')", "PaintballChrome", "PB_MODE",
                   "PB_CTX", "CtfStaticReplay"):
        if banned in text:
            raise SystemExit(f"removed element survived the fork: {banned}")

    out = text.rstrip("\n") + "\n" + block
    with open(os.path.join(REPO, "client", "replay_broadcast.html"), "w",
              encoding="utf-8") as fh:
        fh.write(out)
    print(f"client/replay_broadcast.html: {len(out.splitlines())} lines")


if __name__ == "__main__":
    main()
