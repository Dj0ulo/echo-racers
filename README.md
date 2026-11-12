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
| Reset car to road | R | Y / Triangle |
| Look around (springs back on release) | — | Right stick (±90°) |
| Look back (hold) | C | Right stick down |
| Pause (Q quits while paused) | Esc | Start |

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
  off-centre hits spin both cars without launching anything. A hit car slides, spins and brakes to a stop, waits
  a few seconds, then eases back into its lane; impacts play the car's crash sound scaled by speed and mass.
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
hatch and a truck, an off-centre T-bone, being T-boned by a van, a side swipe) and prints pre/post velocities, yaw
rates and the hit car's recovery; every player crash is also logged in the other autodrive modes.
`--view=x,y,z,tx,ty,tz` (repeatable, with `--shots`) first saves fog-free stills from a free camera at `x,y,z`
looking at `tx,ty,tz`; `--view=overview` shows the whole map. `--route=highway,ramp_north_off1,link_north,ramp_north_on2,highway`
drives through several roads in turn (here: exit the highway, cross the bridge, rejoin the other carriageway).
