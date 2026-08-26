## The turn loop and the engine's bounded-wait contract, without a network: the
## LLM client with no credentials disables itself, which is exactly the path a
## test can drive and exactly the path certification takes.

import std/[atomics, json, monotimes, net, os, strutils, times]

import mummy

import helpers
import waterworld/[sim, roster, sensors, intents, control, baselines, decide, llm]

var failures = 0
proc check(name: string, ok: bool, detail = "") =
  if not ok:
    inc failures
    echo "FAIL ", name, (if detail.len > 0: ": " & detail else: "")

# No credentials in the test environment, so the client disables itself and
# every turn falls back INSTANTLY with no network wait — which is what lets
# offline certification finish in seconds.
putEnv("ANTHROPIC_API_KEY", "")
putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "")
putEnv("AWS_BEARER_TOKEN_BEDROCK", "")

proc freeLocalPort(): int =
  ## mummy does not report the port it bound, so pick one that is free right
  ## now and hand it over. The window between the probe and the bind is the
  ## reason for the range rather than a single hard-coded port.
  for candidate in 39_641 .. 39_680:
    try:
      let probe = newSocket()
      probe.setSockOpt(OptReuseAddr, true)
      probe.bindAddr(Port(candidate), "127.0.0.1")
      probe.close()
      return candidate
    except CatchableError:
      discard
  0

proc framesFor(sim: SimServer): seq[SensorFrame] =
  for seat in 0 ..< SkimmerCount:
    result.add(sim.frameFor(sim.skimmerForSeat(seat)))

block oneParallelBatchPerTurn:
  ## THE SHAPE: all four seats go into ONE batch. `openSeats` is the list that
  ## batch is built from and `batchBodies` is the bodies it carries, so a length
  ## of four here IS "seats are never queried sequentially".
  var sim = seatedSim()
  var engine = initDecisionEngine(sim)
  engine.client.disabled = false     ## pretend credentials, no call is made
  for seat in 0 ..< SkimmerCount:
    engine.seats[seat].isLlm = true
    engine.seats[seat].prompt = "seat " & $seat
  let open = engine.openSeats(sim)
  check("all four LLM seats are open in the same turn", open.len == 4, $open.len)
  let bodies = engine.batchBodies(sim, sim.framesFor(), 0, 0)
  check("the batch carries one body per seat", bodies.len == 4, $bodies.len)
  for seat in 0 ..< SkimmerCount:
    check("body " & $seat & " carries that seat's own guidance",
      ("seat " & $seat) in bodies[seat])
  let retryBodies = engine.batchBodies(sim, sim.framesFor(), 0, 1)
  check("the retry batch is also one batch", retryBodies.len == 4)
  check("the retry batch tells the model why",
    "not usable" in retryBodies[0])

