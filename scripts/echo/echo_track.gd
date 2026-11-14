class_name EchoTrack
extends RefCounted
## A saved echo course: start pose, checkpoints (start and finish included), gate style and every echo raced
## on it, best first. One file per course in `EchoTrack.directory`.

enum Style { RINGS, GATES }

const VERSION := 2  ## 2: packed run poses (EchoRun.to_dict). Version 1 files still load.

static var directory := "user://echoes"  ## The echo test switches this to a scratch folder.

var id := ""
var name := ""
var style := Style.RINGS
var start := Transform3D.IDENTITY          ## Car pose at GO.
var checkpoints := PackedVector3Array()    ## Car-centre positions; [0] = start, last = finish.
var directions := PackedVector3Array()     ## Horizontal travel direction through each checkpoint.
var length := 0.0                          ## Metres, along the original run.
var runs: Array[EchoRun] = []              ## Sorted best (fastest) first.


func best_time() -> float:
	return runs[0].time if not runs.is_empty() else INF


## Adds a run, keeps the list sorted and returns its 1-based rank.
func add_run(run: EchoRun) -> int:
	runs.append(run)
	runs.sort_custom(func(a: EchoRun, b: EchoRun) -> bool: return a.time < b.time)
	return runs.find(run) + 1


## Pose to put the car back on checkpoint `i` (facing the direction of travel).
func checkpoint_transform(i: int) -> Transform3D:
	if i <= 0:
		return start
	var d := directions[i]
	d.y = 0.0
	if d.length_squared() < 1e-6:
		d = Vector3.FORWARD
	return Transform3D(Basis.looking_at(d.normalized(), Vector3.UP), checkpoints[i] + Vector3.UP * 0.3)


func style_name() -> String:
	return "neon rings" if style == Style.RINGS else "light gates"


func save() -> Error:
	DirAccess.make_dir_recursive_absolute(directory)
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f == null:
		push_error("Echo: cannot write %s (%s)" % [_path(), error_string(FileAccess.get_open_error())])
		return FileAccess.get_open_error()
	var run_dicts: Array[Dictionary] = []
	for r in runs:
		run_dicts.append(r.to_dict())
	f.store_var({"version": VERSION, "id": id, "name": name, "style": style, "start": start,
		"checkpoints": checkpoints, "directions": directions, "length": length, "runs": run_dicts})
	return OK


func erase() -> void:
	DirAccess.remove_absolute(_path())


func _path() -> String:
	return "%s/%s.echo" % [directory, id]


static func new_id() -> String:
	return "%d_%04d" % [int(Time.get_unix_time_from_system()), randi() % 10000]


## Older saves measured each checkpoint's direction over +-3 samples, which flipped it when the car stood still
## there (typically the finish, stopped on a slope). Recompute them from the run the track was recorded from:
## the one whose split samples sit exactly on the checkpoints.
func _repair_directions() -> void:
	if directions.size() != checkpoints.size():
		return
	for r in runs:
		if r.splits.size() != checkpoints.size():
			continue
		var idx: Array[int] = []
		for k in checkpoints.size():
			var s := roundi(r.splits[k] * EchoRun.RATE)
			if s >= r.sample_count() or r.positions[s].distance_to(checkpoints[k]) > 0.05:
				break
			idx.append(s)
		if idx.size() == checkpoints.size():
			for k in range(1, idx.size()):
				directions[k] = r.direction_at(idx[k])
			return


## RINGS tracks: re-time `run`'s splits (and finish time) to the moment its car first touched each ring of
## radius `r`, the rule races use, instead of when its centre was on the checkpoint. Left untouched if the run
## misses a ring (it was not driven on this track's rings).
func retime_to_rings(run: EchoRun, r: float) -> void:
	if style != Style.RINGS:
		return
	var n := run.sample_count()
	var out := PackedFloat32Array([0.0])
	var j := 1
	for k in range(1, checkpoints.size()):
		var ground := checkpoints[k] + Vector3.DOWN * 0.7  # Car centre -> ground under it.
		var t := -1.0
		while j < n:
			var q := run.rotations[j]
			var fwd := Quaternion(q.x, q.y, q.z, q.w) * Vector3.FORWARD
			var u := CheckpointGate.touch_fraction(ground, r, run.positions[j - 1], run.positions[j], fwd)
			if u >= 0.0:
				t = (j - 1 + u) / EchoRun.RATE
				break
			j += 1
		if t < 0.0:
			return
		out.append(t)
	run.splits = out
	run.time = out[out.size() - 1]


static func load_all() -> Array[EchoTrack]:
	var out: Array[EchoTrack] = []
	var dir := DirAccess.open(directory)
	if dir == null:
		return out
	for file in dir.get_files():
		if not file.ends_with(".echo"):
			continue
		var f := FileAccess.open("%s/%s" % [directory, file], FileAccess.READ)
		if f == null:
			continue
		var d: Variant = f.get_var()
		if d is Dictionary:
			var t := _from_dict(d)
			if t:
				out.append(t)
	out.sort_custom(func(a: EchoTrack, b: EchoTrack) -> bool: return a.id < b.id)
	return out


static func _from_dict(d: Dictionary) -> EchoTrack:
	if int(d.get("version", 0)) not in [1, VERSION]:
		return null
	var t := EchoTrack.new()
	t.id = d.get("id", "")
	t.name = d.get("name", "Echo")
	t.style = int(d.get("style", Style.RINGS)) as Style
	t.start = d.get("start", Transform3D.IDENTITY)
	t.checkpoints = d.get("checkpoints", PackedVector3Array())
	t.directions = d.get("directions", PackedVector3Array())
	t.length = d.get("length", 0.0)
	for rd: Variant in d.get("runs", []):
		if rd is Dictionary:
			t.runs.append(EchoRun.from_dict(rd))
	if t.id.is_empty() or t.checkpoints.size() < 2 or t.runs.is_empty():
		return null
	t._repair_directions()
	t.runs.sort_custom(func(a: EchoRun, b: EchoRun) -> bool: return a.time < b.time)
	return t
