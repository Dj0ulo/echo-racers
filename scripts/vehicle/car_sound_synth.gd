extends RefCounted
## Builds all of the car's sound material from code at startup (no audio assets):
## single-cycle engine wavetables for the real-time engine voice, seamless noise/tone loops
## (tyres, wind, road, gravel, nitro) and short one-shots (thumps, impacts, clicks, boost whoosh).
## Everything is mono 16-bit at RATE; the looped material is made seamless by construction
## (integer-Hz tones over whole seconds) or by an equal-power crossfade of the loop ends.

const RATE := 22050

static var _rng := RandomNumberGenerator.new()


# --- Engine wavetables -------------------------------------------------------------------------

## One full 4-stroke cycle (two crank turns) of an inline-4: four firing pulses with slightly
## uneven spacing and strength, which gives the low "burble" sub-harmonics a perfect engine lacks.
## `on_throttle` makes sharper, brighter pulses; off-throttle pulses are rounder and softer.
## A crank-order (half the firing rate) and a weaker half-order component add low-end body.
## The table has `size + 1` entries (last = first) for branch-free linear interpolation.
static func engine_table(size: int, on_throttle: bool) -> PackedFloat32Array:
	var offsets: Array[float] = [0.0, 0.253, 0.497, 0.752]
	var amps: Array[float] = [1.0, 0.82, 0.94, 0.76]
	var table := PackedFloat32Array()
	table.resize(size + 1)
	for i in size:
		var ph := float(i) / size
		var s := 0.0
		for c in 4:
			var u := fposmod(ph - offsets[c], 1.0) * 4.0  # Firing periods since this cylinder fired.
			s += amps[c] * _firing_pulse(u, on_throttle)
		# Sub-octave body: 2 and 1 cycles per table (crank order and half order), phase-locked
		# to the first firing so they reinforce the pulses rather than smear them.
		var body := 0.13 if on_throttle else 0.11
		s += body * sin(TAU * ph * 2.0 + 0.9) + body * 0.4 * sin(TAU * ph + 0.4)
		table[i] = s
	# Circular box blur (3 passes) band-limits the table so high RPM does not alias.
	for _pass in 3:
		table = _circular_blur(table, size, 10)
	_remove_dc(table, size)
	_normalize(table, 1.0 if on_throttle else 0.75)
	table[size] = table[0]
	return table


static func _firing_pulse(u: float, on_throttle: bool) -> float:
	if on_throttle:
		var env := (1.0 - exp(-u / 0.03)) * exp(-u / 0.24)
		var body := sin(TAU * u * 2.0) * 0.8 + sin(TAU * u * 5.0 + 0.6) * 0.3 * exp(-u / 0.12)
		var thump := (1.0 - exp(-u / 0.05)) * exp(-u / 0.7) * sin(TAU * u * 0.5) * 0.45
		return env * body + thump
	var env_off := (1.0 - exp(-u / 0.07)) * exp(-u / 0.38)
	return env_off * (sin(TAU * u * 1.5) * 0.9 + sin(TAU * u * 3.0 + 0.4) * 0.18)


static func _circular_blur(src: PackedFloat32Array, size: int, radius: int) -> PackedFloat32Array:
	var out := src.duplicate()
	var width := radius * 2 + 1
	var acc := 0.0
	for k in range(-radius, radius + 1):
		acc += src[posmod(k, size)]
	for i in size:
		out[i] = acc / width
		acc += src[posmod(i + radius + 1, size)] - src[posmod(i - radius, size)]
	return out


# --- Loops -------------------------------------------------------------------------------------

## Tonal tyre squeal: a wobbling partial stack around `base_hz` plus a little hiss.
## All frequencies are whole Hz over a 1 s loop, so the phase wraps seamlessly.
static func tyre_loop(base_hz: int, noise_amount: float, roughness: float) -> AudioStreamWAV:
	_rng.seed = base_hz
	var n := RATE
	var hiss := _seamless(_band_noise(n + 2000, 900.0, 4000.0), 2000)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var base := float(base_hz)
	for i in n:
		var t := float(i) / RATE
		var f := base * (1.0 + 0.045 * sin(TAU * 3.0 * t) + 0.025 * sin(TAU * 7.0 * t + 1.0)
				+ 0.012 * sin(TAU * 19.0 * t + 2.0) * roughness)
		phase += f / RATE
		var p := TAU * phase
		var am := 0.72 + 0.18 * sin(TAU * 5.0 * t) + 0.1 * sin(TAU * 23.0 * t + 2.0) * roughness
		var tone := sin(p) + 0.32 * sin(2.0 * p + 0.3) + 0.1 * sin(3.0 * p + 1.1) * roughness
		out[i] = am * tone + hiss[i] * noise_amount
	_normalize(out, 0.9)
	return make_wav(out, true)


