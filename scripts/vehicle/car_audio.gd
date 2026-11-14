extends Node
## Procedural car audio. Lives under the CarController and only reads its public state.
##
## - Engine: a real-time voice (AudioStreamGenerator filled in _process) that scans single-cycle
##   firing-pulse wavetables at the simulated RPM, cross-fades soft/hard tables by throttle load,
##   adds combustion grit, soft-clips and runs through a resonant low-pass plus a low-shelf boost
##   (sub-octave body from the tables is lifted, highs are left alone). A simulated 6-speed
##   gearbox (+ reverse) drives the RPM, with throttle cuts on upshift, rev-matching blips on
##   downshift, a rev limiter and a few overrun pops on lift-off.
## - Loops (pre-synthesised AudioStreamWAVs, volume/pitch driven per frame): tyre squeal (lateral
##   slip), tyre skid (handbrake lock, hard braking, launch chirp), wind, road rumble, off-road crunch.
## - One-shots: suspension thumps and landings, gear-change clicks, handbrake ratchet. Body
##   impacts (CarController.impacted) play a light knock for taps and one of several layered crash
##   recordings (crunch, metal, debris, glass on the heaviest) for real hits.
## - Boost: a nitro loop (turbo whine + hiss + thrust roar) following a spool envelope, a whoosh
##   when it kicks in and a blow-off "pssh" when it ends, plus a warm synthwave drone that swells
##   in with the boost, climbs in pitch while it is held and cuts out on release.
## All players go to a dedicated bus with a hard limiter so nothing clips.

const Synth := preload("res://scripts/vehicle/car_sound_synth.gd")

const BUS_NAME := &"CarAudio"
const ENGINE_RATE := 22050.0
const ENGINE_LATENCY := 0.06     ## Seconds of engine audio kept queued.
const TABLE_SIZE := 2048

const IDLE_RPM := 850.0
const REDLINE_RPM := 7200.0
const UPSHIFT_RPM := 6500.0
const DOWNSHIFT_RPM := 2300.0
const GEAR_TOP_KMH: Array[float] = [40.0, 68.0, 97.0, 128.0, 162.0, 245.0]  ## Tall 6th for boosted top speed.
const REVERSE_TOP_KMH := 40.0
const SHIFT_TIME := 0.16

@export var volume_db := -4.0
@export_range(0.0, 2.0) var engine_volume := 1.0
@export_range(0.0, 2.0) var engine_bass := 0.8   ## Low-shelf boost (below ~170 Hz) on the engine voice.
@export_range(0.0, 2.0) var boost_volume := 1.0
@export_range(0.0, 2.0) var tyre_volume := 1.0
@export_range(0.0, 2.0) var ambience_volume := 1.0
@export_range(0.0, 2.0) var effects_volume := 1.0
@export_range(0.0, 2.0) var crash_volume := 1.0
@export_range(0.0, 1.0) var crash_threshold := 0.3  ## Impacts below this strength are light knocks.
@export_range(0.0, 2.0) var boost_drone_volume := 1.0  ## Synthwave drone while boosting.
@export var boost_drone_fade_in := 0.4   ## Seconds to swell to full level.
@export var boost_drone_fade_out := 0.15 ## Seconds to cut out once the boost is released.
@export var boost_drone_bend := 0.06     ## Pitch rises by this fraction while swelling in.
@export var boost_drone_rise_semitones := 7.0  ## Pitch climbs toward this while the boost is held...
@export var boost_drone_rise_time := 2.0       ## ...with this time constant (s).
@export var boost_drone_release_dip := 0.08    ## Pitch drops by this fraction as it cuts out.

var rpm := IDLE_RPM
var gear := 1                    ## 0 = reverse, 1..6 forward.
var engine_load := 0.0           ## Smoothed 0..1 throttle load as heard.

var _car: CarController
var _bus := &"Master"

