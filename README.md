# Echo Racers

Low-poly open-world driving prototype (Godot 4.7, GDScript, Mobile renderer). Everything — terrain,
road, vegetation, props and the car — is generated procedurally at startup; no external assets.

## Run

```sh
GODOT=~/Applications/Godot-stable_linux.x86_64
$GODOT --path .            # play
$GODOT -e --path .         # open in the editor
```

On hybrid-GPU laptops, force the NVIDIA GPU with:

```sh
__NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only __GLX_VENDOR_LIBRARY_NAME=nvidia $GODOT --path .
```

## Controls

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Accelerate | W / Up | Right trigger |
| Brake / reverse | S / Down | Left trigger |
| Steer | A, D / Left, Right | Left stick |
| Handbrake (drift) | Space | X / Square |
| Boost (nitro) | Shift | A / Cross |
| Reset car to road (in an echo race: last checkpoint) | R | B / Circle |
| Map / GPS destination | M | Back / Select |
| Echo race menu | Tab | Y / Triangle |
| Look around (springs back on release) | — | Right stick (±90°) |
| Look back (hold) | C | LB |
| Pause (Q quits while paused) | Esc | Start |

## Map and GPS

Press **Select** (M) at any time (except in the echo editor) to pause and open a full-screen top-down map, north
up. Pan with the left stick / WASD / arrows / mouse drag and zoom with LT/RT / Q E / mouse wheel (or right stick).
**A** (Enter) puts a destination under the crosshair, or click a spot; **X** (F, Delete) clears it; **B** / Select
/ Esc closes the map. The destination gets a gold light beam in the world and a gold pin on both maps, and the
route (rerouted every 0.8 s) is drawn on both maps and as a glowing gold filament that rises from the car and flies
~11 m above the ground (starting just above the car roof), loosely following the route and cutting its bends. The route always starts at the car: it
follows the road network (A* on a graph of the roads that respects one-way ramps and the highway carriageways) but
crosses the fields to join it, to leave it, or skips it entirely whenever that is shorter (off-road metres count
1.6x, `offroad_cost`). The filament and the minimap route are hidden during echo races, recording and the editor,
as are the destination beacon and the echo beacons (only the checkpoints show). Reaching the destination clears it.
Code: `scripts/game/world_map.gd`, `gps.gd` (filament, beacon), `road_graph.gd` (route finding).

## Echo races

Press **Y** (Tab) anywhere to open the side menu (up/down to choose, A/Enter to select, B/Esc to go back; the game
pauses while it is open) and pick **Start a race here**: the car stops where it is, 3-2-1-GO, and every position is
recorded. Press Y whenever you want and **End the race & place checkpoints**: a top-down 3D view of the run opens.

- Left/right (stick, d-pad, arrows) scrubs along the run (hold to speed up), LB/RB (`[` `]`) jumps between
  checkpoints, LT/RT (W/S) zooms toward the cursor.
- X (F) or **Add / Remove checkpoint here** toggles a checkpoint at the cursor. **Random checkpoints** spreads a
  few along the run; **Auto: x / y / z extremes** puts one on every local extreme of x, z (outermost points of
  bends) and y (crests and dips). **Set the finish here** trims the run. Start and finish are always checkpoints.
- **Style** toggles between neon rings (glowing circle on the ground with a light cylinder) and light gates
  (two neon pillars with sparks).
- **Save & race this echo** or **Save & leave race mode**. The course gets a small neon blue marker (post, ground ring, chevrons) at its start, also
  shown on the minimap (pinned to the rim when far away); the first choice starts racing its echo right away.
  **Discard run** asks whether to record again from the same start or leave race mode.

Drive into a beacon and press Y to see its echoes, best first, and pick the one to race: 3-2-1-GO, then pass every
checkpoint in order (the next one pulses; it is also the pink marker on the minimap) against a hologram ghost of the
echo. The HUD shows the time and your split against the echo at each checkpoint. During a race Y offers restart
from the start or exit; reset puts you back on the last checkpoint passed. Beat the echo and you can save your run
as a new echo of that course (older ones are kept), then race that new echo straight away. Every race (and restart)
starts with a full boost gauge. The editor's ghost-car cursor grows with the zoom only up to a cap
(`EchoEditor.cursor_max_scale`). Courses are saved in `user://echoes/` (one `.echo` file each,
`~/.local/share/godot/app_userdata/<project>/echoes/` on Linux).

