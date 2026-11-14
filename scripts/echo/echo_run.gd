class_name EchoRun
extends RefCounted
## One recorded drive (an "echo"): the car's pose sampled at a fixed rate plus its checkpoint split times.

const RATE := 30.0  ## Samples per second (sample k is at k / RATE seconds after GO).
const POS_STEP := 0.01     ## Saved position quantization (metres).
const ROT_SCALE := 8192.0  ## Saved quaternion component quantization (steps per unit).

var positions := PackedVector3Array()
var rotations := PackedVector4Array()  ## Quaternions as (x, y, z, w).
var splits := PackedFloat32Array()     ## Time at each checkpoint of its track: [0] = start (0), last = finish.
var time := 0.0                        ## Finish time in seconds.
var date := ""


func add_sample(xform: Transform3D) -> void:
	positions.append(xform.origin)
	var q := xform.basis.get_rotation_quaternion()
	rotations.append(Vector4(q.x, q.y, q.z, q.w))


func sample_count() -> int:
	return positions.size()


func duration() -> float:
	return maxf(positions.size() - 1, 0) / RATE


## Interpolated pose at `t` seconds (clamped to the recording).
func transform_at(t: float) -> Transform3D:
	var n := positions.size()
	if n == 0:
		return Transform3D.IDENTITY
	var f := clampf(t * RATE, 0.0, n - 1.0)
	var i := mini(int(f), maxi(n - 2, 0))
	var j := mini(i + 1, n - 1)
	var u := clampf(f - i, 0.0, 1.0)
	var a := rotations[i]
	var b := rotations[j]
	var q := Quaternion(a.x, a.y, a.z, a.w).normalized().slerp(Quaternion(b.x, b.y, b.z, b.w).normalized(), u)
	return Transform3D(Basis(q), positions[i].lerp(positions[j], u))


## Copy of the first `last_index + 1` samples.
func trimmed(last_index: int) -> EchoRun:
	var r := EchoRun.new()
	var n := clampi(last_index + 1, 1, positions.size())
	r.positions = positions.slice(0, n)
	r.rotations = rotations.slice(0, n)
	r.date = date
	return r


## Poses are packed (see `_pack_poses`), about 8x smaller than raw float arrays; ~1 cm / ~0.1 deg error.
func to_dict() -> Dictionary:
	var raw := _pack_poses()
	return {"poses": raw.compress(FileAccess.COMPRESSION_ZSTD), "poses_size": raw.size(), "count": positions.size(),
		"pos_step": POS_STEP, "rot_scale": ROT_SCALE, "splits": splits, "time": time, "date": date}


static func from_dict(d: Dictionary) -> EchoRun:
	var r := EchoRun.new()
	if d.has("poses"):
		var packed: PackedByteArray = d["poses"]
		r._unpack_poses(packed.decompress(int(d.get("poses_size", 0)), FileAccess.COMPRESSION_ZSTD),
			int(d.get("count", 0)), float(d.get("pos_step", POS_STEP)), float(d.get("rot_scale", ROT_SCALE)))
	else:  # Version 1 files: raw float arrays.
		r.positions = d.get("positions", PackedVector3Array())
		r.rotations = d.get("rotations", PackedVector4Array())
	r.splits = d.get("splits", PackedFloat32Array())
	r.time = d.get("time", 0.0)
	r.date = d.get("date", "")
	return r


static func format_time(t: float) -> String:
	if is_nan(t) or is_inf(t):
		return "--:--.---"
	return "%d:%06.3f" % [int(t / 60.0), fmod(t, 60.0)]


static func format_delta(d: float) -> String:
	return ("+" if d >= 0.0 else "-") + "%.3f" % absf(d)


## Seven integer streams (px, py, pz, qx, qy, qz, qw), quantized, one after the other. Each value is stored as
## its difference from a constant-velocity prediction (2 * prev - prev2), as a zigzag varint: small and
## repetitive, so the zstd pass on top compresses it well.
func _pack_poses() -> PackedByteArray:
	var n := positions.size()
	var cols: Array[PackedInt64Array] = []
	for c in 7:
		var col := PackedInt64Array()
		col.resize(n)
		cols.append(col)
	var prev := Vector4(0, 0, 0, 1)
	for i in n:
		var p := positions[i]
		var q := rotations[i]
		if q.dot(prev) < 0.0:
			q = -q  # Same rotation; keeps consecutive quaternions (and their deltas) close.
		prev = q
		cols[0][i] = roundi(p.x / POS_STEP)
		cols[1][i] = roundi(p.y / POS_STEP)
		cols[2][i] = roundi(p.z / POS_STEP)
		cols[3][i] = roundi(q.x * ROT_SCALE)
		cols[4][i] = roundi(q.y * ROT_SCALE)
		cols[5][i] = roundi(q.z * ROT_SCALE)
		cols[6][i] = roundi(q.w * ROT_SCALE)
	var out := PackedByteArray()
	for col in cols:
		for i in n:
			var z := col[i] - _predict(col, i)
			z = (z << 1) ^ (z >> 63)
			while z >= 0x80:
				out.append((z & 0x7F) | 0x80)
				z >>= 7
			out.append(z)
	return out


## Inverse of `_pack_poses`. Rotations stay as quantized (not renormalized): `transform_at` normalizes.
func _unpack_poses(data: PackedByteArray, n: int, pos_step: float, rot_scale: float) -> void:
	var cols: Array[PackedInt64Array] = []
	var k := 0
	for c in 7:
		var col := PackedInt64Array()
		col.resize(n)
		for i in n:
			var z := 0
			var shift := 0
			while k < data.size():
				var b := data[k]
				k += 1
				z |= (b & 0x7F) << shift
				shift += 7
				if b < 0x80:
					break
			col[i] = ((z >> 1) ^ -(z & 1)) + _predict(col, i)
		cols.append(col)
	positions.resize(n)
	rotations.resize(n)
	for i in n:
		positions[i] = Vector3(cols[0][i], cols[1][i], cols[2][i]) * pos_step
		rotations[i] = Vector4(cols[3][i], cols[4][i], cols[5][i], cols[6][i]) / rot_scale


static func _predict(col: PackedInt64Array, i: int) -> int:
	if i >= 2:
		return 2 * col[i - 1] - col[i - 2]
	return col[i - 1] if i == 1 else 0