## Broadband wind: mid-band noise with a slow gust swell (one swell per 2 s loop).
static func wind_loop() -> AudioStreamWAV:
	_rng.seed = 7
	var n := RATE * 2
	var out := _seamless(_band_noise(n + 4000, 180.0, 1100.0), 4000)
	for i in n:
		var t := float(i) / RATE
		out[i] *= 0.8 + 0.2 * sin(TAU * 0.5 * t) + 0.06 * sin(TAU * 3.0 * t)
	_normalize(out, 0.9)
	return make_wav(out, true)


## Low road/tyre rumble.
static func rumble_loop() -> AudioStreamWAV:
	_rng.seed = 11
	var n := int(RATE * 1.5)
	var out := _seamless(_band_noise(n + 3000, 35.0, 190.0), 3000)
	_normalize(out, 0.9)
	return make_wav(out, true)


## Off-road crunch: gritty band noise, a low thrum and sparse gravel crackles.
static func gravel_loop() -> AudioStreamWAV:
	_rng.seed = 13
	var n := int(RATE * 1.5)
	var fade := 3000
	var grit := _band_noise(n + fade, 500.0, 3200.0)
	var low := _band_noise(n + fade, 40.0, 220.0)
	var raw := PackedFloat32Array()
	raw.resize(n + fade)
	var crackle := 0.0
	for i in n + fade:
		if _rng.randf() < 0.0035:
			crackle = _rng.randf_range(0.5, 1.0)
		crackle *= 0.985
		raw[i] = grit[i] * 0.45 + low[i] * 0.8 + _rng.randf_range(-1.0, 1.0) * crackle * 0.5
	var out := _seamless(raw, fade)
	_normalize(out, 0.9)
	return make_wav(out, true)