Code: `scripts/echo/` — `echo_manager.gd` (game flow, menus, recording at 30 Hz, checkpoint crossing),
`echo_editor.gd` (top view), `echo_ui.gd` (side menu, timer, countdown, beeps), `echo_track.gd` / `echo_run.gd`
(data + save files), `checkpoint_gate.gd`, `ghost_car.gd`, `echo_point.gd` (beacon) and `neon.gd` (glow shaders).

## Day and night

Time flows from 10:00 at startup: 10 real minutes of daylight (06:00-18:00) then 10 of night (`DayNight.day_minutes`,
`night_minutes`). The sun rises in the east, culminates in the south and sets in the west; sunrise and sunset paint a
warm glow along the horizon and light the clouds from below, then a blue-purple twilight gives way to a starry sky
and a cool full-moon light. The car's headlights come on at dusk, and so do the traffic's (glowing lenses plus a light pool on the road). The world map and the echo editor always show the
world in daylight. Colours per sun elevation live in the `_KEYS` table of `scripts/world/day_night.gd`, which also
owns the sky shader.

## Layout

- `scripts/vehicle/` — `car_controller.gd` (raycast suspension + arcade tyre physics, all tunables exported),
  `car_visuals.gd` (procedural body, wheels, lights, tyre smoke), `vehicle_input.gd` (input actions → commands).
- Audio (`scripts/vehicle/car_audio.gd`, node `Car/Audio`) — fully synthesised car sound on its own `CarAudio` bus
  (hard limiter): a real-time engine voice (firing-pulse wavetables, simulated 6-speed gearbox with shift cuts,
  downshift blips, rev limiter and overrun pops), tyre squeal/skid, wind, road rumble, off-road crunch, suspension
  thumps, impacts, gear and handbrake clicks. `car_sound_synth.gd` generates all the samples at startup.
- `scripts/camera/` — `chase_camera.gd` (smoothed chase camera: speed-based FOV/pull-back/lowering, acceleration
  lag and FOV kick, subtle noise shake, right-stick free look and rear view) and `speed_effects.gd` (wind-streak particles + speed overlay above ~80 km/h).
- `scripts/world/` — `world_generator.gd` defines the road network and orchestrates `terrain_data.gd` (height
  field, every road carved in, computed on the WorkerThreadPool), `road_path.gd` (spline roads, open or looped,
  with a configurable cross-section: lanes, lane width, median) and the `*_builder.gd` mesh/collider builders
  (terrain is split into frustum-culled chunks; trees keep ≥5 m apart and thin out near roads, only their trunks
  are solid, and they switch to cheap stand-ins past ~420 m; thousands of static
  colliders go through `collider_batch.gd` straight to the PhysicsServer). `palette.gd` holds the shared colours.
- World layout (~4.6 km across, ±2304 m): the original winding country loop sits in the middle; a 6.5 km 2×2-lane
  highway with a concrete median barrier, guard rails, 1 km straights and ~520 m radius bends loops around it
  (±950 m) with an unbroken median barrier. Three winding country link roads (`link_north`, `link_east`,
  `link_southwest`) leave the loop at T-junctions and cross the highway square-on on bridges (deck, parapets,
  median pier, abutments with wing walls; `interchange_builder.gd`), each a diamond interchange with four
  one-way slip roads (`ramp_<link>_off1/on1` for traffic along the highway's direction, `off2/on2` for the other
  carriageway): ~360 m long, tapering off/onto the outer lane behind a dashed edge line, then climbing gently to
  the link road, which they meet at right angles 60 m from the highway. Past the highway a ~650 m band of rolling
  countryside leads to ridged, rocky, snow-capped mountains (from ~1600 m out) that form the map's natural
  boundary (invisible walls at the very edge), with even higher ranges beyond as backdrop. The links carry on
  outside the ring: `mountain_road` (4 km) continues `link_north` across the outer countryside and winds along
  the north-east foothills to the end of `link_east`; `west_road` (4.7 km) continues `link_southwest` around the
  west of the map to a T-junction on `mountain_road`. Terrain chunks away from roads outside the highway are generated and meshed at 1/2 or
  1/4 resolution (exactly matching the collider), and forests thin out there and stop at the tree line.