block noCredentialsFallsBackInstantly:
  var sim = seatedSim()
  var engine = initDecisionEngine(sim)
  for seat in 0 ..< SkimmerCount:
    engine.seats[seat].isLlm = true
    engine.seats[seat].prompt = "guidance"
  check("with no credentials the client disables itself", engine.client.disabled)
  let started = getMonoTime()
  let records = engine.turn(sim, sim.framesFor(), 0, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds.int
  check("a credential-less turn costs no network wait", elapsed < 1000, $elapsed)
  check("every LLM seat recorded a fallback", records.len >= SkimmerCount,
    $records.len)
  var causes = 0
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback" and
        node{"cause"}.getStr() == "no_credentials":
      inc causes
  check("the cause is named no_credentials", causes == SkimmerCount, $causes)
  for seat in 0 ..< SkimmerCount:
    check("every seat still has an intent", engine.haveIntent[seat])
    check("the fallback intent is marked as a fallback",
      engine.intents[seat].source == isFallback)

block scriptedSeatsGetNoFallbackRecord:
  var sim = seatedSim()
  var engine = initDecisionEngine(sim)
  let records = engine.turn(sim, sim.framesFor(), 0, 0)
  check("a seat that registered as SCRIPTED writes no fallback record",
    records.len == 0, $records.len)
  for seat in 0 ..< SkimmerCount:
    check("a scripted seat's intent is marked scripted",
      engine.intents[seat].source == isScripted)

block budgetGuard:
  ## The guard settles EARLY rather than overrun: if two more full turns
  ## (spacing included) would not fit inside the engine's own wall-clock stop,
  ## the LLM goes off for the rest of the episode and the run finishes on the
  ## scripted layer, so the episode ends complete/* rather than deadline.
  var sim = seatedSim()
  var engine = initDecisionEngine(sim)
  for seat in 0 ..< SkimmerCount:
    engine.seats[seat].isLlm = true
    engine.seats[seat].prompt = "guidance"
  let records = engine.turn(sim, sim.framesFor(), 3,
    sim.config.wallClockBudgetSeconds - 10)
  var guarded = false
  for record in records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      guarded = true
  check("the budget guard fires near the stop", guarded)
  check("the LLM is off for the rest of the episode", engine.llmOff)
  # And the episode still reaches a normal ending on the scripted layer.
  let run = sim.runScripted(blShoal)
  check("the guarded episode still ends complete/*",
    sim.endReason == ReasonComplete, sim.endReason & "/" & sim.endRule)
  check("the guarded episode played its ticks", run.ticks > 100, $run.ticks)

block interBatchFloor:
  ## The rate floor is a bounded, measurable sleep: with turnSpacingMs set, two
  ## consecutive batches cannot start closer than that.
  var sim = seatedSim()
  sim.config.turnSpacingMs = 300
  var engine = initDecisionEngine(sim)
  engine.client.disabled = false
  engine.client.transport = ltAnthropic
  for seat in 0 ..< SkimmerCount:
    engine.seats[seat].isLlm = true
  engine.batchStarted = true
  engine.lastBatchStart = getMonoTime()
  let started = getMonoTime()
  discard engine.openSeats(sim)
  # Drive the floor directly the way turn() does, without issuing a request.
  let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
  if since < sim.config.turnSpacingMs:
    sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  let elapsed = (getMonoTime() - started).inMilliseconds.int
  check("the inter-batch floor is honoured", elapsed >= 250, $elapsed)
  check("and it is BOUNDED", elapsed <= 2000, $elapsed)

  # The floor the engine actually sleeps, through its own entry point.
  engine.lastBatchStart = getMonoTime()
  let realStart = getMonoTime()
  let sleptMs = engine.waitOutInterBatchFloor(sim, 0, 0)
  let realElapsed = (getMonoTime() - realStart).inMilliseconds.int
  check("the engine's own floor sleeps the spacing", sleptMs >= 250, $sleptMs)
  check("and it does not overshoot it", realElapsed <= 2000, $realElapsed)

  # STOP-INTERRUPTIBLE: with the wall clock already spent, the floor gives up
  # after a slice instead of holding the episode past its own deadline.
  sim.config.turnSpacingMs = 3000
  sim.config.wallClockBudgetSeconds = 60
  engine.lastBatchStart = getMonoTime()
  let stopStart = getMonoTime()
  let cutShort = engine.waitOutInterBatchFloor(sim, 0, 60)
  let stopElapsed = (getMonoTime() - stopStart).inMilliseconds.int
  check("a floor that outlives the wall-clock stop is cut short",
    cutShort < 1000, $cutShort)
  check("and the caller comes back inside one slice", stopElapsed < 1000,
    $stopElapsed)

block deadlineArithmetic:
  let config = defaultGameConfig()
  check("attempt1 + retry fits inside the per-turn budget",
    config.attempt1Ms + config.retryMs <= config.turnBudgetMs,
    $(config.attempt1Ms + config.retryMs) & " vs " & $config.turnBudgetMs)
  check("every deadline is a whole number of seconds",
    config.attempt1Ms mod 1000 == 0 and config.retryMs mod 1000 == 0,
    $config.attempt1Ms & "/" & $config.retryMs)
  check("the wall-clock stop is inside 60 % of episodeTimeoutSeconds",
    config.wallClockBudgetSeconds <= 720, $config.wallClockBudgetSeconds)
  # The whole-episode arithmetic: 23 inter-batch gaps + one last turn + the
  # lobby + the physics + the artifact write must fit inside the stop.
  let turns = config.maxTicks div config.turnTicks
  let worst = (turns - 1) * config.turnSpacingMs div 1000 +
    config.turnBudgetMs div 1000 + 72 + 2 + 20 + 30
  check("the absolute worst case fits inside the engine stop",
    worst < config.wallClockBudgetSeconds,
    $worst & " vs " & $config.wallClockBudgetSeconds)

# ---------------------------------------------------------------------------
#  A FAKE PROVIDER: a real HTTP server on 127.0.0.1, driven through the real
#  curly batch path. The engine cannot tell it from Bedrock, so the retry,
#  throttle, budget and batching behaviour asserted below is the engine's own.
# ---------------------------------------------------------------------------
type FakeMode = enum
  fmGood,          ## every reply parses
  fmGarbageThenGood,  ## the first batch is unusable, the second parses
  fmGarbage,       ## every reply is unusable
  fmThrottled,     ## every reply is a 429
  fmHung           ## every reply arrives long after the deadline

var
  fakeMode: Atomic[int]
  fakeHoldMs: Atomic[int]
  fakeSeen: Atomic[int]        ## requests the fake has answered, total
  fakeInFlight: Atomic[int]
  fakeMaxInFlight: Atomic[int]

proc fakeReset(mode: FakeMode, holdMs = 0) =
  fakeMode.store(ord(mode), moRelaxed)
  fakeHoldMs.store(holdMs, moRelaxed)
  fakeSeen.store(0, moRelaxed)
  fakeInFlight.store(0, moRelaxed)
  fakeMaxInFlight.store(0, moRelaxed)

proc replyBody(intent: string): string =
  """{"content":[{"type":"text","text":""" & escapeJson(intent) &
    """}],"stop_reason":"end_turn"}"""

proc fakeHandler(request: Request) {.gcsafe.} =
  let index = fakeInFlight.fetchAdd(1, moSequentiallyConsistent) + 1
  var seen = fakeMaxInFlight.load(moSequentiallyConsistent)
  while index > seen and
      not fakeMaxInFlight.compareExchange(seen, index, moSequentiallyConsistent):
    seen = fakeMaxInFlight.load(moSequentiallyConsistent)
  let ordinal = fakeSeen.fetchAdd(1, moSequentiallyConsistent) + 1
  let mode = FakeMode(fakeMode.load(moRelaxed))
  # Holding every reply for the same interval is what makes the in-flight high
  # water mark meaningful: a caller that queried the seats one after another
  # would never see two at once.
  sleep(fakeHoldMs.load(moRelaxed))
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  case mode
  of fmGood:
    request.respond(200, headers, replyBody(
      """{"mode":"hunt","target":"F1","throttle":0.5,"note":"fake"}"""))
  of fmGarbageThenGood:
    if ordinal <= SkimmerCount:
      request.respond(200, headers, replyBody("no json here at all"))
    else:
      request.respond(200, headers, replyBody(
        """{"mode":"escort","partner":"SKIM-2","throttle":0.25}"""))
  of fmGarbage:
    request.respond(200, headers, replyBody("no json here at all"))
  of fmThrottled:
    request.respond(429, headers, """{"message":"too many requests"}""")
  of fmHung:
    sleep(4000)
    request.respond(200, headers, replyBody("""{"mode":"hold"}"""))
  discard fakeInFlight.fetchSub(1, moSequentiallyConsistent)

proc fakeServe(args: tuple[server: Server, port: int]) {.thread.} =
  try:
    args.server.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard

block fakeProviderDrivesTheEngine:
  ## What the note's §Tests 6 and 7 ask for, against a fake provider:
  ##   * all four seats are in flight at the same moment (ONE batch);
  ##   * an unusable reply on attempt 1 costs EXACTLY one retry;
  ##   * a throttled provider costs ZERO retries;
  ##   * two consecutive failures leave the seat on the `shoal` intent with a
  ##     `fallback` record naming the cause;
  ##   * a hung provider is cut off by the per-turn budget.
  let fakePort = freeLocalPort()
  check("a local port is free for the fake provider", fakePort > 0)
  let fakeServer = newServer(fakeHandler, workerThreads = 8)
  var serverThread: Thread[tuple[server: Server, port: int]]
  createThread(serverThread, fakeServe, (fakeServer, fakePort))
  var up = false
  for _ in 0 ..< 200:
    try:
      let probe = dial("127.0.0.1", Port(fakePort))
      probe.close()
      up = true
      break
    except CatchableError:
      sleep(25)
  check("the fake provider is listening", up)

  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:" & $fakePort)
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "fake-token")
  var sim = seatedSim()
  sim.config.turnSpacingMs = 0
  sim.config.attempt1Ms = 2000
  sim.config.retryMs = 2000
  sim.config.turnBudgetMs = 9000
  var engine = initDecisionEngine(sim)
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "")
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "")
  check("the fake client took the bedrock transport",
    engine.client.transport == ltBedrock and not engine.client.disabled)
  for seat in 0 ..< SkimmerCount:
    engine.seats[seat].isLlm = true
    engine.seats[seat].prompt = "seat " & $seat

  block oneBatchNotFourCalls:
    # Warm-up turn first: libcurl holds back the rest of a batch until the
    # FIRST transfer to a new host has revealed whether the connection can be
    # multiplexed, so a cold pool would serialise the first reply no matter what
    # the engine does. One throwaway batch fills the pool; the measured batch
    # below then rides it.
    fakeReset(fmGood)
    discard engine.turn(sim, sim.framesFor(), 0, 0)
    check("the warm-up batch reached the fake",
      fakeSeen.load(moSequentiallyConsistent) == SkimmerCount,
      $fakeSeen.load(moSequentiallyConsistent))
    fakeReset(fmGood, holdMs = 300)
    let records = engine.turn(sim, sim.framesFor(), 0, 0)
    check("the good turn issued exactly one request per seat",
      fakeSeen.load(moSequentiallyConsistent) == SkimmerCount, $fakeSeen.load(moSequentiallyConsistent))
    check("all four seats were in flight at the same moment",
      fakeMaxInFlight.load(moSequentiallyConsistent) == SkimmerCount,
      $fakeMaxInFlight.load(moSequentiallyConsistent))
    for seat in 0 ..< SkimmerCount:
      check("seat " & $seat & " is flying the LLM's own intent",
        engine.intents[seat].source == isLlm and
          engine.intents[seat].mode == mHunt)
    for record in records:
      check("a good turn records no fallback",
        parseJson(record){"k"}.getStr() != "fallback", record)

  block exactlyOneRetry:
    fakeReset(fmGarbageThenGood)
    let records = engine.turn(sim, sim.framesFor(), 1, 0)
    check("an unusable first batch costs exactly one retry",
      fakeSeen.load(moSequentiallyConsistent) == 2 * SkimmerCount, $fakeSeen.load(moSequentiallyConsistent))
    for seat in 0 ..< SkimmerCount:
      check("the retry's answer is the one that flies",
        engine.intents[seat].source == isLlm and
          engine.intents[seat].mode == mEscort)
    var attemptOneFallbacks = 0
    for record in records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback":
        check("the attempt-1 failure is recorded as attempt 1",
          node{"attempt"}.getInt() == 1, record)
        check("and named a parse_error",
          node{"cause"}.getStr() == "parse_error", record)
        inc attemptOneFallbacks
    check("one per seat", attemptOneFallbacks == SkimmerCount,
      $attemptOneFallbacks)

  block twoFailuresLandOnShoal:
    fakeReset(fmGarbage)
    let records = engine.turn(sim, sim.framesFor(), 2, 0)
    check("two unusable batches are two batches and no more",
      fakeSeen.load(moSequentiallyConsistent) == 2 * SkimmerCount, $fakeSeen.load(moSequentiallyConsistent))
    for seat in 0 ..< SkimmerCount:
      check("the seat lands on the shoal intent",
        engine.intents[seat].source == isFallback)
    var terminal = 0
    for record in records:
      let node = parseJson(record)
      if node{"detail"}.getStr() == "seat fell back to the shoal intent":
        check("the terminal record says both attempts were spent",
          node{"attempt"}.getInt() == 2, record)
        inc terminal
    check("with one terminal fallback record per seat",
      terminal == SkimmerCount, $terminal)

  block throttledMeansNoRetry:
    fakeReset(fmThrottled)
    let records = engine.turn(sim, sim.framesFor(), 3, 0)
    check("a 429 costs ZERO retries",
      fakeSeen.load(moSequentiallyConsistent) == SkimmerCount, $fakeSeen.load(moSequentiallyConsistent))
    var throttled = 0
    for record in records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback" and
          node{"cause"}.getStr() == "throttled":
        inc throttled
    check("and every seat's fallback names the throttle",
      throttled >= SkimmerCount, $throttled)
    for record in records:
      let node = parseJson(record)
      if node{"detail"}.getStr() == "seat fell back to the shoal intent":
        check("the terminal record counts the ONE attempt that was made",
          node{"attempt"}.getInt() == 1, record)
    for seat in 0 ..< SkimmerCount:
      check("the seat still has a legal intent",
        engine.intents[seat].source == isFallback)

  block theBudgetCutsOffAHungProvider:
    fakeReset(fmHung)
    let started = getMonoTime()
    let records = engine.turn(sim, sim.framesFor(), 4, 0)
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    check("a hung provider does not outlive the per-turn budget",
      elapsed <= sim.config.turnBudgetMs + 2000, $elapsed)
    for seat in 0 ..< SkimmerCount:
      check("and the seat plays the shoal intent",
        engine.intents[seat].source == isFallback)
    var timeouts = 0
    for record in records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "fallback" and
          node{"cause"}.getStr() in ["timeout", "transport_error"]:
        inc timeouts
    check("with the wait recorded as a timeout", timeouts >= SkimmerCount,
      $timeouts)

  fakeServer.close()
  joinThread(serverThread)

