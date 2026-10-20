## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "walker-waterworld-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  result = selection.selectionMetadata()
  result["system_sha256"] = %sha256(system).toHex
  result["user_sha256"] = %sha256(user).toHex

proc briefing*(selection: PromptSelection, canonical: string): string =
  ## Rephrase the task, observations, rewards and timing; the action schema stays fixed.
  case selection.selectedVariant
  of pvCanonical:
    "You are ONE of four thruster drones (\"skimmers\") in a shallow tank seen from\nabove. " & canonical
  of pvPlain:
    """You control one of four thruster drones called skimmers. The shallow tank is
viewed from above. It measures 12.00 m across and 8.00 m vertically, with a
round rock of radius 0.90 m at (6.00, 4.00). Positions are in metres from the
bottom-left: x increases rightward and y upward. Bearings increase
counter-clockwise from east: right 0, up 90, left 180, down 270 degrees.

Work together to catch drifting plankton. A catch requires at least two
skimmers touching the same particle simultaneously and gives everyone +10.
Touching plankton alone gives only +0.05. All four skimmers share the same
score; {capture_target} catches win the run and end it early. Poison blooms drift faster
than plankton: contact costs -2 and stuns you for half a second. Thrust has a
small cost, so coasting is preferable to using full throttle everywhere.

Your 16 sensors reach 2.40 m; plankton and poison outside that range are
invisible. A shared transponder always shows the position, velocity and stun
of each of the other three skimmers. There is no communication between
skimmers, and they cannot see anything you write.

Choose an order every 3 seconds for the next 3 seconds. A deterministic
autopilot executes it 24 times per second, steering, leading moving targets
and backing away from poison. You choose the target and effort.
"""
  of pvNumbered:
    """1. Role and map. You are one of four skimmers (thruster drones) in an
overhead view of a shallow tank. The tank is 12.00 m wide and 8.00 m tall.
Its central round rock has radius 0.90 m and centre (6.00, 4.00). Coordinates
are metres from the bottom-left, x right and y up. Bearings are degrees
counter-clockwise from east: 0 right, 90 up, 180 left, 270 down.

2. Objective. Meet another skimmer on drifting plankton: two or more must
touch the particle at the same instant to catch it for +10 to everyone.
A lone skimmer touching it receives only +0.05. Everyone shares one score.
Reaching {capture_target} catches wins and ends the run early.

3. Costs. Poison blooms drift faster than plankton. Touching poison costs
-2 and causes a half-second stun. Thrust also has a small cost; coasting
beats using full throttle everywhere.

4. Information. Sixteen sensors detect plankton and poison only within
2.40 m. The pod's transponder always reveals the other three skimmers'
positions, velocities and stun states. You cannot communicate with them;
none of them sees what you write.

5. Control. Each order lasts 3 seconds; choose another every 3 seconds.
A deterministic autopilot runs 24 times per second, steering, anticipating
target motion and backing away from poison. Choose what to pursue and how hard.
"""
  of pvQuestions:
    """Who are you? One of four skimmers, which are thruster drones in a shallow
tank viewed from above.

How do you score? Plankton drifts around. Catching a particle requires two
or more skimmers to touch it simultaneously, awarding +10 to everyone.
Touching it alone gives only +0.05. All skimmers receive the same score.
{capture_target} catches win the run and finish it early.

What should you avoid? Faster-drifting poison blooms: touching one costs
-2 and stuns you for half a second. Thrust costs a small amount too, so
coasting is better than running at full throttle everywhere.

What can you perceive? Your 16 sensors reach 2.40 m. Plankton and poison
beyond that distance are invisible. The shared transponder always supplies
the other three skimmers' positions, velocities and stun states. There is
no way to talk to them, and none can read anything you write.

Where are things? The tank is 12.00 m wide by 8.00 m tall, with a round rock
of radius 0.90 m at (6.00, 4.00). Coordinates use metres from the bottom-left,
x to the right and y upward. Bearings turn counter-clockwise from east:
0 degrees right, 90 up, 180 left, 270 down.

How do you act? Set an order every 3 seconds for the following 3 seconds.
The deterministic autopilot steers, leads moving targets and backs away
from poison at 24 updates per second. You pick what to seek and how hard.
"""
  of pvReordered:
    """Your order runs for 3 seconds before you choose the next one. A deterministic
autopilot updates 24 times per second to steer, lead moving targets and back
away from poison; you decide what to pursue and how hard.

You are one of four thruster drones, or skimmers, in an overhead view of a
shallow tank. The pod shares one score. To win early, reach {capture_target} catches.
Catch drifting plankton by having at least two skimmers touch the same
particle simultaneously: everyone gets +10. Solo contact gives only +0.05.
Poison blooms drift faster; touching one costs -2 and stuns you for half a
second. Thrust costs a little, making coasting better than full throttle everywhere.

You cannot communicate, and other skimmers cannot see anything you write.
Their positions, velocities and stun states are always visible through the
shared transponder. Plankton and poison, however, are visible only within
the 2.40 m range of your 16 sensors.

The tank measures 12.00 m across and 8.00 m high. A round rock with radius
0.90 m sits at (6.00, 4.00). Coordinates are metres from the bottom-left,
with x pointing right and y up. Bearings are counter-clockwise degrees
from east: right 0, up 90, left 180, down 270.
"""
  of pvHeldoutBriefing:
    """Pilot a skimmer alongside three others. These four thruster drones operate
in a shallow tank shown from overhead. Success is collective: every drone
receives the same score, and the run ends in an early win after {capture_target} catches.
Arrange simultaneous contact by at least two drones with a drifting
plankton particle to capture it for +10. A solitary touch yields just +0.05.
The poison blooms move faster than plankton; contact deducts 2 points and
disables you for half a second. Thrust has a small price as well, so prefer
coasting to continuous full throttle.

Your instruments comprise 16 sensors with 2.40 m reach. They cannot show
plankton or poison farther away. A pod transponder separately provides
unlimited-range positions, velocities and stun states for your three
companions. No messages can pass between skimmers; your writing is unseen
by the others.

Issue a new order every 3 seconds, covering the next 3 seconds. Deterministic
autopilot control runs at 24 updates per second and handles steering,
intercepting moving targets and retreating from poison. Select the goal
and the amount of effort.

Navigate a 12.00 m by 8.00 m tank, width then height, around a circular
0.90 m-radius rock centred at (6.00, 4.00). Metre coordinates start at the
bottom-left with x rightward and y upward. Angle measurements increase
counter-clockwise from east: 0 right, 90 up, 180 left and 270 down.
"""
  of pvHeldoutReference:
    """CONTROL REFERENCE
Command interval and duration: 3 seconds each. Execution: a deterministic
autopilot at 24 updates per second. Its duties are steering, leading moving
targets and backing off poison; your decisions specify pursuit and effort.

WORLD REFERENCE
Role: one of four skimmers (thruster drones). View: overhead, shallow tank.
Extent: width 12.00 m, height 8.00 m. Obstacle: circular rock, radius 0.90 m,
centre (6.00, 4.00). Position units: metres, origin bottom-left, x right,
y up. Bearing convention: degrees counter-clockwise from east; 0 right,
90 up, 180 left, 270 down.

INFORMATION REFERENCE
Plankton/poison detection: 16 sensors, range 2.40 m, no sight beyond range.
Companion tracking: transponder reveals all three other skimmers' positions,
velocities and stun states regardless of distance. Communication: none.
Other skimmers never receive anything you write.

REWARD REFERENCE
Drifting plankton capture: simultaneous contact by two or more skimmers,
+10 for everyone. Lone contact: only +0.05. All four share the same score.
Early victory: {capture_target} catches. Faster-drifting poison blooms: -2 on contact,
plus a half-second stun. Thrust: small cost; coasting outperforms full
throttle everywhere.
"""
  of pvMixed:
    raise newException(Defect, "mixed selection must resolve to a wording")
