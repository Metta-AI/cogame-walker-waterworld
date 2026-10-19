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
  PromptBankVersion* = "walker-waterworld-rules-v1"

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

proc introduction*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical:
    "You are ONE of four thruster drones (\"skimmers\") in a shallow tank seen from\nabove. "
  of pvPlain:
    "Four thruster drones, called skimmers, share a shallow tank viewed from above. You control one skimmer. "
  of pvNumbered:
    "Setting: a shallow tank viewed from above. Participants: four thruster drones called skimmers. Your role: one skimmer. "
  of pvQuestions:
    "Where are you? A shallow tank seen from above. Who participates? Four thruster drones called skimmers; you are one. "
  of pvReordered:
    "In this overhead view of a shallow tank, you play one of four skimmers: thruster drones. "
  of pvHeldoutBriefing:
    "Your briefing: pilot one skimmer, a thruster drone, among four in a shallow tank viewed from above. "
  of pvHeldoutReference:
    "Scenario reference: shallow tank, overhead view, four thruster drones known as skimmers. You play one drone. "
  of pvMixed:
    raise newException(Defect, "mixed selection must resolve to a wording")