# Engine voice
var _engine_player: AudioStreamPlayer
var _gen: AudioStreamGeneratorPlayback
var _gen_capacity := 0
var _buf := PackedVector2Array()
var _table_on := PackedFloat32Array()
var _table_off := PackedFloat32Array()
var _phase := 0.0
var _seed := 12345
var _prev_inc := 0.0
var _prev_load := 0.0
var _prev_gain := 0.0
var _x1 := 0.0
var _x2 := 0.0
var _y1 := 0.0
var _y2 := 0.0
var _dc_x := 0.0
var _dc_y := 0.0
var _bass_lp := 0.0
var _pop_env := 0.0
var _pop_pending := 0.0

# Engine model
var _shift_timer := 0.0
var _shift_cooldown := 0.0
var _shift_blip := false
var _limiter_timer := 0.0
var _pops_left := 0
var _pop_timer := 0.0
var _time := 0.0
var _demand := 0.0             ## Throttle with slow release, so brief lifts do not short-shift.

# Loops: player -> smoothed linear gain
var _squeal: AudioStreamPlayer
var _skid: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _rumble: AudioStreamPlayer
var _gravel: AudioStreamPlayer
var _boost: AudioStreamPlayer
var _gains := {}

# One-shots
var _thump: AudioStreamPlayer
var _impact: AudioStreamPlayer
var _click: AudioStreamPlayer
var _ratchet: AudioStreamPlayer
var _release: AudioStreamPlayer
var _boost_start: AudioStreamPlayer
var _crash: AudioStreamPlayer
var _crash_heavy: AudioStreamPlayer
var _drone: AudioStreamPlayer
var _drone_level := 0.0  ## 0..1 envelope.
var _drone_rise := 0.0   ## 0..1, how far the held-boost pitch climb has gone.
var _blow_off: AudioStreamPlayer

# Event detection (physics rate)
var _last_pos := Vector3.ZERO
var _last_vel := Vector3.ZERO  ## Only used to tell teleports apart from motion.
var _prev_comp := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _bump_cooldown := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _thump_cooldown := 0.0
var _suppress_events := 0.5
var _air_time := 0.0
var _fall_speed := 0.0
var _handbrake_was := false
var _boost_was := false
var _boost_spool := 0.0         ## 0..1, rises while boosting, decays after.


func _ready() -> void:
	_car = get_parent() as CarController
	_bus = _ensure_bus()

	_table_on = Synth.engine_table(TABLE_SIZE, true)
	_table_off = Synth.engine_table(TABLE_SIZE, false)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = ENGINE_RATE
	gen.buffer_length = 0.15
	_engine_player = _make_player(&"Engine", gen, 1)
	_engine_player.play()
	_gen = _engine_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if _gen:
		_gen_capacity = _gen.get_frames_available()

	_squeal = _make_loop(&"TyreSqueal", Synth.tyre_loop(880, 0.18, 1.0))
	_skid = _make_loop(&"TyreSkid", Synth.tyre_loop(540, 0.55, 1.6))
	_wind = _make_loop(&"Wind", Synth.wind_loop())
	_rumble = _make_loop(&"RoadRumble", Synth.rumble_loop())
	_gravel = _make_loop(&"Gravel", Synth.gravel_loop())
	_boost = _make_loop(&"Boost", Synth.boost_loop())

	_thump = _make_player(&"Thump", Synth.thump(), 4)
	_impact = _make_player(&"Impact", Synth.impact(), 3)
	_click = _make_player(&"ShiftClick", Synth.shift_click(), 2)
	_ratchet = _make_player(&"Ratchet", Synth.ratchet(), 1)
	_release = _make_player(&"HandbrakeRelease", Synth.release_click(), 1)
	_boost_start = _make_player(&"BoostWhoosh", Synth.boost_whoosh(), 2)
	_blow_off = _make_player(&"BlowOff", Synth.blow_off(), 2)
	_crash = _make_player(&"Crash", _randomizer([Synth.crash(0, false), Synth.crash(1, false), Synth.crash(2, false)]), 3)
	_crash_heavy = _make_player(&"CrashHeavy", _randomizer([Synth.crash(3, true), Synth.crash(4, true)]), 2)
	_drone = _make_player(&"BoostDrone", Synth.boost_drone(), 1)
	_car.impacted.connect(_on_impacted)


