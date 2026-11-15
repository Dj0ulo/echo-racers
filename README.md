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

### Editing in the Godot editor

The world is generated when the game starts, so `scenes/main.tscn` looks empty in the editor. Select the
`World` node and tick **Editor Preview** in the Inspector to build it in the 3D view (takes a few seconds;
**Regenerate preview** rebuilds it, e.g. after changing `World Seed`). The generated nodes are not shown in
the Scene panel nor saved; generation is deterministic, so nodes you add to the scene (e.g. as children of
`World`) stay exactly where you put them relative to the roads and terrain.

## Controls

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Accelerate | W / Up | Right trigger |
| Brake / reverse | S / Down | Left trigger |
| Steer | A, D / Left, Right | Left stick |
| Handbrake (drift) | Space | X / Square |
| Boost (nitro) | Shift | A / Cross |
| Reset car to road (in an echo race: last checkpoint) | R | hold LT + RT for 2 s |
| Map / GPS destination | M | Back / Select |
| Echo race menu | Tab | Y / Triangle |
| Look around (springs back on release) | — | Right stick (±90°) |
| Look back (hold) | C | LB |
| Pause menu (Resume / Save / Quit) | Esc | Start |

**Start** (Esc) pauses and opens a centered menu: up/down (arrows, d-pad, stick) + Enter / A, or click with the
mouse; Start / Esc / B resumes (Q still quits). **Save** writes the car's position and heading and the time of day
to `user://savegame.cfg`; the next launch starts there (at rest) instead of on the road spawn. Debug `--autodrive`
runs ignore the save. Quit does not save. The pause menu is not available in the echo editor or over the echo menu
and the map, which pause the game themselves.

## Map and GPS

Press **Select** (M) at any time (except in the echo editor) to pause and open a full-screen top-down map, north
up. Pan with the left stick / WASD / arrows / mouse drag and zoom with LT/RT / Q E / mouse wheel (or right stick).
**A** (Enter) puts a destination under the crosshair, or click a spot; **X** (F, Delete) clears it; **B** / Select
/ Esc closes the map. Echo race starts, delivery offers and the active drop-off snap: bring the mouse pointer (or
the crosshair, which then eases onto it) near one and it is selected, its course is previewed on the map (the
echo's best run with numbered checkpoints and a chequered finish, or the delivery's road route to its drop-off) and
a panel at the top right shows its details (length, best echo, par, reward / cargo, pay, time left, distance by
road from you) with a GPS button: A / Enter, or a click on the button or the point, sets the destination there.
The destination gets a gold light beam in the world and a gold pin on both maps, and the
route (rerouted every 0.8 s) is drawn on both maps and as a glowing gold filament that flies
20 m above the ground (already at that height above the car), loosely following the route and cutting its bends; when a reroute changes the route it glides onto the new one (`filament_morph`, 0.7 s). The route always starts at the car: it
follows the road network (A* on a graph of the roads that respects one-way ramps and the highway carriageways) but
crosses the fields to join it, to leave it, or skips it entirely whenever that is shorter (off-road metres count
1.6x, `offroad_cost`). The GPS filament and minimap route are hidden during echo races, recording and the editor,
as are the destination beacon and the echo beacons (only the checkpoints show; in a race the filament follows the
echo's path instead, see below). Reaching the destination clears it.
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
  (two neon pillars with sparks). A ring counts as soon as any part of the car touches its cylinder, from any
  direction; a gate must be driven through forwards (any part of the car between the pillars).
- **Save** closes the editor; the course gets a small neon blue marker (post, ground ring, chevrons) at its start,
  also shown on the minimap (pinned to the rim when far away). Back in the car view, the end-of-race menu shows the
  recorded time and offers **Race the new echo** or **Exit race mode**. **Discard** (after a confirm) returns to
  the car view with **Record again from the same start** or **Exit race mode**.

Drive into a beacon and press Y to see its echoes, best first, and pick the one to race: 3-2-1-GO, then pass every
checkpoint in order (the next one pulses; it is also the pink marker on the minimap) against a hologram ghost of the
echo (also a cyan arrow on the minimap). The HUD shows the time and your split against the echo at each checkpoint.
The filament and the minimap route turn blue and follow the raced echo's path from the car to the finish (kept on the
current leg between checkpoints, `Gps.race_step` / `race_lost`). During a race Y offers restart from the start,
**Direction line: On/Off** (toggles that line, kept for the session) or exit; reset puts you back on the last checkpoint passed. Beat the echo and you can save your run
as a new echo of that course (older ones are kept), then race that new echo straight away. Every race (and restart)
starts with a full boost gauge. The editor's ghost-car cursor grows with the zoom only up to a cap
(`EchoEditor.cursor_max_scale`). Courses are saved in `user://echoes/` (one `.echo` file each,
`~/.local/share/godot/app_userdata/<project>/echoes/` on Linux). Run poses are saved quantized (1 cm,
~0.1°), delta-coded and zstd-compressed, about 8× smaller than raw floats; old version-1 files still load.

