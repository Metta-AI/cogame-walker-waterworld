## The board: waterworld's sprite-protocol renderer, plus the per-viewer state
## the server and the wasm viewer both drive it through.
##
## The BOARD is Nim-side. `client/broadcast_core.js` is a dumb compositor: it
## ingests sprite definitions and object placements and blits them, so
## everything a spectator sees on the tank — the water, the rock, the four
## skimmer hulls, the thruster plumes, the SIXTEEN SENSOR RAYS PER SKIMMER, the
## plankton, the poison blooms, the capture rings, the score pops, the speech
## bubbles and the aliases — is baked and placed here. The DOM chrome (scorebug,
## feed, endcard, transport) is the appended game block's job and reads the state
## JSON `broadcast.nim` builds.
##
## Floats are legal in this file: rendering is never hashed, exactly as in the
## starter. What IS load-bearing here is the wire budget — a sprite definition
## rides one websocket message and the hosted replay closes any frame over
## 1 MiB — so the tank floor is ONE tiled 400x400 sprite placed 24 times rather
## than a single 15 MB plate, and every tile/rim object sits in the static-band
## id range (40..99) at z = -32768 so the compositor bakes them into its cached
## base once and never re-composites them.

import std/[json, math, os, strutils, tables]

import pixie
import bitworld/spriteprotocol

import sim_types, sim