func _randomizer(streams: Array[AudioStreamWAV]) -> AudioStreamRandomizer:
	var r := AudioStreamRandomizer.new()
	r.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS
	r.random_pitch = 1.0
	r.random_volume_offset_db = 0.0
	for st in streams:
		r.add_stream(-1, st)
	return r


func _ensure_bus() -> StringName:
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, BUS_NAME)
		AudioServer.set_bus_send(idx, &"Master")
		var limiter := AudioEffectHardLimiter.new()
		limiter.ceiling_db = -1.0
		AudioServer.add_bus_effect(idx, limiter)
	AudioServer.set_bus_volume_db(idx, volume_db)
	return BUS_NAME


func _make_player(player_name: StringName, stream: AudioStream, polyphony: int) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = player_name
	p.stream = stream
	p.bus = _bus
	p.max_polyphony = polyphony
	add_child(p)
	return p


func _make_loop(player_name: StringName, stream: AudioStreamWAV) -> AudioStreamPlayer:
	var p := _make_player(player_name, stream, 1)
	p.volume_db = -80.0
	_gains[p] = 0.0
	p.play(randf() * stream.get_length())
	return p


func _process(delta: float) -> void:
	if _car == null or _car.input == null or _car.wheels.is_empty():
		return
	_time += delta
	_update_engine_model(delta)
	_update_loops(delta)
	_fill_engine()


# --- Engine model ------------------------------------------------------------------------------

func _gear_rpm(kmh: float, g: int) -> float:
	var top := REVERSE_TOP_KMH if g == 0 else GEAR_TOP_KMH[g - 1]
	return kmh / top * REDLINE_RPM


func _update_engine_model(delta: float) -> void:
	var inp := _car.input
	var spd := _car.speed
	var kmh := absf(spd) * 3.6
	var grounded := _car.grounded_wheels > 0

	# Mirror the controller's pedal logic: "brake" reverses once nearly stopped.
	var drive := 0.0
	var braking := 0.0
	if spd > 1.0:
		drive = inp.throttle
		braking = inp.brake
	elif spd < -1.0:
		drive = inp.brake
		braking = inp.throttle
	else:
		drive = maxf(inp.throttle, inp.brake)
	var reversing := spd < -1.0 or (spd <= 1.0 and inp.brake > inp.throttle + 0.05)

	# Gearbox
	_demand = maxf(drive, move_toward(_demand, drive, 1.2 * delta))
	_shift_cooldown -= delta
	if reversing:
		if gear != 0:
			_shift_to(0, false)
	elif gear == 0:
		_shift_to(1, false)
	elif _shift_cooldown <= 0.0 and grounded:
		var r := _gear_rpm(kmh, gear)
		var up_at := lerpf(4600.0, UPSHIFT_RPM, clampf(_demand * 1.3, 0.0, 1.0))
		var can_up := gear < GEAR_TOP_KMH.size() and braking < 0.1 \
				and _gear_rpm(kmh, gear + 1) > DOWNSHIFT_RPM + 500.0
		var down_at := DOWNSHIFT_RPM
		if braking > 0.3:
			down_at = 3400.0
		elif drive > 0.8 and gear > 1 and _gear_rpm(kmh, gear - 1) < UPSHIFT_RPM - 900.0:
			down_at = 3300.0  # Kick-down under full throttle.
		if can_up and r > up_at:
			_shift_to(gear + 1, false)
		elif gear > 1 and kmh < 12.0:
			_shift_to(1, false)
		elif gear > 1 and r < down_at:
			_shift_to(gear - 1, true)
			if braking > 0.3:
				_shift_cooldown = 0.22

	# Target RPM
	var target: float
	var rate := 12.0
	if not grounded:
		target = lerpf(IDLE_RPM * 1.2, REDLINE_RPM * 0.97, drive)
		rate = 7.0 if target > rpm else 3.0
	else:
		var wheel_rpm := _gear_rpm(kmh, gear)
		if _car.is_drifting:
			wheel_rpm += drive * 1400.0  # Rear wheels spinning up in the slide.
		var clutch := (IDLE_RPM + drive * 2700.0) * clampf(1.0 - kmh / 28.0, 0.0, 1.0)
		target = maxf(wheel_rpm, clutch)
	var heard_load := drive
	if _shift_timer > 0.0:
		_shift_timer -= delta
		if _shift_blip:
			var k := _shift_timer / SHIFT_TIME
			target += 900.0 * k
			heard_load = 0.55 * k
			rate = 18.0
		else:
			heard_load = 0.0
	target = maxf(target, IDLE_RPM) + sin(_time * 7.3) * 14.0 + sin(_time * 2.1) * 18.0
	rpm = lerpf(rpm, target, 1.0 - exp(-rate * delta))

	# Rev limiter: bounce off the redline with a short fuel cut.
	_limiter_timer -= delta
	if rpm > REDLINE_RPM:
		rpm = REDLINE_RPM - 280.0
		_limiter_timer = 0.07
	if _limiter_timer > 0.0:
		heard_load = 0.0

	# Overrun pops when lifting off from high revs.
	var prev_load := engine_load
	engine_load = move_toward(engine_load, heard_load, (14.0 if heard_load > engine_load else 9.0) * delta)
	if prev_load > 0.55 and heard_load < 0.1 and rpm > 4200.0 and _pops_left == 0 and _shift_timer <= 0.0:
		_pops_left = randi_range(2, 5)
		_pop_timer = randf_range(0.04, 0.12)
	if _pops_left > 0:
		_pop_timer -= delta
		if _pop_timer <= 0.0:
			_pop_pending = randf_range(0.35, 0.8) * clampf((rpm - 2500.0) / 3000.0, 0.2, 1.0)
			_pops_left -= 1
			_pop_timer = randf_range(0.05, 0.2)
		if heard_load > 0.3:
			_pops_left = 0


