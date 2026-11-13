# Echo Racers

Low-poly open-world driving prototype (Godot 4.7, GDScript, Mobile renderer). Everything (terrain, roads,
vegetation, props, car, traffic, audio) is generated procedurally at startup; there are no external assets.
Controls, world layout details and the debug flags are in `README.md` (link, don't duplicate). Code style:
tabs, typed GDScript, `##` doc comment at the top of each script.

## Map (one line per script)
- `scripts/game/main.gd` entry point: spawns the car on the road, pause/quit, resets.
- `scripts/game/hud.gd` (Hud) speedometer, boost gauge, FPS, controls hint, pause overlay.
- `scripts/game/minimap.gd` (Minimap) heading-up circular minimap, terrain+roads rendered once, shader rotates.
- `scripts/vehicle/car_controller.gd` (CarController) RigidBody3D, raycast suspension, arcade tyre physics, exported tunables.
- `scripts/vehicle/vehicle_input.gd` (VehicleInput) input actions to normalized commands (AI can drive too).
- `scripts/vehicle/car_visuals.gd` (CarVisuals) procedural body, wheels, lights, tyre smoke; never affects physics.
- `scripts/vehicle/car_audio.gd` procedural engine/tyre/wind/impact audio on the `CarAudio` bus.
- `scripts/vehicle/car_sound_synth.gd` generates all sound samples at startup.
- `scripts/camera/chase_camera.gd` (ChaseCamera) smoothed chase cam, speed FOV/pull-back, free look.
- `scripts/camera/speed_effects.gd` (SpeedEffects) wind-streak particles + speed overlay.
- `scripts/traffic/traffic_manager.gd` (TrafficManager) AI traffic (IDM), momentum-based crash handling.
- `scripts/traffic/traffic_car.gd` (TrafficCar) one kinematic AI car and its states.
- `scripts/traffic/traffic_car_mesh.gd` (TrafficCarMesh) low-poly bodies: sedan, hatch, van, pickup, truck.
- `scripts/world/world_generator.gd` (WorldGenerator) defines the road network, orchestrates all builders.
- `scripts/world/road_path.gd` (RoadPath) Catmull-Rom spline road, lanes/median cross-section, open or looped.
- `scripts/world/road_builder.gd` (RoadBuilder) asphalt ribbon, bevelled edges, collider.
- `scripts/world/interchange_builder.gd` (InterchangeBuilder) bridges, piers, abutments of the diamond interchanges.
- `scripts/world/terrain_data.gd` (TerrainData) height field with roads carved in; analytic mountains.
- `scripts/world/terrain_builder.gd` (TerrainBuilder) chunked flat-shaded terrain meshes + collider.
- `scripts/world/vegetation_builder.gd` (VegetationBuilder) trees, rocks, grass, flowers via MultiMesh chunks.
- `scripts/world/props_builder.gd` (PropsBuilder) posts, fences, guard rails, median barrier, farms, turbines, clouds.
- `scripts/world/scenery_meshes.gd` (SceneryMeshes) low-poly meshes for vegetation and props.
- `scripts/world/mesh_builder.gd` (MeshBuilder) flat-shaded vertex-coloured triangle accumulator -> ArrayMesh.
- `scripts/world/collider_batch.gd` (ColliderBatch) thousands of static colliders straight into PhysicsServer.
- `scripts/world/palette.gd` (Palette) shared colours and materials.
- `scripts/debug/autodrive.gd` autopilot lap, drift scenarios, `--crashtest`, screenshots (flags in its header).
- `shaders/` road.gdshader (markings), grass.gdshader (sway), speed_overlay.gdshader, speed_streak.gdshader.

## Key scenes
- `scenes/main.tscn` root: nodes `World` (WorldGenerator), `Car`, `ChaseCamera`, `Traffic`, `WorldEnvironment`, HUD.
  `project.godot` runs it by default.
- `scenes/car.tscn` the player car (CarController + visuals + audio + input).

## Running
Binary: `~/Applications/Godot-stable_linux.x86_64` (call it `$G`). Run from the repo root. Full recipes: the
`playtest` skill (`.claude/skills/playtest/SKILL.md`); use it for any run/screenshot/error check.
- Headless check (no display needed, shows script/parse errors): `timeout 120 $G --headless --path . --quit-after 60 2>&1 | grep -E 'ERROR|SCRIPT|Parse' | head`
- Autodrive/screenshots need a display: prefix `DISPLAY=:0`, add `--disable-vsync` for FPS numbers. Headless autodrive
  works for physics checks (no shots).
- Strict warning check of one file: write `override.cfg` containing
  `[debug]` / `gdscript/warnings/treat_warnings_as_errors=true`, run
  `$G --headless --path . --check-only --script <file.gd>`, then delete `override.cfg` (never commit it).
- After adding new `class_name` scripts or assets run `$G --headless --path . --import` once.
- On the hybrid-GPU laptop the README's `__NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only __GLX_VENDOR_LIBRARY_NAME=nvidia` is only needed for interactive play.

## Working rules for agents
- Do not cat whole scripts (many are 15-28k chars). Use `grep -n`, then `sed -n 'A,Bp'` line ranges. The map above
  says where things live; `grep -n '^class_name\|^##' -m5 <file>` gives a file's purpose.
- Read screenshots sparingly: at most 2-3 per check, only the ones that matter. `--shots` images are 960 px wide
  by default (`--shot-width=` to change). Do not screenshot just to confirm something a log line can show.
- Never let Godot output flood the context: pipe through `grep -E ... | tail -40` or pass `--quiet` to autodrive.
- One feature per subagent/session; keep tunables as `@export` vars and update `README.md` when behaviour or flags change.
- Do not commit scratch files (`override.cfg`, `scripts/debug/*_tmp.gd`); use `/tmp` for outputs.
