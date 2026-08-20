extends RefCounted
## Runtime-generated sound. Every voice in the game is synthesised here at boot;
## there is no asset pipeline, and a wave file would be larger than the code that
## makes it.
##
## The looped voices are built with a crossfaded tail (see `_seamless`) rather
## than by trimming at a zero crossing. Noise has no zero crossings worth aiming
## at, and a raw loop of noise clicks once a second forever — which, at speed, is
## the one artefact you cannot stop hearing.

const RATE := 22050

static var _horn_cache := {}
static var _engine_cache := {}
static var _wind_cache: AudioStreamWAV
static var _tyre_cache: AudioStreamWAV
static var _rain_cache: AudioStreamWAV
static var _impact_cache: AudioStreamWAV
static var _whoosh_cache: AudioStreamWAV
static var _drone_cache := {}


static func _wav(data: PackedByteArray, loop: bool, mix_rate: int = RATE) -> AudioStreamWAV:
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = mix_rate
	s.stereo = false
	s.data = data
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = data.size() / 2
	return s


static func _push(data: PackedByteArray, sample: float) -> void:
	var v: int = int(clampf(sample, -1.0, 1.0) * 32000.0)
	data.append(v & 0xFF)
	data.append((v >> 8) & 0xFF)


static func _bake(samples: PackedFloat32Array, loop: bool, peak: float) -> AudioStreamWAV:
	## Normalise to a known peak, then quantise. Synthesised layers land wherever
	## their maths lands, and mixing raw against the hand-tuned horn and engine
	## would mean tuning every volume_db twice.
	var loudest := 0.0
	for s in samples:
		loudest = maxf(loudest, absf(s))
	var gain: float = peak / maxf(loudest, 1e-5)
	var data := PackedByteArray()
	for s in samples:
		_push(data, s * gain)
	return _wav(data, loop, RATE)


static func _seamless(raw: PackedFloat32Array, length: int, tail: int) -> PackedFloat32Array:
	## `raw` is `length + tail` samples long. Fade its overrun back over its own
	## start, so the end of the loop already contains the beginning and the joint
	## is inaudible. Costs one extra tail's worth of generation and nothing at
	## runtime.
	var out := PackedFloat32Array()
	out.resize(length)
	for i in length:
		if i < tail:
			var k: float = float(i) / float(tail)
			out[i] = raw[i] * k + raw[length + i] * (1.0 - k)
		else:
			out[i] = raw[i]
	return out


static func _noise(count: int, low: float, high: float, seed_value: int) -> PackedFloat32Array:
	## White noise through a one-pole lowpass and then a one-pole highpass, which
	## between them place the band. `low` near 1 is bright hiss, near 0 is a dark
	## rumble; `high` lifts the bottom out so nothing eats headroom below hearing.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := PackedFloat32Array()
	out.resize(count)
	var lp := 0.0
	var hp := 0.0
	for i in count:
		lp += (rng.randf_range(-1.0, 1.0) - lp) * low
		hp += (lp - hp) * high
		out[i] = lp - hp
	return out


static func wind() -> AudioStreamWAV:
	if _wind_cache:
		return _wind_cache
	## Air over a helmet: a broad mid band with a slow swell in it. The swell has
	## to complete a whole number of cycles across the loop or it beats against
	## the loop point and turns into a siren.
	var n: int = RATE * 2
	var tail: int = int(RATE * 0.25)
	var body := _noise(n + tail, 0.42, 0.020, 5501)
	var body2 := _noise(n + tail, 0.14, 0.010, 9907)
	var raw := PackedFloat32Array()
	raw.resize(n + tail)
	for i in n + tail:
		var phase: float = float(i) / float(n) * TAU
		var swell: float = 1.0 + 0.30 * sin(phase * 2.0) + 0.16 * sin(phase * 5.0 + 1.1)
		raw[i] = (body[i] + body2[i] * 0.65) * swell
	_wind_cache = _bake(_seamless(raw, n, tail), true, 0.85)
	return _wind_cache