func _shift_to(new_gear: int, blip: bool) -> void:
	var was := gear
	gear = new_gear
	_shift_cooldown = 0.45
	_play(_click, effects_volume * 0.22, randf_range(0.92, 1.08))
	if was == 0 or new_gear == 0:
		return  # Into/out of reverse at standstill: just the click.
	_shift_timer = SHIFT_TIME
	_shift_blip = blip
	if not blip and engine_load > 0.7 and randf() < 0.5:
		_pop_pending = 0.4


# --- Engine voice ------------------------------------------------------------------------------

func _fill_engine() -> void:
	if _gen == null:
		return
	var avail := _gen.get_frames_available()
	var want := int(ENGINE_RATE * ENGINE_LATENCY) - (_gen_capacity - avail)
	want = mini(want, avail)
	if want <= 0:
		return
	_buf.resize(want)

	var rpm_n := clampf((rpm - IDLE_RPM) / (REDLINE_RPM - IDLE_RPM), 0.0, 1.0)
	var inc := rpm / 120.0 / ENGINE_RATE  # One table cycle = two crank turns.
	var ld := engine_load
	var gain := engine_volume * 0.3 * (0.5 + 0.5 * ld) * (0.72 + 0.4 * rpm_n)
	var grit := 0.06 + 0.3 * ld * (0.4 + 0.6 * rpm_n)
	var drive := 1.3 + 1.8 * ld

	# Resonant low-pass (RBJ biquad); brighter with load and revs, but kept warm.
	var cutoff := 320.0 + 1500.0 * ld * (0.5 + 0.5 * rpm_n) + 900.0 * rpm_n
	var w0 := TAU * cutoff / ENGINE_RATE
	var cw := cos(w0)
	var alpha := sin(w0) / (2.0 * 1.25)
	var a0 := 1.0 + alpha
	var b0 := (1.0 - cw) * 0.5 / a0
	var b1 := (1.0 - cw) / a0
	var a1 := -2.0 * cw / a0
	var a2 := (1.0 - alpha) / a0

	if _pop_pending > 0.0:
		_pop_env = maxf(_pop_env, _pop_pending)
		_pop_pending = 0.0

	# Ramp per-buffer parameters across the buffer to avoid zipper noise.
	var inv := 1.0 / want
	var d_inc := (inc - _prev_inc) * inv
	var d_load := (ld - _prev_load) * inv
	var d_gain := (gain - _prev_gain) * inv
	var cur_inc := _prev_inc
	var cur_load := _prev_load
	var cur_gain := _prev_gain

	var t_on := _table_on
	var t_off := _table_off
	var size_f := float(TABLE_SIZE)
	var ph := _phase
	var rng_state := _seed
	var x1 := _x1
	var x2 := _x2
	var y1 := _y1
	var y2 := _y2
	var dc_x := _dc_x
	var dc_y := _dc_y
	var pop := _pop_env
	var bass_lp := _bass_lp
	var bass := engine_bass
	var a_bass := 1.0 - exp(-TAU * 170.0 / ENGINE_RATE)

	for i in want:
		cur_inc += d_inc
		cur_load += d_load
		cur_gain += d_gain
		ph += cur_inc
		if ph >= 1.0:
			ph -= 1.0
		var pos := ph * size_f
		var idx := int(pos)
		var fr := pos - idx
		var on := t_on[idx] + (t_on[idx + 1] - t_on[idx]) * fr
		var off := t_off[idx] + (t_off[idx + 1] - t_off[idx]) * fr
		var s := off + (on - off) * cur_load
		rng_state = (rng_state * 1103515245 + 12345) & 0x7fffffff
		var noise := float(rng_state) * 9.313225746e-10 - 1.0
		s += noise * (grit * absf(on) + pop)
		pop *= 0.9993
		s *= drive
		s = s / (1.0 + absf(s))
		var y := b0 * (s + x2) + b1 * x1 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = s
		y2 = y1
		y1 = y
		# DC blocker
		var hp := y - dc_x + 0.995 * dc_y
		dc_x = y
		dc_y = hp
		# Low shelf: add back a low-passed copy.
		bass_lp += (hp - bass_lp) * a_bass
		var out := (hp + bass_lp * bass) * cur_gain
		_buf[i] = Vector2(out, out)

	_phase = ph
	_seed = rng_state
	_x1 = x1
	_x2 = x2
	_y1 = y1
	_y2 = y2
	_dc_x = dc_x
	_dc_y = dc_y
	_bass_lp = bass_lp
	_pop_env = pop if pop > 0.001 else 0.0
	_prev_inc = inc
	_prev_load = ld
	_prev_gain = gain
	_gen.push_buffer(_buf)


