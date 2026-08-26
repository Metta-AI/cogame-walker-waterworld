# Writing a skimmer order

WHAT YOU CONTROL

Every 3 seconds you set ONE order for the next 3 seconds. You choose WHAT to go for and HOW hard; a deterministic autopilot does the steering 24 times a second, leads a moving target, swings around poison and never drives into the rock.

  mode hunt    drive at the plankton in `target` (or, if you cannot sense it,
               the nearest plankton you CAN sense; if none, the waypoint),
               aiming where it will be in `lead_ticks`
  mode escort  drive to the skimmer in `partner`, stopping 0.80 m short —
               unless you sense plankton within 1.50 m of that partner, in
               which case you go to the plankton instead. THIS is how two
               skimmers arrive together
  mode sweep   drive to `waypoint` and park there. Searching
  mode hold    brake to a stop where you are. Waiting on a partner
  mode avoid   run from the nearest poison you sense (tank centre if none)

  target      "F1".."F5" or "none" — a plankton you have SENSED. Naming one
              you cannot sense is the same as "none"
  partner     "SKIM-1".."SKIM-4" or "none". Your own alias is "none"
  waypoint    [x, y] in metres from the bottom-left corner
  lead_ticks  0..24 (24 ticks = 1 second)
  standoff_m  0.0..2.5 — how wide the autopilot swings around poison. 0
              ignores it; above 2.0 it will not close on food
  throttle    0.0..1.0 of full speed. Thrust costs points
  note        <=160 runes of your reasoning, for the spectator feed
  say         <=48 runes, spectators only. No skimmer ever sees it

WHAT WINS

A catch needs TWO skimmers on one plankton in the SAME TICK. One skimmer alone on plankton earns +0.05 once and then nothing until it has moved 0.60 m away — sitting on food alone is not a strategy, it is a signal. So the whole game is rendezvous: sense something, decide who else can reach it in three seconds, and be there at the same moment as somebody who cannot hear you. `escort` exists precisely for that: it converges two skimmers to a point 0.80 m apart and then, the instant either of them smells plankton near the other, sends both to the plankton.

Poison costs -2 and half a second of no thrust. -2 is twenty nibbles; it is worth a wide standoff when you are not closing on anything. Thrust is small but real: 6.912 points if you hold full throttle for the whole run, which is most of a catch.

EVERYONE GETS THE SAME SCORE, including the two seats you did not choose and cannot talk to. The ladder ranks you by the mean of those shared scores, so a policy that only works alongside its own twin is exactly the policy the cross-play mean exposes.
