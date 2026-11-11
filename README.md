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
| Pause (Q quits while paused) | Esc | Start |

## Layout

- `scripts/vehicle/` — `car_controller.gd` (raycast suspension + arcade tyre physics, all tunables exported),
  `car_visuals.gd` (procedural body, wheels, lights, tyre smoke), `vehicle_input.gd` (input actions → commands).
- Audio (`scripts/vehicle/car_audio.gd`, node `Car/Audio`) — fully synthesised car sound on its own `CarAudio` bus
  (hard limiter): a real-time engine voice (firing-pulse wavetables, simulated 6-speed gearbox with shift cuts,
  downshift blips, rev limiter and overrun pops), tyre squeal/skid, wind, road rumble, off-road crunch, suspension
  thumps, impacts, gear and handbrake clicks. `car_sound_synth.gd` generates all the samples at startup.
- `scripts/camera/` — `chase_camera.gd` (smoothed chase camera: speed-based FOV/pull-back/lowering, acceleration
  lag and FOV kick, subtle noise shake) and `speed_effects.gd` (wind-streak particles + speed overlay above ~80 km/h).
- `scripts/world/` — `world_generator.gd` defines the road network and orchestrates `terrain_data.gd` (height
  field, every road carved in, computed on the WorkerThreadPool), `road_path.gd` (spline roads, open or looped,
  with a configurable cross-section: lanes, lane width, median) and the `*_builder.gd` mesh/collider builders
  (terrain is split into frustum-culled chunks; trees switch to cheap stand-ins past ~420 m; thousands of static
  colliders go through `collider_batch.gd` straight to the PhysicsServer). `palette.gd` holds the shared colours.
- World layout (~2.3 km across, ±1152 m): the original winding country loop sits in the middle; a 6.5 km 2×2-lane
  highway with a concrete median barrier, guard rails, 1 km straights and ~520 m radius bends loops around it;
  three winding country link roads join the loop to the highway through at-grade T-junctions (gaps in the rails
  and median there). Hills rise at the map edge with mountains beyond.
- `scripts/traffic/` — `traffic_manager.gd` (node `Traffic` in `main.tscn`) drives ~36 AI cars on the country loop
  and the highway, both directions, with the Intelligent Driver Model (keeps a time gap, slows for bends, brakes
  for the player's car). Cars are kinematic `AnimatableBody3D`s (`traffic_car.gd`) on collision layers 1+3, so
  the player crashes into them physically; `traffic_car_mesh.gd` builds the low-poly bodies (sedan, hatch, van,
  pickup, box truck).
- `scripts/game/` — `main.gd` (spawn, pause, reset) and `hud.gd`.
- `shaders/` — road markings, wind-swayed grass, speed streaks and the high-speed screen overlay.

## Debug

`$GODOT --path . -- --autodrive [--shots=/abs/dir]` runs a scripted autopilot lap (including a handbrake drift),
prints handling telemetry and FPS, optionally saves screenshots, then quits. Works headless for physics checks.
Traffic is off during autodrive unless `--traffic` is passed; `--road=highway` (or `link_north`, ...) drives
another road of the network instead of the country loop (on the highway, in the inner lane at up to 260 km/h).
