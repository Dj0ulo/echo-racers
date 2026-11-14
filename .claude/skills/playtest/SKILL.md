---
name: playtest
description: Run Echo Racers headless or in autodrive, take screenshots to verify visual changes, and check for GDScript errors. Use after editing scripts/scenes, or when asked to verify, screenshot or playtest the game.
---

# Playtest

Use `tools/gd` (header documents it): runs from the repo root, bakes in the binary (`G` env override), timeouts,
`DISPLAY=:0` and always filters output. Extra args go to the game; engine flags via `GD_FLAGS="--disable-vsync"`.

## (a) Check errors: fast first, then full
```sh
tools/gd check --fast   # ~0.4 s/file, --check-only on changed/untracked .gd files (parse/type errors)
tools/gd check          # same + full headless load (~8 s; catches unknown members on typed vars)
```
Prints one `OK` line when clean. After adding a `class_name` or asset run `tools/gd import` once.

## (b) Autodrive
```sh
tools/gd drive --duration=10           # headless physics check, no shots
tools/gd shots                         # display, 44 s lap, shots at 12/22.5/23/30 s in /tmp/er_shots (SHOTS=...)
tools/gd shots --view=overview --duration=0    # just the still(s), quits right after (~10 s)
tools/gd shots --duration=13           # one shot (the 12 s one)
```
Shots are 640 px wide (`--shot-width=<px>`). Add `--traffic` for traffic. `--duration=<s>` shortens the lap; later
events/shots just don't happen. Prefer short durations: a full lap is ~50 s wall time.

## (c) Other modes (flags documented in the header of scripts/debug/autodrive.gd)
```sh
# another road of the network (highway: inner lane, up to 260 km/h); also link_north, mountain_road, ...
tools/gd shots --road=highway --traffic
# several roads in turn: exit the highway, cross the bridge, rejoin the other carriageway
tools/gd drive --route=highway,ramp_north_off1,link_north,ramp_north_on2,highway
# fog-free stills from a free camera (x,y,z looking at tx,ty,tz), saved as view_<k>.png before the drive
tools/gd shots --duration=0 --view=overview --view=100,30,-900,100,0,-700
# echo mode end to end (record, editor, save, race the ghost); shots echo_editor*.png, echo_race.png
tools/gd echotest
# scripted crashes against traffic (prints pre/post velocities; --quiet drops the per-0.25 s timelines)
tools/gd crashtest
```

## Output and screenshots
- Only bypass `tools/gd` if you must; never run Godot unfiltered: without `--quiet` autodrive prints 1 Hz lap lines and 10 Hz drift/crash timelines
  (can be ~20k tokens). Keep `| grep -E '...' | tail -40`.
- Useful lines: `ERROR`/`SCRIPT ERROR` (failures), `Saved <path>`, `Rendering: average N FPS`,
  `--- drift event ...` summaries, `Autodrive done: max speed ...`, `Crash test '...': closing ...`.
- Look at only the 1-3 shots that show the change (e.g. `shot_1.png`, `view_0.png`); do not open them all.
  To check size without viewing: `python3 -c "import struct;print(struct.unpack('>II',open('/tmp/er_shots/shot_0.png','rb').read()[16:24]))"`.
- Clean up: nothing in the repo should change from a playtest (`git status --short`).