- `scripts/traffic/` — `traffic_manager.gd` (node `Traffic` in `main.tscn`) drives ~36 AI cars on the country loop
  and the highway, both directions, with the Intelligent Driver Model (keeps a time gap, slows for bends, brakes
  for the player's car and crashed cars). Cars are kinematic `AnimatableBody3D`s (`traffic_car.gd`, layer 3 only)
  with a mass per type (hatch 1100 kg … box truck 6000 kg). Crashes are momentum-based: the manager tests the
  player's body box against nearby traffic (and crashed cars against other traffic) as oriented boxes and
  exchanges a horizontal impulse at the contact point (restitution ~0.28, friction, masses and yaw inertias, a
  per-pair cooldown so contacts never double-bounce), so a hatch gets punted, a truck barely budges and
  off-centre hits spin both cars. Above ~60 km/h closing speed a player hit also launches the traffic car
  (arcade): height, push and tumble grow with the impact energy (closing speed squared) and the player/car mass
  ratio, so a hatch hit at 180 km/h barrel-rolls ~4 m high while a truck only lurches, and the player keeps most
  of its speed (`launch_*` exports on the Traffic node). A hit car slides (or flies, bounces and rolls back onto
  its wheels), spins and brakes to a stop, waits a few seconds, then eases back into its lane; impacts play the car's crash sound scaled by speed and mass.
  `traffic_car_mesh.gd` builds the low-poly bodies (sedan, hatch, van, pickup, box truck).
- `scripts/game/` — `main.gd` (spawn, pause, reset), `hud.gd` and `minimap.gd` (bottom-left, heading-up circular
  minimap: terrain and every road in `WorldGenerator.roads` are rendered once into a mipmapped texture sized from
  the road network's extent, then a shader rotates/samples it each frame; traffic dots, north marker, zooms out
  with speed).
- `shaders/` — road markings, wind-swayed grass, speed streaks and the high-speed screen overlay.

## Debug

`$GODOT --path . -- --autodrive [--shots=/abs/dir]` runs a scripted autopilot lap (including a handbrake drift),
prints handling telemetry and FPS, optionally saves screenshots, then quits. Works headless for physics checks.
Traffic is off during autodrive unless `--traffic` is passed; `--road=highway` (or `link_north`, ...) drives
another road of the network instead of the country loop (on the highway, in the inner lane at up to 260 km/h).
`$GODOT --headless --path . -- --autodrive --crashtest` instead stages crashes on a highway straight (rear-ending a
hatch and a truck, an off-centre T-bone, being T-boned by a van, a side swipe, then two 180-200 km/h launches) and
prints pre/post velocities, yaw rates, the hit car's peak air height and its recovery; every player crash is also logged in the other autodrive modes.
`--view=x,y,z,tx,ty,tz` (repeatable, with `--shots`) first saves fog-free stills from a free camera at `x,y,z`
looking at `tx,ty,tz`; `--view=overview` shows the whole map. `--route=highway,ramp_north_off1,link_north,ramp_north_on2,highway`
drives through several roads in turn (here: exit the highway, cross the bridge, rejoin the other carriageway).
`--time=<hour>` (e.g. `--time=17.6` for a sunset, `--time=23` for night) sets the starting time of day and
`--timescale=<x>` speeds the day/night cycle up (any mode, not only autodrive).
`--autodrive --echotest [--shots=/abs/dir]` runs the echo mode end to end through simulated menu presses: records a
14 s run, places checkpoints on its extremes in the editor, saves it, races its ghost (following its line a bit
faster), prints the splits and result, saves the new echo, then deletes the scratch course (`user://echoes_test`).
`--autodrive --maptest [--shots=/abs/dir]` opens the world map through its input action, sets a destination 450 m
ahead (shots `map.png`, then `filament.png` after closing the map), then routes to the middle of every road and
prints route vs straight-line distances. Real gamepad buttons are ignored during it (Godot reads joypads even
unfocused; add `--audio-driver Dummy` before `--` to keep test runs silent while someone plays).