static func tyre() -> AudioStreamWAV:
	if _tyre_cache:
		return _tyre_cache
	## Tread on tarmac. Much darker than the wind so the two stack instead of
	## masking each other, and the pair is what makes speed audible: rumble
	## carries the low end at 60, wind takes over by 160.
	var n: int = int(RATE * 1.5)
	var tail: int = int(RATE * 0.2)
	var body := _noise(n + tail, 0.09, 0.006, 3313)
	var grit := _noise(n + tail, 0.55, 0.05, 7717)
	var raw := PackedFloat32Array()
	raw.resize(n + tail)
	for i in n + tail:
		raw[i] = body[i] * 1.6 + grit[i] * 0.09
	_tyre_cache = _bake(_seamless(raw, n, tail), true, 0.8)
	return _tyre_cache


static func rain() -> AudioStreamWAV:
	if _rain_cache:
		return _rain_cache
	## Bright hiss with a spatter on top. The spatter is the hiss gated by a
	## third noise layer — rain is not a steady sound, it arrives in gusts, and a
	## flat hiss reads as tape noise rather than weather.
	var n: int = RATE * 2
	var tail: int = int(RATE * 0.25)
	var hiss := _noise(n + tail, 0.72, 0.06, 2029)
	var spatter := _noise(n + tail, 0.95, 0.30, 4441)
	var gate := _noise(n + tail, 0.004, 0.0005, 6151)
	var raw := PackedFloat32Array()
	raw.resize(n + tail)
	for i in n + tail:
		var g: float = clampf(0.55 + gate[i] * 9.0, 0.0, 1.6)
		raw[i] = hiss[i] * (0.7 + g * 0.5) + spatter[i] * g * 0.5
	_rain_cache = _bake(_seamless(raw, n, tail), true, 0.85)
	return _rain_cache


static func drone(heavy: bool) -> AudioStreamWAV:
	## Traffic engine, heard from outside. Deliberately plainer than the player's
	## twin: this one gets pitched by doppler as it goes past, and a lumpy source
	## makes the pitch shift read as a wobble instead of as a car.
	if _drone_cache.has(heavy):
		return _drone_cache[heavy]
	var base: float = 42.0 if heavy else 78.0
	var cycles: int = 12 if heavy else 18
	# An integer number of periods, so the waveform itself needs no crossfade.
	var n: int = int(round(float(RATE) * float(cycles) / base))
	var hiss := _noise(n, 0.30, 0.02, 1201 if heavy else 1301)
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in n:
		var ph: float = float(i) / float(n) * float(cycles)
		var f: float = fposmod(ph, 1.0)
		var s: float = (f * 2.0 - 1.0) * 0.5
		s += sin(f * TAU) * 0.35
		s += sin(f * TAU * 2.0) * 0.18
		s += sin(f * TAU * 4.0) * (0.16 if heavy else 0.07)
		s += hiss[i] * (0.22 if heavy else 0.15)
		samples[i] = s
	var stream := _bake(samples, true, 0.75)
	_drone_cache[heavy] = stream
	return stream


static func impact() -> AudioStreamWAV:
	if _impact_cache:
		return _impact_cache
	## The crash. A body blow that decays fast, then bent metal ringing on
	## underneath it — the ring is what stops it sounding like a door slam and
	## starts it sounding like the run ending.
	var duration := 1.4
	var n: int = int(RATE * duration)
	var crack := _noise(n, 0.65, 0.04, 8123)
	var body := _noise(n, 0.12, 0.008, 8231)
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in n:
		var t: float = float(i) / float(RATE)
		var hit: float = exp(-t * 26.0)
		var thud: float = exp(-t * 9.0)
		var ring: float = exp(-t * 3.4)
		var s: float = crack[i] * hit * 0.9 + body[i] * thud * 1.5
		# Falling low sweep: the mass of the thing going down.
		s += sin(TAU * (150.0 - 96.0 * minf(t, 1.0)) * t) * thud * 0.5
		# Three detuned partials, deliberately inharmonic, for bent metal.
		s += sin(TAU * 611.0 * t) * ring * 0.10
		s += sin(TAU * 923.0 * t) * ring * 0.07
		s += sin(TAU * 1487.0 * t) * ring * 0.05
		samples[i] = s
	_impact_cache = _bake(samples, false, 0.95)
	return _impact_cache