Code: `scripts/echo/` — `echo_manager.gd` (game flow, menus, recording at 30 Hz, checkpoint crossing),
`echo_editor.gd` (top view), `echo_ui.gd` (side menu, timer, countdown, beeps), `echo_track.gd` / `echo_run.gd`
(data + save files), `checkpoint_gate.gd`, `ghost_car.gd`, `echo_point.gd` (beacon) and `neon.gd` (glow shaders).

## Economy

The currency sign is a capital R with a vertical bar through it (like the dollar's S), shown as R⃒ below. The
balance sits top right on the HUD; on every change it counts to the new value, flashes green (gain) or red (spend)
and floats the signed amount under it. A new game starts with R⃒500 (`Wallet.start_balance`). The wallet is saved to
`user://wallet.cfg` on every change (independent of the pause-menu Save); autodrive/debug runs use a fresh scratch
`user://wallet_test.cfg` instead.

- **Creating an echo course costs money**: R⃒250 × 1.25ⁿ rounded to R⃒10 (R⃒250, 310, 390, 490, ...), where n is the
  number of courses ever created (persisted in the wallet, so deleting courses does not lower the price;
  `EchoManager.course_base_cost`, `course_cost_growth`, `course_cost_step`). The price is shown on the Y menu's
  record entry (greyed out, with a "Not enough money" line, when unaffordable) and on the editor's **Save**; it is
  charged only when the course is saved (a discarded recording is free). Creating an echo earns nothing.
- **Echo races pay** only when the time beats both the course's **best echo** and its **par** time. Par is a
  theoretical minimum: the crow-flies horizontal distance between consecutive checkpoints (start, checkpoints,
  finish) at 100 km/h (`par_speed_kmh`) plus every climb between them at 10 m/s (`par_climb_speed`), so a
  deliberately slow first echo cannot be farmed. Reward = 20 × (par − time) + 100 × (best − time), seconds,
  rounded (`reward_per_par_second`, `reward_per_echo_second`). Once paid, the time becomes the course's paid record
  (saved in its `.echo` file) and "best" is min(best echo, paid record), so re-racing without saving cannot collect
  the same margin twice. The finish banner and result menu show the par, whether it was beaten and the reward (or
  why nothing was paid); the course and race menus show the par and the time to beat.
- **Delivery missions pay** by distance, see below.

Code: `scripts/game/wallet.gd` (`Wallet`: `balance`, `earn(amount, reason)`, `spend(amount, reason) -> bool`,
`can_afford`, `get_stat` / `set_stat`, signal `changed(balance, delta, reason)`, `Wallet.format(amount, signed)`).
The sign is `Wallet.SIGN`, a private-use character U+E000 followed by "R": a procedural bitmap font, added at
startup as a fallback of the default theme font, draws U+E000 as a zero-width bar over the next letter, so it works
in any Label/Button at any size without assets.

## Delivery missions

From time to time a delivery offer appears somewhere on the roads (not on the highway or its ramps): a lime neon
post with a spinning parcel, a pulsing ring and a sign with its reward and distance; it is also a lime parcel on the
minimap (pinned to the rim when far) and on the world map. The first one comes about 15 s after start, then one every
45-120 s, up to 3 open at once, at least 300 m from the car; an untaken offer disappears after 4 minutes.
Stop (below 35 km/h) inside an offer's ring in free roam and its menu opens: the cargo, where the customer is
(crow-flies distance and compass direction, distance by road), the reward and how long the offer stays open.
**Accept** makes it the active delivery (one at a time; the Accept entry is greyed out while one is running);
**Decline** keeps the offer on the map but it only asks again once you have left its ring and come back. Offers
never open during an echo race, recording or the editor.

Parcels are not always on the road: about 40 % of offers and drop-offs sit out in a field, 20-60 m off the road
edge, on gentle ground (at most 14°) that can be driven to straight from the road, away from any other road and with
no tree, fence, guard rail or building on the way or within 6 m. The offer menu says when the drop-off is across a
field; the GPS leaves the road at the nearest point and the filament goes straight to the beacon.

The drop-off is a random spot (roadside or field) 600 m - 3 km away by road. It gets a tall lime light beam and a lime pin on
the minimap and world map, and the GPS routes to it. Drive within 25 m of it (free roam) to deliver: the reward is
paid with a "DELIVERED" banner. Each offer has a **time limit**, shown in its menu: 10 s + the route at an
average 120 km/h, rounded up to 5 s (about 0:30 for 600 m, 1:00 for 1.6 km, 1:40 for 3 km). It starts on Accept and
counts down at the top of the screen (in the echo-race timer style, lime, red with a beep every second in the last
10-20 s); it stops while the game is paused (pause menu, world map, menus) but keeps running during an echo race. If
it runs out the delivery is cancelled: no pay, the beam, pin and GPS route are cleared and a "TIME'S UP" banner shows
(`deliveries_failed` stat). Reward = route km (including the straight field legs) × R⃒160 × a random factor in [0.85, 1.2], rounded to R⃒5 (about
R⃒250 for a 1.6 km delivery). While a delivery is active, the free-roam Y menu can point the GPS back to the
drop-off (after you set another destination on the map) or abandon the delivery (no pay, no penalty).
**Tips**: arrive with at least 30 % of the time limit left (`tip_min_early`) and the customer may tip you, paid on
top of the reward and shown in the banner ("+R⃒155  + R⃒20 tip"). The chance grows from 30 % at that threshold to 80 %
with 75 % of the time left (`tip_full_early`), and so does the size: 5 % to 20 % of the reward (± 4 points of
randomness), now and then (8 % of tips) a generous 25-30 %, rounded to R⃒5 and at least R⃒5. On a R⃒250 delivery
that is about R⃒15 just early enough, R⃒40-50 very early, R⃒65-75 when generous. No tip when you arrive late in
the clock. The wallet totals them (`tips` amount and `tips_count` stats).
Missions are not saved: open offers and the active delivery are gone after a restart (the money earned is kept).
The wallet counts completed deliveries (`deliveries` stat).

Code: `scripts/game/missions.gd` (`MissionManager`, all tunables exported: `first_offer_delay`,
`spawn_interval_min/max`, `max_offers`, `offer_lifetime`, `min_offer_distance`, `pickup_radius`,
`pickup_speed_kmh`, `delivery_radius`, `min_route`, `max_route`, `pay_per_km`, `pay_random_min/max`, `pay_step`, `time_base`, `time_avg_speed_kmh`, `time_step`, `time_warning`, `time_beep`, `tip_min_early`, `tip_full_early`, `tip_chance_min/max`,
`tip_percent_min/max`, `tip_percent_jitter`, `tip_generous_chance`, `tip_generous_min/max`, `tip_step`, `tip_min`, `offroad_chance`, `offroad_min_distance`, `offroad_max_distance`,
`offroad_max_slope`, `offroad_clearance`),
`scripts/game/mission_marker.gd` (`MissionMarker`, the lime beacon). Debug runs (`--autodrive`) get no random
offers.

## Day and night

Time flows from 10:00 at startup: 10 real minutes of daylight (06:00-18:00) then 10 of night (`DayNight.day_minutes`,
`night_minutes`). The sun rises in the east, culminates in the south and sets in the west; sunrise and sunset paint a
warm glow along the horizon and light the clouds from below, then a blue-purple twilight gives way to a starry sky
and a cool full-moon light. The car's headlights come on at dusk, and so do the traffic's (glowing lenses plus a light pool on the road). The world map and the echo editor always show the
world in daylight. Colours per sun elevation live in the `_KEYS` table of `scripts/world/day_night.gd`, which also
owns the sky shader.

## Layout

- `scripts/vehicle/` — `car_controller.gd` (raycast suspension + arcade tyre physics, all tunables exported),
  `car_visuals.gd` (procedural body, wheels, lights, tyre smoke), `vehicle_input.gd` (input actions → commands,
  controller rumble). Every body impact (wall/prop hits from a velocity jump, traffic hits reported by the
  manager) goes through the controller's `impacted` signal: crash sound, camera shake and a pad vibration scaled
  by the impact strength (`rumble_*` exports on `Car/Input`, `Crash Shake` exports on the camera).
- Audio (`scripts/vehicle/car_audio.gd`, node `Car/Audio`) — fully synthesised car sound on its own `CarAudio` bus
  (hard limiter): a real-time engine voice (firing-pulse wavetables, simulated 6-speed gearbox with shift cuts,
  downshift blips, rev limiter and overrun pops), tyre squeal/skid, wind, road rumble, off-road crunch, suspension
  thumps, gear and handbrake clicks. Light taps make a knock; real hits play one of several layered crashes
  (chassis whump, crumpling metal, panel ring, debris, glass on the heaviest). Boosting plays two layers tuned to A: a thrust roar
  (noise rung on A2/E3/A3 + turbine whine on A4/A5) and a warm synthwave drone (detuned round saws on A2 with a slow
  breathing sweep). One shared envelope and pitch curve drive both: they swell in together, climb a fifth while the
  boost is held and fade out together, with a whoosh at the start and a blow-off at the release (`boost_*` exports).
  `car_sound_synth.gd` generates all the samples at startup.
- `scripts/camera/` — `chase_camera.gd` (smoothed chase camera: speed-based FOV/pull-back/lowering, acceleration
  lag and FOV kick, subtle noise shake, trauma shake on crashes, right-stick free look and rear view) and `speed_effects.gd` (wind-streak particles + speed overlay above ~80 km/h).
- `scripts/world/` — `world_generator.gd` defines the road network and orchestrates `terrain_data.gd` (height
  field, every road carved in, computed on the WorkerThreadPool), `road_path.gd` (spline roads, open or looped,
  with a configurable cross-section: lanes, lane width, median) and the `*_builder.gd` mesh/collider builders
  (terrain is split into frustum-culled chunks; trees keep ≥5 m apart and thin out near roads, only their trunks up to the
  foliage are solid, and they switch to cheap stand-ins past ~420 m; thousands of static
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
- `scripts/game/` — `main.gd` (spawn, pause menu, save game, reset), `pause_menu.gd`, `hud.gd` and `minimap.gd` (bottom-left, heading-up circular
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
`--shots` images are 640 px wide (`--shot-width=<px>`); `--quiet` drops the periodic telemetry lines. `--duration=<s>`
sets the lap length in game time (default 44; `--duration=0` with `--view`s quits right after the stills).
`tools/gd` wraps these runs with filtered output (see its header).
`--time=<hour>` (e.g. `--time=17.6` for a sunset, `--time=23` for night) sets the starting time of day and
`--timescale=<x>` speeds the day/night cycle up (any mode, not only autodrive).
`--autodrive --echotest [--shots=/abs/dir]` runs the echo mode end to end through simulated menu presses: records a
14 s run, places checkpoints on its extremes in the editor, saves it, picks "Race the new echo"
in the result menu, races its ghost (following its line a bit
faster), prints the splits and result, saves the new echo, then deletes the scratch course (`user://echoes_test`).
It also checks the course price is charged on save, prints the par and the race reward, checks the same time is not
paid twice, that the world map snaps onto the course start (selection, course preview, GPS button; shot
`echo_map.png`), and deletes the scratch wallet (`user://wallet_test.cfg`, reset at the start of every `--autodrive` run).
`--autodrive --maptest [--shots=/abs/dir]` opens the world map through its input action, sets a destination 450 m
ahead (shots `map.png`, then `filament.png` after closing the map), then routes to the middle of every road and
prints route vs straight-line distances.
`--autodrive --missiontest [--shots=/abs/dir]` (`tools/gd missiontest`) spawns a delivery offer just ahead of the
car, checks its menu opens (shot `mission_offer.png`), accepts it with a simulated ui_accept, checks the GPS route,
spawns a random offer, checks the world map snaps onto it (selection, route preview, GPS button; shot
`mission_map.png`), teleports to the drop-off and checks the scratch wallet
was paid the reward; prints `Mission test: PASS` or `FAIL: <why>`. Real gamepad buttons are ignored during it (Godot reads joypads even
unfocused; add `--audio-driver Dummy` before `--` to keep test runs silent while someone plays).