# --- Loops -------------------------------------------------------------------------------------

func _update_loops(delta: float) -> void:
	var inp := _car.input
	var spd := _car.speed
	var abs_speed := absf(spd)
	var vel_len := _car.linear_velocity.length()

	var grounded := 0
	var on_road := 0
	var lat_max := 0.0
	for w: CarController.Wheel in _car.wheels:
		if not w.grounded:
			continue
		grounded += 1
		if w.surface == &"road":
			on_road += 1
		lat_max = maxf(lat_max, absf(w.lateral_slip))
	var road_frac := on_road / 4.0
	var grass_frac := (grounded - on_road) / 4.0

	# Lateral slip: drifting / sliding through corners.
	var slip := clampf((lat_max - 1.2) / 5.5, 0.0, 1.0) * clampf(vel_len / 4.0, 0.0, 1.0)
	# Longitudinal skid: handbrake lock, hard braking, wheelspin on launch.
	var braking := inp.brake if spd > 1.0 else (inp.throttle if spd < -1.0 else 0.0)
	var skid := 0.0
	if inp.handbrake:
		skid = clampf(abs_speed / 14.0, 0.0, 1.0) * 0.85
	skid = maxf(skid, clampf((braking - 0.5) * 2.0, 0.0, 1.0) * clampf((abs_speed - 5.0) / 20.0, 0.0, 1.0) * 0.7)
	if gear == 1 and inp.throttle > 0.8 and abs_speed < 7.0:
		skid = maxf(skid, (1.0 - abs_speed / 7.0) * 0.45 * inp.throttle)

	var wobble := 1.0 + 0.03 * sin(_time * 9.0) + 0.02 * sin(_time * 23.0)
	_drive_loop(_squeal, slip * road_frac * 0.32 * tyre_volume, (0.88 + 0.22 * slip) * wobble, delta, 10.0, 5.0)
	_drive_loop(_skid, skid * road_frac * 0.3 * tyre_volume, (0.85 + clampf(abs_speed / 40.0, 0.0, 0.3)) * wobble, delta, 12.0, 6.0)

	var off_road := clampf(vel_len / 18.0, 0.0, 1.0) * 0.55 + maxf(slip, skid) * 0.5
	_drive_loop(_gravel, grass_frac * off_road * 0.32 * ambience_volume, 0.8 + clampf(vel_len / 40.0, 0.0, 0.5), delta, 6.0, 6.0)

	var speed_n := clampf(vel_len / 55.0, 0.0, 1.0)
	_drive_loop(_wind, speed_n * speed_n * 0.155 * ambience_volume, 0.7 + 0.65 * speed_n, delta, 3.0, 3.0)
	var rumble := road_frac * clampf(vel_len / 30.0, 0.0, 1.0)
	_drive_loop(_rumble, rumble * 0.3 * ambience_volume, 0.65 + clampf(vel_len / 50.0, 0.0, 0.8), delta, 5.0, 5.0)

	# Nitro: spool up fast, wind down a little slower.
	var boosting := _car.is_boosting
	_boost_spool = move_toward(_boost_spool, 1.0 if boosting else 0.0, (2.5 if boosting else 1.6) * delta)
	var spool_gain := _boost_spool * _boost_spool * (0.55 + 0.45 * clampf(vel_len / 50.0, 0.0, 1.0))
	_drive_loop(_boost, spool_gain * 0.34 * boost_volume, 0.7 + 0.45 * _boost_spool + 0.15 * speed_n, delta, 8.0, 4.0)
	if boosting != _boost_was:
		_boost_was = boosting
		if boosting:
			_play(_boost_start, boost_volume * 0.42, randf_range(0.95, 1.05))
		elif _boost_spool > 0.3:
			_play(_blow_off, boost_volume * 0.3 * _boost_spool, randf_range(0.95, 1.1))
	_update_drone(boosting, delta)

	# Handbrake ratchet / release.
	if inp.handbrake != _handbrake_was:
		_handbrake_was = inp.handbrake
		if inp.handbrake:
			_play(_ratchet, effects_volume * 0.3, randf_range(0.95, 1.05))
		else:
			_play(_release, effects_volume * 0.22, randf_range(0.95, 1.05))


