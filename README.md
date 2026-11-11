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
| Handbrake (drift) | Space | A / Cross |
| Reset car to road | R | Y / Triangle |
| Pause (Q quits while paused) | Esc | Start |

## Layout

- `scripts/vehicle/` — `car_controller.gd` (raycast suspension + arcade tyre physics, all tunables exported),
  `car_visuals.gd` (procedural body, wheels, lights, tyre smoke), `vehicle_input.gd` (input actions → commands).
- `scripts/camera/chase_camera.gd` — smoothed third-person chase camera.
- `scripts/world/` — `world_generator.gd` orchestrates `terrain_data.gd` (height field), `road_path.gd` (spline),
  and the `*_builder.gd` mesh/collider builders; `palette.gd` holds the shared colours.
- `scripts/game/` — `main.gd` (spawn, pause, reset) and `hud.gd`.
- `shaders/` — road markings and wind-swayed grass.

## Debug

`$GODOT --path . -- --autodrive [--shots=/abs/dir]` runs a scripted autopilot lap (including a handbrake drift),
prints handling telemetry and FPS, optionally saves screenshots, then quits. Works headless for physics checks.
