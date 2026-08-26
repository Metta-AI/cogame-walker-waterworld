# Rules

THE TANK

12.00 m x 8.00 m, one submerged rock of radius 0.90 m dead centre at (6.00, 4.00). Coordinates shown to a policy are metres from the BOTTOM-LEFT corner, x right, y up; bearings are degrees counter-clockwise from east (0 = right, 90 = up).

BODIES
  4 skimmers, radius 0.24 m, spawning at rest at (3,2), (9,2), (3,6), (9,6)
  5 plankton, radius 0.16 m, speed 0.67 / 0.79 / 0.91 m/s
  8 poison blooms, radius 0.16 m, speed 0.96 / 1.10 / 1.25 m/s
Skimmers pass through each other: two-on-one-particle is geometrically easy and the TIMING is the hard part. Particles travel at exactly constant speed forever — direction changes only at a bounce.

MOTION
Thrust level 0..7 in one of 32 directions, 3.00 m/s^2 at level 7. Drag 3.81 %/tick, terminal speed 3.24 m/s. A wall returns 40 % of the normal speed; the rock does the same about its outward normal. Thrust costs level^2 * 1000 / 49 micro-points per tick, so full throttle for a whole episode costs 6.912 points and a policy that sprints everywhere loses to one that coasts.

SENSING
Sixteen sensors reaching 2.40 m. A plankton or poison particle is detected iff the distance between CENTRES is at most 2.40 m — nothing hides between rays. The other three skimmers are detected at ANY range (the pod shares a transponder), because capture needs two bodies on one particle at one instant with no communication channel of any kind. A partner beyond 2.40 m occupies no ray.

SCORING
  capture (2+ skimmers on one plankton, same tick)  +10.000
  nibble  (1 skimmer alone on a plankton)            +0.050, re-armed only
                                                     after 0.60 m of separation
  poison hit  -2.000, plus a 0.5 s stun and half your speed
  thrust      -level^2 * 0.000001 * 1000/49 per tick
One score, computed once, copied into all four seats.

ENDINGS
  complete/target_met  20 captures reached
  complete/full_time   1728 ticks played
  deadline/wall_clock  the engine's 660 s stop tripped first (declared
                       acceptable: the hosted LLM was slow, not broken)
  fault/sim_fault      an invariant guard tripped; partial replay written
  fault/host_error     an unexpected server-side exception

A seat that never connects does NOT end the episode: the no-show is reported, its skimmer plays the `shoal` baseline for the whole run, and three skimmers can still capture.

DETERMINISM
The whole sim runs in INTEGERS (micrometres, µm/tick, micro-points) with a committed 32-entry unit-vector table and one integer square root. Replays are re-simulated by the emscripten/wasm32 build of the same module the native server ran, and their per-tick gameHash chains must match bit for bit — integers make that true by construction rather than by an argument about two builds of libm agreeing.