static func whoosh() -> AudioStreamWAV:
	if _whoosh_cache:
		return _whoosh_cache
	## The punch of air off something you just passed too close to. Short, and
	## the band sweeps down across it so it reads as going past rather than as a
	## noise burst on the spot.
	var duration := 0.5
	var n: int = int(RATE * duration)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5077
	var samples := PackedFloat32Array()
	samples.resize(n)
	var lp := 0.0
	var hp := 0.0
	for i in n:
		var t: float = float(i) / float(n)
		# Band sweeps from bright to dark over the pass.
		var low: float = 0.70 - 0.55 * t
		lp += (rng.randf_range(-1.0, 1.0) - lp) * low
		hp += (lp - hp) * 0.10
		samples[i] = (lp - hp) * sin(PI * t) * (0.4 + 0.6 * t)
	_whoosh_cache = _bake(samples, false, 0.9)
	return _whoosh_cache


static func horn(kind: int = 0) -> AudioStreamWAV:
	## Dual-tone electromagnetic horn, looping so the rider can hold H.
	## A pair of sines is a phone beep; a pair of driven reeds with a mechanical
	## wobble is the thing on the bars. Each café has its own pitch and bite.
	kind = clampi(kind, 0, HORN_SPECS.size() - 1)
	if _horn_cache.has(kind):
		return _horn_cache[kind]
	var spec: Dictionary = HORN_SPECS[kind]
	const HORN_RATE := 44100
	var f1: float = float(spec["f1"])
	var f2: float = float(spec["f2"])
	var grit: float = float(spec["grit"])
	var buzz: float = float(spec["buzz"])
	var drive: float = float(spec["drive"])
	var n: int = int(HORN_RATE * 0.4)
	var tail: int = int(HORN_RATE * 0.05)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4400 + kind * 17
	var raw := PackedFloat32Array()
	raw.resize(n + tail)
	for i in n + tail:
		var t: float = float(i) / float(HORN_RATE)
		var s := _reed(t, f1, 1.0) + _reed(t, f2, 0.92)
		# Diaphragm wobble — the disc is oscillating, not a synth hold.
		s *= 0.86 + buzz * sin(t * 29.0 * TAU + float(kind))
		s *= 0.94 + 0.06 * sin(t * 7.4 * TAU)
		s += rng.randf_range(-grit, grit)
		raw[i] = tanh(s * drive)
	var looped := _seamless(raw, n, tail)
	var data := PackedByteArray()
	var peak := 0.0
	for s in looped:
		peak = maxf(peak, absf(s))
	var gain: float = 0.92 / maxf(peak, 1e-5)
	for s in looped:
		_push(data, s * gain)
	var stream := _wav(data, true, HORN_RATE)
	_horn_cache[kind] = stream
	return stream


static func _reed(t: float, freq: float, amp: float) -> float:
	## Odd-heavy partials, the shape of a stamped disc, plus a little even
	## content from the horn cup. Not a square wave — those alias badly and
	## read as a toy.
	var w: float = t * freq * TAU
	var s: float = sin(w)
	s += sin(w * 3.0) * 0.36
	s += sin(w * 5.0) * 0.18
	s += sin(w * 7.0) * 0.09
	s += sin(w * 9.0) * 0.04
	s += sin(w * 2.0) * 0.07
	return s * amp


## f1/f2 in Hz. Mesa is the small high one; Raven is the deep baritone.
const HORN_SPECS := [
	{"f1": 496.0, "f2": 592.0, "grit": 0.035, "buzz": 0.16, "drive": 1.28},
	{"f1": 418.0, "f2": 504.0, "grit": 0.045, "buzz": 0.20, "drive": 1.48},
	{"f1": 368.0, "f2": 454.0, "grit": 0.040, "buzz": 0.18, "drive": 1.40},
	{"f1": 388.0, "f2": 476.0, "grit": 0.070, "buzz": 0.24, "drive": 1.70},
	{"f1": 322.0, "f2": 398.0, "grit": 0.090, "buzz": 0.28, "drive": 1.82},
]