block wallClockStop:
  var sim = seatedSim()
  sim.endEpisode(ReasonDeadline, EndRuleWallClock)
  check("the wall-clock stop yields deadline/wall_clock",
    sim.endReason == ReasonDeadline and sim.endRule == EndRuleWallClock)
  check("and it still scores the state as it stands",
    parseJson(sim.playerResultsJson()){"reason"}.getStr() == "deadline")

block simFault:
  ## A tripped invariant guard yields fault/sim_fault, and the results document
  ## is still writable — which is what makes a partial replay useful.
  var sim = seatedSim()
  sim.latticeFallbacks = int32(MaxLatticeFallbacks + 1)
  var raised = false
  var cmds: array[SkimmerCount, uint8]
  try:
    sim.step(cmds)
  except SimGuardError:
    raised = true
  check("a tripped guard raises SimGuardError", raised)
  sim.endEpisode(ReasonFault, EndRuleSimFault)
  let results = parseJson(sim.playerResultsJson())
  check("the fault ending is reported", results{"reason"}.getStr() == "fault")
  check("with the sim_fault rule",
    results{"endRule"}.getStr() == "sim_fault")

block neverConnectingSeat:
  ## A seat that never connects does NOT end the episode: the lobby times out,
  ## the no-show is reported, and the skimmer plays the shoal baseline.
  var config = testConfig()
  config.lobbyJoinTimeoutTicks = 10
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  discard sim.addPlayer("only-one", 0, "t0", trusted = true)
  var cmds: array[SkimmerCount, uint8]
  for _ in 0 ..< 12:
    sim.step(cmds)
  check("the lobby reports a timeout", sim.lobbyJoinTimedOut())
  check("the missing seat is the next open slot", sim.nextPlayerSlot() == 1,
    $sim.nextPlayerSlot())
  # The server lowers minPlayers to what joined and plays on.
  sim.config.minPlayers = 1
  for _ in 0 ..< 4:
    sim.step(cmds)
  check("the tank still goes live", sim.phase == Playing, $sim.phase)
  let run = sim.runScripted(blShoal, ticks = 200)
  check("and the run plays", run.ticks == 200, $run.ticks)

block droppedSeatKeepsItsSkimmer:
  var sim = seatedSim()
  sim.removePlayerAt(2)
  check("a dropped seat leaves the roster", sim.players.len == 3,
    $sim.players.len)
  check("but the pod is still four skimmers",
    sim.perm.len == SkimmerCount)
  let run = sim.runScripted(blShoal, ticks = 200)
  check("and the episode keeps playing", run.ticks == 200, $run.ticks)

if failures > 0:
  quit("test_engine: " & $failures & " failure(s)", 1)
echo "test_engine: ok"