func _drive_loop(p: AudioStreamPlayer, target: float, pitch: float, delta: float,
		attack: float, release: float) -> void:
	var g: float = _gains[p]
	var rate := attack if target > g else release
	g = lerpf(g, target, 1.0 - exp(-rate * delta))
	_gains[p] = g
	p.volume_db = linear_to_db(g) if g > 0.0005 else -80.0
	p.pitch_scale = clampf(pitch, 0.25, 4.0)


func _play(p: AudioStreamPlayer, gain: float, pitch: float) -> void:
	if gain <= 0.0005:
		return
	p.volume_db = linear_to_db(gain)
	p.pitch_scale = pitch
	p.play()


# --- Events (thumps, landings, impacts) --------------------------------------------------------

## Synthwave drone: swells in (small upward bend) when the boost starts, keeps climbing in pitch
## while it is held, and cuts out quickly with a short downward dip on release.
func _update_drone(boosting: bool, delta: float) -> void:
	if boosting:
		if not _drone.playing:
			_drone.volume_db = -80.0
			_drone_rise = 0.0
			_drone.play(randf() * _drone.stream.get_length())
		_drone_rise += (1.0 - _drone_rise) * (1.0 - exp(-delta / maxf(boost_drone_rise_time, 0.01)))
	var rate := 1.0 / maxf(boost_drone_fade_in if boosting else boost_drone_fade_out, 0.01)
	_drone_level = move_toward(_drone_level, 1.0 if boosting else 0.0, rate * delta)
	if _drone_level <= 0.0:
		if _drone.playing:
			_drone.stop()
		return
	var pitch := pow(2.0, boost_drone_rise_semitones * _drone_rise / 12.0)
	var gain := _drone_level
	if boosting:
		var shaped := _drone_level * _drone_level * (3.0 - 2.0 * _drone_level)  # Smoothstep swell.
		gain = shaped
		pitch *= 1.0 - boost_drone_bend * (1.0 - shaped)
	else:
		pitch *= 1.0 - boost_drone_release_dip * (1.0 - _drone_level)
	_drone.volume_db = linear_to_db(0.45 * boost_drone_volume * gain)
	_drone.pitch_scale = pitch