const
  MapLayerId* = SpriteLayerMap
  ZoomableLayerFlag* = SpriteLayerZoomableFlag

  BoardW* = MapWidth * RenderScale
  BoardH* = MapHeight * RenderScale
  WaterTilePx = 400
  RimPx = 56

  # --- sprite ids ----------------------------------------------------------
  SpriteWater = 10
  SpriteRimTop = 11
  SpriteRimBottom = 12
  SpriteRimLeft = 13
  SpriteRimRight = 14
  SpriteRock = 20
  SpriteSkimmerBase = 30        ## 30..33
  SpritePlankton = 40
  SpritePoison = 41
  SpriteRayPipBase = 50         ## 50..55, one per RayKind
  SpriteRayHitBase = 60         ## 60..65
  SpritePlume = 70
  SpriteCaptureRing = 71
  SpriteNibbleRing = 72
  SpriteStunPip = 73
  SpriteDash = 74
  SpriteTextBase = 200          ## dynamic text sprites (aliases, pops, bubbles)
  SpriteTextCeiling = 1200

  # --- object ids ----------------------------------------------------------
  ObjWaterBase = 40             ## 40..63, static band
  ObjRimBase = 64               ## 64..67, static band
  StaticBandZ = -32768
  ObjRock = 100
  ObjSkimmerBase = 200
  ObjLabelBase = 210
  ObjStunBase = 220
  ObjPlumeBase = 230            ## 230..241 (3 pips x 4 skimmers)
  ObjPlanktonBase = 300
  ObjPoisonBase = 320
  ObjRingBase = 340
  ObjRayBase = 1000             ## 1000..1383 (4 x 16 x 6)
  ObjFxBase = 1500
  ObjBubbleBase = 1600
  ObjDashBase = 1700

  # --- z order -------------------------------------------------------------
  ZRock = 10
  ZRay = 30
  ZDash = 32
  ZParticle = 40
  ZRing = 42
  ZPlume = 58
  ZSkimmer = 60
  ZLabel = 62
  ZStun = 63
  ZFx = 70
  ZBubble = 80

  # One accent per skimmer, matching the committed nano-banana kits, so the four
  # read apart at board scale without labels: SKIM-1 hot orange, SKIM-2 cyan,
  # SKIM-3 violet, SKIM-4 lime.
  SkimmerTints: array[SkimmerCount, tuple[r, g, b: uint8]] = [
    (255'u8, 122'u8, 47'u8),
    (57'u8, 215'u8, 232'u8),
    (176'u8, 114'u8, 240'u8),
    (217'u8, 226'u8, 74'u8)
  ]

type
  SpriteDefinition* = object
    spriteId*: int
    width*, height*: int
    label*: string

  GlobalViewerState* = object
    ## Everything one spectator connection remembers between frames.
    initialized*: bool
    spriteDefs*: seq[SpriteDefinition]
    objectIds*: seq[int]
    textSpriteIds*: Table[string, int]
    nextTextSpriteId*: int
    momentumSent*: bool
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    replayCommands*: seq[char]
    replaySeekTick*: int

  PlayerViewerState* = ref object
    ## Per-SEAT stream state. The seat's frame is sensor-filtered by the same
    ## predicate the sensor frame uses, so a seat never receives a sprite for a
    ## particle it cannot feel.
    initialized*: bool
    spriteDefs*: seq[SpriteDefinition]
    objectIds*: seq[int]

proc initGlobalViewerState*(): GlobalViewerState =
  result.textSpriteIds = initTable[string, int]()
  result.nextTextSpriteId = SpriteTextBase
  result.replaySeekTick = -1
  result.mouseLayer = -1

proc initPlayerViewerState*(): PlayerViewerState =
  PlayerViewerState()

proc gameDir(): string = getCurrentDir()

# ---------------------------------------------------------------------------
#  Bakes
# ---------------------------------------------------------------------------

var
  bakedSprites: Table[int, tuple[width, height: int, pixels: seq[uint8]]]
  boardTypefaceCache: Typeface

proc boardTypeface(): Typeface =
  if boardTypefaceCache.isNil:
    boardTypefaceCache = readTypeface(gameDir() / "data" / "font.ttf")
  boardTypefaceCache

proc imageToStraightRgba(image: Image): seq[uint8] =
  ## Straight-alpha RGBA bytes for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let c = image.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc loadArt(name: string): Image =
  readImage(gameDir() / "data" / "art" / name)

proc bakeWaterTile(): tuple[width, height: int, pixels: seq[uint8]] =
  ## The tank floor: dark rippled water. Built from the starter's shipped
  ## `data/arena_floor.png` plate, resampled to the tile, deep-tinted, and
  ## cross-faded with its own mirror so the 6x4 tiling has no hard seam.
  let plate = readImage(gameDir() / "data" / "arena_floor.png").resize(
    WaterTilePx, WaterTilePx)
  var tile = newImage(WaterTilePx, WaterTilePx)
  for y in 0 ..< WaterTilePx:
    for x in 0 ..< WaterTilePx:
      # Cross-fade the plate with its own mirror, weighted in toward the tile
      # edges, so the 6x4 tiling has no hard seam.
      let
        a = plate[x, y].rgba()
        b = plate[WaterTilePx - 1 - x, WaterTilePx - 1 - y].rgba()
        fx = float(min(x, WaterTilePx - 1 - x)) / (float(WaterTilePx) * 0.5)
        fy = float(min(y, WaterTilePx - 1 - y)) / (float(WaterTilePx) * 0.5)
        w = clamp(1.0 - min(fx, fy), 0.0, 1.0) * 0.5
        r0 = float(a.r) * (1.0 - w) + float(b.r) * w
        g0 = float(a.g) * (1.0 - w) + float(b.g) * w
        b0 = float(a.b) * (1.0 - w) + float(b.b) * w
        # Deep-water tint: pull the warm arena floor into blue-green.
        lum = (r0 * 0.3 + g0 * 0.5 + b0 * 0.2) / 255.0
      tile[x, y] = rgba(
        uint8(clamp(14.0 + lum * 26.0, 0.0, 255.0)),
        uint8(clamp(38.0 + lum * 70.0, 0.0, 255.0)),
        uint8(clamp(52.0 + lum * 84.0, 0.0, 255.0)),
        255'u8)
  # Caustics: a few soft light bands so the water reads as water in motion.
  var caustics = newImage(WaterTilePx, WaterTilePx)
  for y in 0 ..< WaterTilePx:
    for x in 0 ..< WaterTilePx:
      let
        u = x.float / WaterTilePx.float * 2.0 * PI
        v = y.float / WaterTilePx.float * 2.0 * PI
        band = sin(u * 3.0 + sin(v * 2.0) * 1.4) * sin(v * 3.0 - u * 0.7)
        alpha = clamp((band - 0.55) * 2.2, 0.0, 1.0) * 0.22
      caustics[x, y] = rgba(180, 236, 255, uint8(alpha * 255.0))
  tile.draw(caustics, blendMode = NormalBlend)
  (WaterTilePx, WaterTilePx, imageToStraightRgba(tile))

proc bakeRim(horizontal: bool): tuple[width, height: int, pixels: seq[uint8]] =
  ## The tank rim, from the starter's shipped wall plates. Darkened and faded
  ## inward so the water reads as sunk below a lip.
  # The plates are the starter's shipped wall art, moved under data/ because
  # that is the ONE directory the emscripten build preloads (config.nims:
  # --preload-file data@data) — a bake that read from client/ would work
  # natively and throw in the browser.
  let
    source = readImage(gameDir() / "data" / "art" /
      (if horizontal: "rim_h.jpg" else: "rim_v.jpg"))
    w = if horizontal: BoardW else: RimPx
    h = if horizontal: RimPx else: BoardH
  var image = newImage(w, h)
  image.draw(source.resize(w, h))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let
        inward = if horizontal: y.float / h.float else: x.float / w.float
        edge = min(inward, 1.0 - inward) * 2.0
        c = image[x, y].rgba()
        dim = 0.34 + 0.3 * (1.0 - edge)
      image[x, y] = rgba(
        uint8(c.r.float * dim), uint8(c.g.float * dim), uint8(c.b.float * dim),
        uint8(clamp(255.0 * (1.0 - edge * 0.55), 0.0, 255.0)))
  (w, h, imageToStraightRgba(image))

proc bakeArtSprite(
  name: string, size: int, shadow: bool
): tuple[width, height: int, pixels: seq[uint8]] =
  ## One committed nano-banana render, resized to its board footprint with an
  ## optional soft contact shadow underneath.
  var art = loadArt(name).resize(size, size)
  var image = newImage(size, size)
  if shadow:
    var shade = newImage(size, size)
    let r = size.float * 0.46
    for y in 0 ..< size:
      for x in 0 ..< size:
        let
          dx = (x.float - size.float / 2.0) / r
          dy = (y.float - size.float / 2.0 - size.float * 0.06) / (r * 0.92)
          d = sqrt(dx * dx + dy * dy)
          alpha = clamp((1.0 - d) * 1.4, 0.0, 1.0) * 0.42
        shade[x, y] = rgba(0, 0, 0, uint8(alpha * 255.0))
    image.draw(shade)
  image.draw(art)
  (size, size, imageToStraightRgba(image))

proc bakeDisc(
  size: int, r, g, b: uint8, alpha: float, ring: bool
): tuple[width, height: int, pixels: seq[uint8]] =
  var image = newImage(size, size)
  let radius = size.float / 2.0
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        dx = x.float - radius + 0.5
        dy = y.float - radius + 0.5
        d = sqrt(dx * dx + dy * dy) / radius
      var a =
        if ring:
          clamp(1.0 - abs(d - 0.82) * 9.0, 0.0, 1.0)
        else:
          clamp((1.0 - d) * 2.6, 0.0, 1.0)
      a = a * alpha
      image[x, y] = rgba(r, g, b, uint8(clamp(a * 255.0, 0.0, 255.0)))
  (size, size, imageToStraightRgba(image))

proc rayColour(kind: RayKind): tuple[r, g, b: uint8] =
  case kind
  of rkClear: (118'u8, 140'u8, 156'u8)      ## dim slate
  of rkFood: (140'u8, 240'u8, 168'u8)       ## green
  of rkPoison: (208'u8, 72'u8, 168'u8)      ## magenta
  of rkCog: (242'u8, 232'u8, 216'u8)        ## white
  of rkRock: (150'u8, 142'u8, 130'u8)       ## grey
  of rkWall: (120'u8, 116'u8, 110'u8)       ## grey

proc rayAlpha(kind: RayKind): float =
  ## A CLEAR ray is drawn dim and short so the 360 px featured-match frame
  ## stays legible: the spoke set has to read as an outline of what the skimmer
  ## can feel, not as a starburst that hides the tank.
  if kind == rkClear: 0.30 else: 0.95

proc bakedSprite(
  spriteId: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Bakes one static sprite on first use and caches it for the process. Called
  ## from the frame builder, so the FIRST frame a viewer gets pays the bake —
  ## which is why the server warms them all before it opens its listener.
  if bakedSprites.hasKey(spriteId):
    return bakedSprites[spriteId]
  var baked: tuple[width, height: int, pixels: seq[uint8]]
  case spriteId
  of SpriteWater: baked = bakeWaterTile()
  of SpriteRimTop, SpriteRimBottom: baked = bakeRim(true)
  of SpriteRimLeft, SpriteRimRight: baked = bakeRim(false)
  of SpriteRock:
    baked = bakeArtSprite("rock.png",
      int(RockRadius div BoardScaleUm) * 2 * RenderScale, shadow = true)
  of SpritePlankton:
    baked = bakeArtSprite("plankton.png",
      int(FoodRadius div BoardScaleUm) * 2 * RenderScale, shadow = false)
  of SpritePoison:
    baked = bakeArtSprite("poison.png",
      int(PoisonRadius div BoardScaleUm) * 2 * RenderScale, shadow = false)
  of SpriteSkimmerBase .. SpriteSkimmerBase + SkimmerCount - 1:
    baked = bakeArtSprite("skim_" & $(spriteId - SpriteSkimmerBase + 1) & ".png",
      int(SkimmerRadius div BoardScaleUm) * 2 * RenderScale, shadow = true)
  of SpriteRayPipBase .. SpriteRayPipBase + ord(high(RayKind)):
    let kind = RayKind(spriteId - SpriteRayPipBase)
    let tint = rayColour(kind)
    baked = bakeDisc(8, tint.r, tint.g, tint.b, rayAlpha(kind), ring = false)
  of SpriteRayHitBase .. SpriteRayHitBase + ord(high(RayKind)):
    let kind = RayKind(spriteId - SpriteRayHitBase)
    let tint = rayColour(kind)
    baked = bakeDisc(18, tint.r, tint.g, tint.b, rayAlpha(kind), ring = false)
  of SpritePlume: baked = bakeDisc(14, 190, 232, 255, 0.72, ring = false)
  of SpriteCaptureRing:
    baked = bakeDisc(int(FoodRadius div BoardScaleUm) * 6 * RenderScale,
      140, 240, 168, 0.95, ring = true)
  of SpriteNibbleRing:
    baked = bakeDisc(int(FoodRadius div BoardScaleUm) * 4 * RenderScale,
      232, 208, 120, 0.7, ring = true)
  of SpriteStunPip: baked = bakeDisc(16, 208, 72, 168, 0.9, ring = true)
  of SpriteDash: baked = bakeDisc(8, 242, 232, 216, 0.45, ring = false)
  else:
    baked = bakeDisc(4, 255, 255, 255, 0.0, ring = false)
  bakedSprites[spriteId] = baked
  baked

proc textSprite(
  lines: openArray[string], r, g, b: uint8, lineHeightPx: int
): tuple[width, height: int, pixels: seq[uint8]] =
  ## Board text in the shipped face (`data/font.ttf`, the same face the DOM
  ## chrome uses), with a soft dark drop shadow so thin strokes stay legible
  ## over the water.
  let
    face = boardTypeface()
    font = newFont(face)
    lineBox = float32(lineHeightPx)
  font.size = lineBox / 1.2
  font.lineHeight = lineBox
  var textW = 1.0'f32
  for line in lines:
    textW = max(textW, font.layoutBounds(line).x)
  let
    pad = 3
    outW = int(ceil(textW)) + pad * 2
    outH = max(1, lines.len * lineHeightPx + lineHeightPx div 3)
  var image = newImage(max(1, outW), outH)
  for i, line in lines:
    let ty = float32(i * lineHeightPx)
    font.paint = newPaint(SolidPaint)
    font.paint.color = color(0, 0, 0, 0.72)
    image.fillText(font, line, translate(vec2(float32(pad) + 1.5, ty + 1.5)))
    font.paint = newPaint(SolidPaint)
    font.paint.color = color(float32(r) / 255, float32(g) / 255,
      float32(b) / 255, 1)
    image.fillText(font, line, translate(vec2(float32(pad), ty)))
  (image.width, image.height, imageToStraightRgba(image))

proc bubbleSprite(
  text: string, r, g, b: uint8
): tuple[width, height: int, pixels: seq[uint8]] =
  ## A speech bubble: rounded paper pill, tinted outline, the line set in the
  ## board face. Drawn in the RESERVED BAND at the top of the tank and never
  ## positioned relative to a skimmer, which is the reservation the
  ## text-out-of-bounds scar demands.
  let
    face = boardTypeface()
    font = newFont(face)
    lineBox = 26.0'f32
  font.size = lineBox / 1.15
  font.lineHeight = lineBox
  let
    textW = font.layoutBounds(text).x
    padX = 12
    padY = 6
    pillW = int(ceil(textW)) + padX * 2
    pillH = int(lineBox) + padY * 2
  var image = newImage(max(24, pillW), pillH)
  var pill = newPath()
  pill.roundedRect(rect(1.5, 1.5, float32(image.width) - 3.0,
    float32(pillH) - 3.0), 8, 8, 8, 8)
  image.fillPath(pill, color(0.96, 0.945, 0.918, 0.94))
  image.strokePath(pill, color(float32(r) / 255, float32(g) / 255,
    float32(b) / 255, 1), strokeWidth = 3.0)
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(0.12, 0.09, 0.08, 1)
  image.fillText(font, text, translate(vec2(float32(padX), float32(padY) - 2.0)))
  (image.width, image.height, imageToStraightRgba(image))

proc warmBoardRenderCaches*() =
  ## Bakes every static sprite BEFORE the listener opens: a viewer's
  ## first-message clock starts at its successful connect and the coworld
  ## certifier allows only seconds, so nothing may be accepted until every frame
  ## the loop will ever build can be assembled instantly.
  discard bakedSprite(SpriteWater)
  discard bakedSprite(SpriteRimTop)
  discard bakedSprite(SpriteRimLeft)
  discard bakedSprite(SpriteRock)
  discard bakedSprite(SpritePlankton)
  discard bakedSprite(SpritePoison)
  for i in 0 ..< SkimmerCount:
    discard bakedSprite(SpriteSkimmerBase + i)
  for kind in RayKind:
    discard bakedSprite(SpriteRayPipBase + ord(kind))
    discard bakedSprite(SpriteRayHitBase + ord(kind))
  discard bakedSprite(SpritePlume)
  discard bakedSprite(SpriteCaptureRing)
  discard bakedSprite(SpriteNibbleRing)
  discard bakedSprite(SpriteStunPip)
  discard bakedSprite(SpriteDash)
  discard boardTypeface()

# ---------------------------------------------------------------------------
#  Emission helpers
# ---------------------------------------------------------------------------

proc defineIndex(defs: openArray[SpriteDefinition], spriteId: int): int =
  for i in 0 ..< defs.len:
    if defs[i].spriteId == spriteId:
      return i
  -1

proc addSpriteOnce(
  packet: var seq[uint8], defs: var seq[SpriteDefinition],
  spriteId: int, baked: tuple[width, height: int, pixels: seq[uint8]],
  label: string
) =
  ## One sprite definition per viewer per sprite. Every sprite carries a
  ## non-empty label: the inspector and the bot readers both key off it, and an
  ## empty label silently re-sends forever.
  doAssert label.len > 0, "sprite " & $spriteId & " needs a non-empty label"
  let index = defs.defineIndex(spriteId)
  if index >= 0 and defs[index].width == baked.width and
      defs[index].height == baked.height and defs[index].label == label:
    return
  if index >= 0:
    defs[index].width = baked.width
    defs[index].height = baked.height
    defs[index].label = label
  else:
    defs.add SpriteDefinition(spriteId: spriteId, width: baked.width,
      height: baked.height, label: label)
  packet.addSprite(spriteId, baked.width, baked.height, baked.pixels, label)

proc addStatic(
  packet: var seq[uint8], defs: var seq[SpriteDefinition],
  spriteId: int, label: string
) =
  packet.addSpriteOnce(defs, spriteId, bakedSprite(spriteId), label)

proc boardX(um: int32): int = int((int64(um) * int64(RenderScale)) div int64(BoardScaleUm))
proc boardY(um: int32): int = int((int64(um) * int64(RenderScale)) div int64(BoardScaleUm))

proc place(
  packet: var seq[uint8], ids: var seq[int],
  objectId, centreX, centreY, z, spriteId, w, h: int
) =
  ## Objects are placed by their TOP-LEFT corner, so everything on the tank is
  ## centred here rather than at each call site.
  ids.add(objectId)
  packet.addObject(objectId, centreX - w div 2, centreY - h div 2, z,
    MapLayerId, spriteId)

proc textSpriteIdFor(
  packet: var seq[uint8], state: var GlobalViewerState,
  key: string, lines: openArray[string], r, g, b: uint8, lineHeightPx: int
): tuple[id, w, h: int] =
  ## Text sprites are keyed by content: an alias never re-bakes, a score pop
  ## bakes once per value, and a bubble bakes once per line. The id pool wraps
  ## rather than growing without bound.
  let baked = textSprite(lines, r, g, b, lineHeightPx)
  if state.textSpriteIds.hasKey(key):
    let id = state.textSpriteIds[key]
    packet.addSpriteOnce(state.spriteDefs, id, baked, key)
    return (id, baked.width, baked.height)
  if state.nextTextSpriteId >= SpriteTextCeiling:
    state.nextTextSpriteId = SpriteTextBase
    state.textSpriteIds.clear()
  let id = state.nextTextSpriteId
  inc state.nextTextSpriteId
  state.textSpriteIds[key] = id
  packet.addSpriteOnce(state.spriteDefs, id, baked, key)
  (id, baked.width, baked.height)

proc bubbleSpriteIdFor(
  packet: var seq[uint8], state: var GlobalViewerState,
  text: string, tint: tuple[r, g, b: uint8]
): tuple[id, w, h: int] =
  let
    key = "bubble\x1f" & $tint.r & "\x1f" & text
    baked = bubbleSprite(text, tint.r, tint.g, tint.b)
  if state.textSpriteIds.hasKey(key):
    let id = state.textSpriteIds[key]
    packet.addSpriteOnce(state.spriteDefs, id, baked, key)
    return (id, baked.width, baked.height)
  if state.nextTextSpriteId >= SpriteTextCeiling:
    state.nextTextSpriteId = SpriteTextBase
    state.textSpriteIds.clear()
  let id = state.nextTextSpriteId
  inc state.nextTextSpriteId
  state.textSpriteIds[key] = id
  packet.addSpriteOnce(state.spriteDefs, id, baked, key)
  (id, baked.width, baked.height)

proc addBoardInit(packet: var seq[uint8], state: var GlobalViewerState) =
  ## The board's one-time chrome: the layer, the viewport, the tiled water and
  ## the rim. Every one of these objects is a STATIC BAND (id 40..99,
  ## z = -32768), which is what lets the compositor bake them into its cached
  ## base and never re-composite them.
  packet.addLayer(MapLayerId, 0, ZoomableLayerFlag)
  packet.addViewport(MapLayerId, BoardW, BoardH)
  packet.addStatic(state.spriteDefs, SpriteWater, "tank water")
  var objectId = ObjWaterBase
  var y = 0
  while y < BoardH:
    var x = 0
    while x < BoardW:
      packet.addObject(objectId, x, y, StaticBandZ, MapLayerId, SpriteWater)
      inc objectId
      x += WaterTilePx
    y += WaterTilePx
  packet.addStatic(state.spriteDefs, SpriteRimTop, "tank rim top")
  packet.addStatic(state.spriteDefs, SpriteRimBottom, "tank rim bottom")
  packet.addStatic(state.spriteDefs, SpriteRimLeft, "tank rim side left")
  packet.addStatic(state.spriteDefs, SpriteRimRight, "tank rim side right")
  packet.addObject(ObjRimBase, 0, 0, StaticBandZ, MapLayerId, SpriteRimTop)
  packet.addObject(ObjRimBase + 1, 0, BoardH - RimPx, StaticBandZ, MapLayerId,
    SpriteRimBottom)
  packet.addObject(ObjRimBase + 2, 0, 0, StaticBandZ, MapLayerId, SpriteRimLeft)
  packet.addObject(ObjRimBase + 3, BoardW - RimPx, 0, StaticBandZ, MapLayerId,
    SpriteRimRight)

proc addRays(
  packet: var seq[uint8], ids: var seq[int], sim: SimServer, i: int,
  frame: SensorFrame
) =
  ## THE IDEA'S EXPLICIT REPLAY PLAN, and a first-class readout: all sixteen
  ## rays per skimmer, drawn as dotted 2.40 m spokes whose length IS the hit
  ## distance and whose colour is what the ray found. The spoke set reads as a
  ## live outline of what that skimmer can feel.
  let
    cx = boardX(sim.skimmers[i].x)
    cy = boardY(sim.skimmers[i].y)
  for n in 0 ..< SensorCount:
    let
      ray = frame.rays[n]
      dir = n * 2
      ux = float(DirQ12[dir].x) / float(Q12)
      uy = float(DirQ12[dir].y) / float(Q12)
      hitPx = float(ray.distUm) * float(RenderScale) / float(BoardScaleUm)
      pips = if ray.kind == rkClear: 3 else: 5
      pipSprite = SpriteRayPipBase + ord(ray.kind)
      baseId = ObjRayBase + (i * SensorCount + n) * 6
    for k in 1 .. pips:
      let t = hitPx * float(k) / float(pips + 1)
      packet.place(ids, baseId + k - 1,
        cx + int(ux * t), cy + int(uy * t), ZRay, pipSprite, 8, 8)
    if ray.kind != rkClear:
      let hitId = SpriteRayHitBase + ord(ray.kind)
      packet.place(ids, baseId + 5,
        cx + int(ux * hitPx), cy + int(uy * hitPx), ZRay, hitId, 18, 18)

proc addFx(
  packet: var seq[uint8], ids: var seq[int], state: var GlobalViewerState,
  sim: SimServer
) =
  ## Score pops and the near-miss flash, for a bounded window after the tick
  ## they happened on.
  var slot = 0
  for fx in sim.fx:
    let age = sim.tickCount - fx.tick
    if age < 0 or age > TargetFps or slot >= 16:
      continue
    let rise = age * 2
    case fx.kind
    of fxCapture:
      let text = packet.textSpriteIdFor(state, "pop+10", ["+10"],
        140, 240, 168, 34)
      packet.place(ids, ObjFxBase + slot, boardX(fx.x), boardY(fx.y) - rise,
        ZFx, text.id, text.w, text.h)
    of fxNibble:
      let text = packet.textSpriteIdFor(state, "pop+0.05", ["+0.05"],
        232, 208, 120, 24)
      packet.place(ids, ObjFxBase + slot, boardX(fx.x), boardY(fx.y) - rise,
        ZFx, text.id, text.w, text.h)
    of fxPoison:
      let text = packet.textSpriteIdFor(state, "pop-2", ["-2"],
        232, 96, 168, 34)
      packet.place(ids, ObjFxBase + slot, boardX(fx.x), boardY(fx.y) - rise,
        ZFx, text.id, text.w, text.h)
    of fxNearMiss:
      let text = packet.textSpriteIdFor(state, "popmiss", ["SO CLOSE"],
        242, 232, 216, 22)
      packet.place(ids, ObjFxBase + slot, boardX(fx.x), boardY(fx.y) - rise,
        ZFx, text.id, text.w, text.h)
    inc slot

proc bubbleBandCentreY*(): int =
  ## The board y the bubble pills are centred on: the reserved band at the top
  ## of the tank, view Y 7.50 m. Exported because tools/ci/renderer_fixture.html
  ## reproduces the band by hand and tests/test_viewer.nim pins its numbers
  ## against this one.
  int((int64(ArenaH - 7_500_000) * int64(RenderScale)) div int64(BoardScaleUm))

proc bubblePillHeight*(): int =
  ## The pill's height in board pixels: one 26 px line box plus 6 px of padding
  ## above and below, as `bubbleSprite` builds it.
  26 + 6 * 2

proc bubbleSlotX*(slot, slots, spriteW: int): int =
  ## The centre x of one bubble slot, CLAMPED so a wide pill cannot hang off
  ## either edge of the board. `place()` subtracts half the sprite width, and a
  ## canvas accepts a negative coordinate without complaint, so an unclamped
  ## centre is how a full-cap `say` becomes an invisible sliver. The clamp is
  ## the reason this does not depend on the font's advance widths.
  let centre = BoardW * (slot * 2 + 1) div (slots * 2)
  if spriteW >= BoardW:
    BoardW div 2
  else:
    clamp(centre, spriteW div 2, BoardW - spriteW div 2)

proc addBubbles(
  packet: var seq[uint8], ids: var seq[int], state: var GlobalViewerState,
  sim: SimServer
) =
  ## At most THREE bubbles at a time, drawn in a reserved band at the top of the
  ## tank (view Y 7.10 .. 7.85 m) and never positioned relative to a skimmer.
  ## The band is sized from MaxSayRunes measured in the board face, which is
  ## what makes `viewer_smoke.mjs --strict-text-bounds` pass on a fixed tank.
  var slot = 0
  let bandY = bubbleBandCentreY()
  for bubble in sim.bubbles:
    if bubble.untilTick <= sim.tickCount or slot >= 3:
      continue
    let
      tint = SkimmerTints[clamp(int(bubble.skimmer), 0, SkimmerCount - 1)]
      sprite = packet.bubbleSpriteIdFor(state, bubble.text, tint)
      slots = 3
      cx = bubbleSlotX(slot, slots, sprite.w)
    packet.place(ids, ObjBubbleBase + slot, cx, bandY, ZBubble,
      sprite.id, sprite.w, sprite.h)
    inc slot

proc addSkimmers(
  packet: var seq[uint8], ids: var seq[int], state: var GlobalViewerState,
  sim: SimServer
) =
  for i in 0 ..< SkimmerCount:
    let
      s = sim.skimmers[i]
      cx = boardX(s.x)
      cy = boardY(s.y)
      size = int(SkimmerRadius div BoardScaleUm) * 2 * RenderScale
      decoded = decodeThrust(s.cmd)
    # The thruster plume: length and direction read the COMMAND BYTE, which is
    # what makes continuous control visible on the board.
    let pipCount =
      if decoded.level <= 0: 0
      elif decoded.level <= 2: 1
      elif decoded.level <= 5: 2
      else: 3
    for k in 0 ..< 3:
      if k >= pipCount:
        continue
      let
        ux = -float(DirQ12[int(decoded.dir)].x) / float(Q12)
        uy = -float(DirQ12[int(decoded.dir)].y) / float(Q12)
        offset = float(size) * 0.42 + float(k) * 13.0
      packet.place(ids, ObjPlumeBase + i * 3 + k,
        cx + int(ux * offset), cy + int(uy * offset), ZPlume, SpritePlume, 14, 14)
    packet.place(ids, ObjSkimmerBase + i, cx, cy, ZSkimmer,
      SpriteSkimmerBase + i, size, size)
    # The board label is the ANONYMOUS alias and nothing else — one of the two
    # name spaces. Real policy names live only in the DOM chrome and the results.
    let tint = SkimmerTints[i]
    let label = packet.textSpriteIdFor(state, "alias\x1f" & skimmerAlias(i),
      [skimmerAlias(i)], tint.r, tint.g, tint.b, 22)
    packet.place(ids, ObjLabelBase + i, cx, cy - size div 2 - 14, ZLabel,
      label.id, label.w, label.h)
    if s.stun > 0:
      packet.place(ids, ObjStunBase + i, cx, cy + size div 2 + 12, ZStun,
        SpriteStunPip, 16, 16)

proc addParticles(packet: var seq[uint8], ids: var seq[int], sim: SimServer) =
  for f in 0 ..< sim.config.foodCount:
    let p = sim.food[f]
    if p.state != psLive:
      continue
    let size = int(FoodRadius div BoardScaleUm) * 2 * RenderScale
    packet.place(ids, ObjPlanktonBase + f, boardX(p.x), boardY(p.y),
      ZParticle, SpritePlankton, size, size)
    # A PULSING DOUBLE RING the instant two skimmers hold it; a single thin
    # ring for a lone holder, so a spectator sees "one is not enough" without
    # being told.
    var holders = 0
    for i in 0 ..< SkimmerCount:
      if withinUm(sim.skimmers[i].x, sim.skimmers[i].y, p.x, p.y,
          SkimmerRadius + FoodRadius):
        inc holders
    if holders >= sim.config.coopNeeded:
      let ringSize = int(FoodRadius div BoardScaleUm) * 6 * RenderScale
      packet.place(ids, ObjRingBase + f, boardX(p.x), boardY(p.y), ZRing,
        SpriteCaptureRing, ringSize, ringSize)
    elif holders == 1:
      let ringSize = int(FoodRadius div BoardScaleUm) * 4 * RenderScale
      packet.place(ids, ObjRingBase + f, boardX(p.x), boardY(p.y), ZRing,
        SpriteNibbleRing, ringSize, ringSize)
  for q in 0 ..< sim.config.poisonCount:
    let p = sim.poison[q]
    if p.state != psLive:
      continue
    let size = int(PoisonRadius div BoardScaleUm) * 2 * RenderScale
    packet.place(ids, ObjPoisonBase + q, boardX(p.x), boardY(p.y),
      ZParticle, SpritePoison, size, size)

proc addRendezvousLines(
  packet: var seq[uint8], ids: var seq[int], sim: SimServer,
  escorts: openArray[int]
) =
  ## A thin dashed line from a skimmer to the partner it is escorting, read off
  ## the intent records — so a spectator sees the rendezvous being attempted
  ## before it lands.
  for i in 0 ..< SkimmerCount:
    if i >= escorts.len or escorts[i] < 0 or escorts[i] >= SkimmerCount:
      continue
    let
      ax = boardX(sim.skimmers[i].x)
      ay = boardY(sim.skimmers[i].y)
      bx = boardX(sim.skimmers[escorts[i]].x)
      by = boardY(sim.skimmers[escorts[i]].y)
    for k in 1 .. 8:
      let t = float(k) / 9.0
      packet.place(ids, ObjDashBase + i * 8 + k - 1,
        ax + int(float(bx - ax) * t), ay + int(float(by - ay) * t),
        ZDash, SpriteDash, 8, 8)

proc escortTargets(sim: SimServer): seq[int] =
  ## Which skimmer each skimmer is escorting this turn, from the `intent`
  ## records the feed already carries. Presentation only.
  result = newSeq[int](SkimmerCount)
  for i in 0 ..< SkimmerCount:
    result[i] = -1
  for record in sim.feedIntents:
    try:
      let node = parseJson(record)
      if node{"mode"}.getStr() != "escort":
        continue
      let skimmer = int(node{"skimmer"}.getInt())
      let partner = node{"partner"}.getStr()
      if skimmer < 0 or skimmer >= SkimmerCount:
        continue
      for j in 0 ..< SkimmerCount:
        if skimmerAlias(j) == partner:
          result[skimmer] = j
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
#  The spectator board
# ---------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Viewer input: transport commands, seeks and clicks arrive on the same
  ## binary channel the board goes out on.
  for item in parseSpriteClientMessages(message):
    case item.kind
    of SpriteClientChatMessage:
      let text = item.text.strip()
      if text.len == 0:
        discard
      elif text.len > 2 and text[0] == 's' and text[1] == ':':
        try:
          state.replaySeekTick = parseInt(text[2 .. ^1])
        except ValueError:
          discard
      elif text.len > 2 and text[0] == 'v' and text[1] == ':':
        discard                       ## no POV lens in waterworld
      else:
        for ch in text:
          state.replayCommands.add(ch)
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      if item.hasLayer:
        state.mouseLayer = item.layer
    of SpriteClientMouseButtonMessage:
      state.mouseDown = item.down
      if item.down:
        state.clickPending = true
    else:
      discard

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  replayTick = -1,
  replayPlaying = false,
  replaySpeed = 1,
  replayMaxTick = -1,
  replayLooping = false,
  replayEnabled = false,
  replayMismatchTick = -1
): seq[uint8] =
  ## One spectator frame: the board objects, then the chrome sprite.
  result = @[]
  nextState = state
  nextState.replayCommands.setLen(0)
  nextState.replaySeekTick = -1
  nextState.clickPending = false
  if not nextState.initialized:
    result.addBoardInit(nextState)
    nextState.initialized = true

  var currentIds: seq[int] = @[]
  result.addStatic(nextState.spriteDefs, SpriteRock, "rock")
  let rockSize = int(RockRadius div BoardScaleUm) * 2 * RenderScale
  result.place(currentIds, ObjRock, boardX(RockCentreX), boardY(RockCentreY),
    ZRock, SpriteRock, rockSize, rockSize)
  result.addStatic(nextState.spriteDefs, SpritePlankton, "plankton")
  result.addStatic(nextState.spriteDefs, SpritePoison, "poison bloom")
  result.addStatic(nextState.spriteDefs, SpritePlume, "thruster plume")
  result.addStatic(nextState.spriteDefs, SpriteCaptureRing, "capture ring")
  result.addStatic(nextState.spriteDefs, SpriteNibbleRing, "nibble ring")
  result.addStatic(nextState.spriteDefs, SpriteStunPip, "stun pip")
  result.addStatic(nextState.spriteDefs, SpriteDash, "rendezvous dash")
  for kind in RayKind:
    result.addStatic(nextState.spriteDefs, SpriteRayPipBase + ord(kind),
      "sensor ray " & $kind)
    result.addStatic(nextState.spriteDefs, SpriteRayHitBase + ord(kind),
      "sensor hit " & $kind)
  for i in 0 ..< SkimmerCount:
    result.addStatic(nextState.spriteDefs, SpriteSkimmerBase + i,
      "skimmer " & skimmerAlias(i))

  for i in 0 ..< SkimmerCount:
    result.addRays(currentIds, sim, i, sim.frameFor(i))
  result.addRendezvousLines(currentIds, sim, sim.escortTargets())
  result.addParticles(currentIds, sim)
  result.addSkimmers(currentIds, nextState, sim)
  result.addFx(currentIds, nextState, sim)
  result.addBubbles(currentIds, nextState, sim)

  for objectId in state.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc addChromeSprite*(
  packet: var seq[uint8], stateJson: string
) =
  ## The chrome rides the SAME binary channel as the board, as the label of a
  ## reserved never-drawn 1x1 sprite — because that is the ONLY channel that
  ## survives a hosted replay.
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0], stateJson)

# ---------------------------------------------------------------------------
#  The per-seat stream
# ---------------------------------------------------------------------------

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  seat: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState
): seq[uint8] =
  ## What ONE SEAT sees: the tank, the rock, its own skimmer with its sixteen
  ## rays, the other three skimmers (the transponder) and plankton/poison ONLY
  ## while their centres are within the sensor range of this skimmer's centre.
  ## Everything else is dark. Board labels carry only SKIM-n — a seat never
  ## receives a real policy name on any channel.
  result = @[]
  nextState = if state.isNil: initPlayerViewerState() else: state
  if not nextState.initialized:
    result.addLayer(MapLayerId, 0, ZoomableLayerFlag)
    result.addViewport(MapLayerId, BoardW, BoardH)
    result.addStatic(nextState.spriteDefs, SpriteWater, "tank water")
    var objectId = ObjWaterBase
    var y = 0
    while y < BoardH:
      var x = 0
      while x < BoardW:
        result.addObject(objectId, x, y, StaticBandZ, MapLayerId, SpriteWater)
        inc objectId
        x += WaterTilePx
      y += WaterTilePx
    nextState.initialized = true
  let
    skimmer = sim.skimmerForSeat(seat)
    frame = sim.frameFor(max(0, skimmer))
  var currentIds: seq[int] = @[]
  result.addStatic(nextState.spriteDefs, SpriteRock, "rock")
  let rockSize = int(RockRadius div BoardScaleUm) * 2 * RenderScale
  result.place(currentIds, ObjRock, boardX(RockCentreX), boardY(RockCentreY),
    ZRock, SpriteRock, rockSize, rockSize)
  result.addStatic(nextState.spriteDefs, SpritePlankton, "plankton")
  result.addStatic(nextState.spriteDefs, SpritePoison, "poison bloom")
  for kind in RayKind:
    result.addStatic(nextState.spriteDefs, SpriteRayPipBase + ord(kind),
      "sensor ray " & $kind)
    result.addStatic(nextState.spriteDefs, SpriteRayHitBase + ord(kind),
      "sensor hit " & $kind)
  for i in 0 ..< SkimmerCount:
    result.addStatic(nextState.spriteDefs, SpriteSkimmerBase + i,
      "skimmer " & skimmerAlias(i))
  if skimmer >= 0:
    result.addRays(currentIds, sim, skimmer, frame)
  # The transponder: every skimmer, at any range.
  for i in 0 ..< SkimmerCount:
    let
      s = sim.skimmers[i]
      size = int(SkimmerRadius div BoardScaleUm) * 2 * RenderScale
    result.place(currentIds, ObjSkimmerBase + i, boardX(s.x), boardY(s.y),
      ZSkimmer, SpriteSkimmerBase + i, size, size)
  # Prey: only what THIS skimmer can feel.
  for det in frame.food:
    let size = int(FoodRadius div BoardScaleUm) * 2 * RenderScale
    result.place(currentIds, ObjPlanktonBase + int(det.index),
      boardX(det.x), boardY(det.y), ZParticle, SpritePlankton, size, size)
  for det in frame.poison:
    let size = int(PoisonRadius div BoardScaleUm) * 2 * RenderScale
    result.place(currentIds, ObjPoisonBase + int(det.index),
      boardX(det.x), boardY(det.y), ZParticle, SpritePoison, size, size)
  for objectId in nextState.objectIds:
    if objectId notin currentIds:
      result.addDeleteObject(objectId)
  nextState.objectIds = currentIds

proc chunkSpritePacket*(
  packet: openArray[uint8], maxBytes: int
): seq[seq[uint8]] =
  ## Splits one packet into websocket-frame-sized chunks AT MESSAGE BOUNDARIES:
  ## the hosted replay viewer closes any frame over 1 MiB, and the client
  ## accumulates sprite/object state across binary messages, so N chunks are
  ## equivalent to one packet.
  var
    offset = 0
    current: seq[uint8] = @[]
  while offset < packet.len:
    let size = spriteMessageBytes(packet, offset)
    if size <= 0:
      break
    if current.len > 0 and current.len + size > maxBytes:
      result.add(current)
      current = @[]
    for i in offset ..< min(offset + size, packet.len):
      current.add(packet[i])
    offset += size
  if current.len > 0:
    result.add(current)
