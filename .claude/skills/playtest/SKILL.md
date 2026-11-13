---
name: playtest
description: Run Echo Racers headless or in autodrive, take screenshots to verify visual changes, and check for GDScript errors. Use after editing scripts/scenes, or when asked to verify, screenshot or playtest the game.
---

# Playtest

All commands run from the repo root. `G=~/Applications/Godot-stable_linux.x86_64`. Always filter output.

## (a) Headless parse/error check (no display)
```sh
G=~/Applications/Godot-stable_linux.x86_64
timeout 120 $G --headless --path . --quit-after 60 2>&1 | grep -E 'ERROR|SCRIPT|Parse|WARNING' | head -20
```
No output means the project loads cleanly. After adding a new `class_name` or asset, run `--import` once first:
`timeout 200 $G --headless --path . --import >/dev/null 2>&1`.
For a headless physics check, add `-- --autodrive --quiet` and grep `ERROR|SCRIPT|Rendering|max speed`.

## (b) Autodrive with screenshots (needs a display)
```sh
rm -rf /tmp/er_shots && mkdir -p /tmp/er_shots
DISPLAY=:0 timeout 200 $G --path . -- --autodrive --quiet --shots=/tmp/er_shots 2>&1 \
  | grep -E 'ERROR|SCRIPT|Saved|Rendering|Autodrive done|---|Crash test' | tail -40
```
Takes ~45 s of game time (`DURATION`), shots at 12/22.5/23/30 s (`SHOT_TIMES`), 960 px wide
(`--shot-width=<px>` to change). Add `--traffic` to spawn traffic, `--disable-vsync` before `--` for real FPS.

## (c) Other modes (flags documented in the header of scripts/debug/autodrive.gd)
```sh
# another road of the network (highway: inner lane, up to 260 km/h); also link_north, mountain_road, ...
DISPLAY=:0 timeout 200 $G --path . -- --autodrive --quiet --road=highway --traffic --shots=/tmp/er_shots
# several roads in turn: exit the highway, cross the bridge, rejoin the other carriageway
timeout 400 $G --headless --path . -- --autodrive --quiet --route=highway,ramp_north_off1,link_north,ramp_north_on2,highway
# fog-free stills from a free camera (x,y,z looking at tx,ty,tz), saved as view_<k>.png before the drive
DISPLAY=:0 timeout 200 $G --path . -- --autodrive --quiet --shots=/tmp/er_shots --view=overview --view=100,30,-900,100,0,-700
# echo mode end to end (record, editor, save, race the ghost); shots echo_editor*.png, echo_race.png
DISPLAY=:0 timeout 200 $G --path . -- --autodrive --quiet --echotest --shots=/tmp/er_shots 2>&1 | grep -E 'ERROR|SCRIPT|Echo test|Saved'
# scripted crashes against traffic (prints pre/post velocities; --quiet drops the per-0.25 s timelines)
timeout 300 $G --headless --path . -- --autodrive --crashtest 2>&1 | grep -E 'ERROR|SCRIPT|Crash test|---' | tail -30
```

## Output and screenshots
- Never run Godot unfiltered: without `--quiet` autodrive prints 1 Hz lap lines and 10 Hz drift/crash timelines
  (can be ~20k tokens). Keep `| grep -E '...' | tail -40`.
- Useful lines: `ERROR`/`SCRIPT ERROR` (failures), `Saved <path>`, `Rendering: average N FPS`,
  `--- drift event ...` summaries, `Autodrive done: max speed ...`, `Crash test '...': closing ...`.
- Look at only the 1-3 shots that show the change (e.g. `shot_1.png`, `view_0.png`); do not open them all.
  To check size without viewing: `python3 -c "import struct;print(struct.unpack('>II',open('/tmp/er_shots/shot_0.png','rb').read()[16:24]))"`.
- Clean up: nothing in the repo should change from a playtest (`git status --short`).