## Body impact (CarController.impacted): `strength` 0..1, `heaviness` 0..1 from the mass of what
## was hit (lower, duller crunch). Light taps get a knock, real hits a layered crash.
func _on_impacted(strength: float, heaviness: float) -> void:
	if _suppress_events > 0.0:
		return
	var weight := lerpf(1.0, 0.82, heaviness)
	if strength < crash_threshold:
		_play(_impact, effects_volume * lerpf(0.25, 0.55, strength / crash_threshold),
				randf_range(0.9, 1.1) * lerpf(1.15, 0.95, strength) * weight)
		return
	var k := (strength - crash_threshold) / (1.0 - crash_threshold)
	var p := _crash_heavy if k > 0.75 else _crash
	_play(p, crash_volume * lerpf(0.5, 0.95, k), randf_range(0.93, 1.05) * lerpf(1.08, 0.9, k) * weight)
	# A touch of the old low boom under heavy hits adds weight.
	if k > 0.3:
		_play(_impact, effects_volume * 0.35 * k, randf_range(0.7, 0.8) * weight)


func _physics_process(delta: float) -> void:
	if _car == null or _car.wheels.is_empty():
		return
	var pos := _car.global_position
	var vel := _car.linear_velocity
	_thump_cooldown -= delta
	_suppress_events -= delta

	# Teleports (resets) are not crashes.
	if pos.distance_to(_last_pos) > maxf(6.0, _last_vel.length() * delta * 3.0):
		_suppress_events = 0.4
		_air_time = 0.0
	_last_pos = pos
	_last_vel = vel

	var wheels := _car.wheels
	if _suppress_events > 0.0:
		for i in wheels.size():
			_prev_comp[i] = wheels[i].compression
		return

	# Landings
	if _car.grounded_wheels == 0:
		_air_time += delta
		_fall_speed = maxf(_fall_speed, -vel.y)
	else:
		if _air_time > 0.25 and _thump_cooldown <= 0.0:
			var strength := clampf(_fall_speed / 9.0, 0.25, 1.0)
			_play(_thump, effects_volume * lerpf(0.25, 0.55, strength), randf_range(0.85, 1.0))
			_thump_cooldown = 0.15
		_air_time = 0.0
		_fall_speed = 0.0

	# Bumps: fast suspension compression on any wheel.
	for i in wheels.size():
		var w := wheels[i]
		var c_rate := (w.compression - _prev_comp[i]) / delta
		_prev_comp[i] = w.compression
		_bump_cooldown[i] -= delta
		if w.grounded and c_rate > 2.4 and _bump_cooldown[i] <= 0.0 and _thump_cooldown <= 0.0:
			var strength := clampf((c_rate - 2.4) / 4.0, 0.15, 0.8)
			_play(_thump, effects_volume * 0.3 * strength, randf_range(0.95, 1.2))
			_bump_cooldown[i] = 0.25
			_thump_cooldown = 0.06