static func engine(kind: int = 0) -> AudioStreamWAV:
	## One seamless crank-loop per café. Pitched at runtime to fake a gearbox.
	## Architecture is the whole point: a 360° British twin is not a 270° big
	## twin is not a loping Vee, and sharing one lumpy sample made every bike
	## in the garage sound like the Mesa.
	kind = clampi(kind, 0, ENGINE_SPECS.size() - 1)
	if _engine_cache.has(kind):
		return _engine_cache[kind]
	var spec: Dictionary = ENGINE_SPECS[kind]
	var base: float = float(spec["base"])
	var cycles: int = int(spec["cycles"])
	var n: int = int(round(float(RATE) * float(cycles) / base))
	var tail: int = mini(n, int(RATE * 0.04))
	var hiss := _noise(n + tail, 0.28, 0.018, int(spec["seed"]))
	var clatter := _noise(n + tail, 0.62, 0.08, int(spec["seed"]) + 91)
	var offset: float = float(spec["offset"])
	var mix: float = float(spec["mix"])
	var width: float = float(spec["width"])
	var odd: float = float(spec["odd"])
	var even: float = float(spec["even"])
	var thump: float = float(spec["thump"])
	var hiss_amt: float = float(spec["hiss"])
	var clatter_amt: float = float(spec["clatter"])
	var lope: float = float(spec["lope"])
	var raw := PackedFloat32Array()
	raw.resize(n + tail)
	for i in n + tail:
		var ph: float = float(i) / float(n) * float(cycles)
		var f: float = fposmod(ph, 1.0)
		var fire_a := _combust(f, width)
		var fire_b := _combust(f + offset, width) * mix
		var pulse: float = fire_a + fire_b
		var s: float = pulse * thump * 0.52
		s += (f * 2.0 - 1.0) * 0.10
		s += sin(f * TAU) * odd
		s += sin(f * TAU * 2.0) * even
		s += sin(f * TAU * 3.0) * odd * 0.38
		s += sin(f * TAU * 4.0) * even * 0.45
		s += sin(f * TAU * 6.0) * even * 0.16
		s += sin(ph * PI) * lope
		s += hiss[i] * hiss_amt * (0.35 + pulse * 0.8)
		s += clatter[i] * clatter_amt * pulse
		raw[i] = tanh(s * 1.15)
	var stream := _bake(_seamless(raw, n, tail), true, 0.78)
	_engine_cache[kind] = stream
	return stream


static func _combust(phase: float, width: float) -> float:
	## Pressure rise and exponential dump — one firing of one pot.
	var f: float = fposmod(phase, 1.0)
	return exp(-f / maxf(width, 0.01))


## base Hz of the loop, offset = second-cylinder firing as a fraction of a turn.
## Mesa even-ish twin, Sabre 180°, Halcyon 360° British, Tempest 270°, Raven Vee.
const ENGINE_SPECS := [
	{"base": 76.0, "cycles": 12, "offset": 0.48, "mix": 0.70, "odd": 0.24, "even": 0.10, "width": 0.10, "hiss": 0.11, "clatter": 0.07, "thump": 0.58, "lope": 0.00, "seed": 11},
	{"base": 62.0, "cycles": 10, "offset": 0.50, "mix": 0.88, "odd": 0.16, "even": 0.13, "width": 0.12, "hiss": 0.08, "clatter": 0.05, "thump": 0.66, "lope": 0.00, "seed": 23},
	{"base": 54.0, "cycles": 9, "offset": 0.04, "mix": 0.94, "odd": 0.13, "even": 0.20, "width": 0.14, "hiss": 0.07, "clatter": 0.09, "thump": 0.84, "lope": 0.04, "seed": 37},
	{"base": 47.0, "cycles": 8, "offset": 0.27, "mix": 0.86, "odd": 0.12, "even": 0.22, "width": 0.16, "hiss": 0.09, "clatter": 0.08, "thump": 0.98, "lope": 0.06, "seed": 53},
	{"base": 39.0, "cycles": 8, "offset": 0.17, "mix": 0.76, "odd": 0.10, "even": 0.30, "width": 0.18, "hiss": 0.12, "clatter": 0.11, "thump": 1.18, "lope": 0.16, "seed": 71},
]
