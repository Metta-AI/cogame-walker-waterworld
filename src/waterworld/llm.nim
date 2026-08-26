## Claude-backed skimmer orders. A policy is just a prompt: the game server
## composes the seat's sensor frame plus that seat's PLAYER_PROMPT and asks
## Claude what its skimmer goes for over the next 3.0 seconds.
##
## Inherited from `coworld-ctf/src/ctf/llm.nim` behaviour for behaviour — the
## credential ladder, the single-haiku model list, the `throttled` fast-fail, the
## fence-tolerant JSON extraction and the rune-boundary truncation are all that
## file's, because they are all scar tissue from real hosted failures.
##
## Waterworld is a SIMULTANEOUS-decision game, so all four seats' calls go out
## as ONE parallel batch per turn (`curly.makeRequests`). Seats are never
## queried sequentially: that is what keeps 24 turns inside the wall-clock
## budget.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to the
## scripted layer INSTANTLY, with no network wait — which is what lets offline
## certification finish in seconds.

import std/[json, os, strutils]

import bitworld/runtime
import curly

import sim_types, intents

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. Set per turn, cleared by the turn loop: retrying inside the
      ## same turn cannot succeed, so the seat fails fast to the scripted
      ## fallback instead of spending the turn budget on a call that will be
      ## refused again.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "waterworld llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order; BEDROCK_MODEL pins
  ## one. There is exactly ONE candidate — haiku — because every sonnet
  ## inference profile times out on every sidecar call (cogame-raid round 2,
  ## 2026-08-23), and one haiku throttle then cascades into a whole episode of
  ## scripted fallbacks because the retry burns the turn. With no second
  ## candidate a throttle fails fast (see `throttled`) and the seat plays the
  ## scripted fallback for that turn only.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "waterworld llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "waterworld llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "waterworld llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside "falling
    ## back" in decide.nim: "LLM provider is unavailable".
    echo "waterworld llm: no credentials — the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is none.
  ## Auth failure disables the client for the rest of the episode;
  ## model-access denial and throttling rotate the Bedrock model for the next
  ## batch instead.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes. A byte slice can cut a codepoint in
    ## half, and truncateRunes downstream only SHORTENS — it cannot repair a
    ## broken one.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You are ONE of four thruster drones ("skimmers") in a shallow tank seen from
above. The tank is 12.00 m wide and 8.00 m tall. Coordinates are metres from
the bottom-left corner; x runs right, y runs up. Bearings are degrees
counter-clockwise from east: 0 = right, 90 = up, 180 = left, 270 = down.
There is one round rock of radius 0.90 m dead centre at (6.00, 4.00).
THE POINT OF THE GAME: plankton drifts around the tank. A plankton particle is
only CAUGHT when TWO OR MORE skimmers are touching it AT THE SAME MOMENT. That
is worth +10 to everyone. One skimmer alone touching it is worth +0.05 and
nothing more, so the whole game is meeting a partner on a moving target.
Poison blooms also drift, faster. Touching one costs -2 and stuns you for half
a second. Thrusting costs a tiny amount, so full throttle everywhere loses to
coasting.
YOU FEEL THE WATER WITH 16 SENSORS THAT REACH ONLY 2.40 m. Beyond that you
cannot see plankton or poison at all. You CAN always see the other three
skimmers - position, velocity, stun - because the pod shares a transponder.
You CANNOT talk to anyone and nobody sees anything you write.
Everyone in the pod gets the SAME score. 20 catches ends the run early and
wins it.
Every 3 seconds you set your ORDER for the next 3 seconds. A deterministic
autopilot runs it 24 times a second: it steers, it leads a moving target, it
backs off poison for you. You choose WHAT to go for and HOW hard.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars, your reasoning",
 "mode":"hunt"|"escort"|"sweep"|"hold"|"avoid",
   // hunt   : drive at the plankton named in "target" (or, if you cannot
   //          sense it, the nearest plankton you CAN sense; if none, the
   //          waypoint), aiming where it will be in lead_ticks
   // escort : drive to the skimmer named in "partner", stopping 0.80 m short
   //          of it - unless you sense plankton within 1.50 m of that partner,
   //          in which case you go to the plankton instead. THIS is how two
   //          skimmers arrive together.
   // sweep  : drive to "waypoint" and hold there. Searching.
   // hold   : brake to a stop where you are. Waiting on a partner.
   // avoid  : run away from the nearest poison you sense (to the tank centre
   //          if you sense none)
 "target":"F1".."F5" or "none",     // a plankton id you have sensed
 "partner":"SKIM-1".."SKIM-4" or "none",
 "waypoint":[x,y],                  // metres, clamped into the tank
 "lead_ticks":0..24,                // aim where the target will be this many
                                    // ticks from now (24 ticks = 1 second)
 "standoff_m":0.0..2.5,             // how wide the autopilot swings around
                                    // poison. 0 = ignore it, 2.5 = paranoid
 "throttle":0.0..1.0,               // fraction of full speed you ask for
 "say":"<=48 chars"}                // spectators only; no skimmer ever sees it
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how much
  ## weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## sensor frame. The frame is built server-side (see decide.nim).
  operatorBlock(operatorPrompt) & viewJson
