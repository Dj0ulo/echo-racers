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
- `scripts/world/` — `world_generator.gd` orchestrates `terrain_data.gd` (height field), `road_path.gd` (spline),
  and the `*_builder.gd` mesh/collider builders; `palette.gd` holds the shared colours.
- `scripts/game/` — `main.gd` (spawn, pause, reset) and `hud.gd`.
- `shaders/` — road markings, wind-swayed grass, speed streaks and the high-speed screen overlay.

## Debug

`$GODOT --path . -- --autodrive [--shots=/abs/dir]` runs a scripted autopilot lap (including a handbrake drift),
prints handling telemetry and FPS, optionally saves screenshots, then quits. Works headless for physics checks.