## Nitro: a rising turbo whine (integer-Hz partials, seamless over 1 s), airy hiss and a low
## thrust roar. Pitch/volume are driven by the boost spool at runtime.
static func boost_loop() -> AudioStreamWAV:
	_rng.seed = 37
	var n := RATE
	var hiss := _seamless(_band_noise(n + 2000, 700.0, 5000.0), 2000)
	var roar := _seamless(_band_noise(n + 2000, 45.0, 260.0), 2000)
	_normalize(hiss, 1.0)
	_normalize(roar, 1.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var whine := sin(TAU * 1460.0 * t) * 0.5 + sin(TAU * 2920.0 * t + 0.7) * 0.16 \
				+ sin(TAU * 1467.0 * t + 1.3) * 0.25  # Slight detune beats like a spinning turbine.
		var flutter := 0.85 + 0.15 * sin(TAU * 11.0 * t)
		out[i] = whine * 0.35 * flutter + hiss[i] * 0.45 + roar[i] * 0.75
	_normalize(out, 0.9)
	return make_wav(out, true)


## Boost kick-in: a swelling, rising noise sweep with a short low punch.
static func boost_whoosh() -> AudioStreamWAV:
	_rng.seed = 41
	var n := int(RATE * 0.9)
	var out := PackedFloat32Array()
	out.resize(n)
	var hi := 0.0
	var lo := 0.0
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var k := t / 0.9
		var cutoff := lerpf(300.0, 4200.0, sqrt(k))
		hi += (_rng.randf_range(-1.0, 1.0) - hi) * (1.0 - exp(-TAU * cutoff / RATE))
		lo += (hi - lo) * (1.0 - exp(-TAU * cutoff * 0.25 / RATE))
		var env := minf(t / 0.12, 1.0) * exp(-maxf(t - 0.12, 0.0) / 0.28)
		phase += lerpf(70.0, 40.0, minf(t / 0.25, 1.0)) / RATE
		var punch := sin(TAU * phase) * exp(-t / 0.12) * minf(t / 0.01, 1.0)
		out[i] = (hi - lo) * env + punch * 0.5
	_normalize(out, 0.9)
	return make_wav(out, false)


## Boost end: a short "pssh" blow-off, bright hiss with a falling band.
static func blow_off() -> AudioStreamWAV:
	_rng.seed = 43
	var n := int(RATE * 0.5)
	var out := PackedFloat32Array()
	out.resize(n)
	var hi := 0.0
	var lo := 0.0
	for i in n:
		var t := float(i) / RATE
		var cutoff := lerpf(6000.0, 1800.0, minf(t / 0.4, 1.0))
		hi += (_rng.randf_range(-1.0, 1.0) - hi) * (1.0 - exp(-TAU * cutoff / RATE))
		lo += (hi - lo) * (1.0 - exp(-TAU * 900.0 / RATE))
		var env := minf(t / 0.008, 1.0) * exp(-t / 0.13)
		out[i] = (hi - lo) * env
	_normalize(out, 0.85)
	return make_wav(out, false)


# --- One-shots ---------------------------------------------------------------------------------

## Suspension thump: a falling low sine with a short soft knock on top.
static func thump() -> AudioStreamWAV:
	_rng.seed = 17
	var n := int(RATE * 0.35)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		phase += lerpf(95.0, 42.0, minf(t / 0.2, 1.0)) / RATE
		var attack := minf(t / 0.003, 1.0)
		lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.25
		out[i] = attack * (sin(TAU * phase) * exp(-t / 0.08) + lp * 0.9 * exp(-t / 0.012))
	_normalize(out, 0.95)
	return make_wav(out, false)


## Body impact: low boom, crunchy noise and a few inharmonic metal partials.
static func impact() -> AudioStreamWAV:
	_rng.seed = 19
	var n := int(RATE * 0.7)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var lp := 0.0
	var partials: Array[float] = [337.0, 781.0, 1213.0, 1871.0]
	for i in n:
		var t := float(i) / RATE
		phase += lerpf(80.0, 36.0, minf(t / 0.3, 1.0)) / RATE
		lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.35
		var attack := minf(t / 0.002, 1.0)
		var s := sin(TAU * phase) * exp(-t / 0.14) + lp * 1.2 * exp(-t / 0.06)
		var ring := 0.0
		for k in partials.size():
			ring += sin(TAU * partials[k] * t + k) * exp(-t / (0.16 - 0.025 * k))
		out[i] = attack * (s + ring * 0.12)
	_normalize(out, 0.95)
	return make_wav(out, false)


## Gear change: a double mechanical "tick-clunk".
static func shift_click() -> AudioStreamWAV:
	_rng.seed = 23
	var n := int(RATE * 0.09)
	var out := PackedFloat32Array()
	out.resize(n)
	_add_click(out, 0.0, 1700.0, 0.004, 0.7)
	_add_click(out, 0.032, 900.0, 0.007, 1.0)
	_normalize(out, 0.9)
	return make_wav(out, false)


## Handbrake pull: a quick ratchet run with rising pitch.
static func ratchet() -> AudioStreamWAV:
	_rng.seed = 29
	var n := int(RATE * 0.2)
	var out := PackedFloat32Array()
	out.resize(n)
	for k in 6:
		_add_click(out, 0.006 + k * 0.026, 2100.0 + k * 180.0, 0.0025, 0.55 + k * 0.06)
	_normalize(out, 0.9)
	return make_wav(out, false)


## Handbrake release: a single soft clunk.
static func release_click() -> AudioStreamWAV:
	_rng.seed = 31
	var out := PackedFloat32Array()
	out.resize(int(RATE * 0.06))
	_add_click(out, 0.0, 650.0, 0.008, 1.0)
	_normalize(out, 0.8)
	return make_wav(out, false)


static func _add_click(buf: PackedFloat32Array, at: float, tone_hz: float, decay: float, amp: float) -> void:
	var start := int(at * RATE)
	var lp := 0.0
	for i in range(start, buf.size()):
		var t := float(i - start) / RATE
		var env := exp(-t / decay)
		if env < 0.001:
			break
		lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.5
		buf[i] += amp * env * (sin(TAU * tone_hz * t) * 0.7 + lp * 0.6)


# --- Helpers -----------------------------------------------------------------------------------

static func make_wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = samples.size()
	return wav


## White noise through a one-pole low-pass at `hi_hz` minus a one-pole low-pass at `lo_hz`.
static func _band_noise(n: int, lo_hz: float, hi_hz: float) -> PackedFloat32Array:
	var a_hi := 1.0 - exp(-TAU * hi_hz / RATE)
	var a_lo := 1.0 - exp(-TAU * lo_hz / RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var hi := 0.0
	var lo := 0.0
	for i in n:
		hi += (_rng.randf_range(-1.0, 1.0) - hi) * a_hi
		lo += (hi - lo) * a_lo
		out[i] = hi - lo
	return out


## Folds the last `fade` samples over the start with an equal-power crossfade, so the result
## (length raw.size() - fade) loops without a click.
static func _seamless(raw: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	var n := raw.size() - fade
	var out := raw.slice(0, n)
	for i in fade:
		var a := float(i) / fade
		out[i] = raw[i] * sqrt(a) + raw[n + i] * sqrt(1.0 - a)
	return out


static func _remove_dc(buf: PackedFloat32Array, n: int) -> void:
	var mean := 0.0
	for i in n:
		mean += buf[i]
	mean /= n
	for i in n:
		buf[i] -= mean


static func _normalize(buf: PackedFloat32Array, peak: float) -> void:
	var m := 0.0
	for v in buf:
		m = maxf(m, absf(v))
	if m <= 0.0:
		return
	var k := peak / m
	for i in buf.size():
		buf[i] *= k
