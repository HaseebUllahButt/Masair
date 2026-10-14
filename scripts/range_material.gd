extends RefCounted
## Materials for every painted mountain range in the game: the ring that follows
## the rider, and the authored skyline across the lake at each overlook.
##
## Both are one shader (shaders/horizon.gdshader) fed from one mood, so the
## mountains you ride toward and the mountains you stop to look at are drawn in
## the same hand. The overlooks used to be lit as ordinary Lambert terrain under
## the engine fog: at dusk that put every range in the same warm clay, whatever
## the biome, while the ring on the ride carried a treeline, snow, valley mist and
## its own aerial perspective. Each overlook now takes the ring's material with a
## biome profile over it — how high the woods climb and whether the tops hold
## snow — rather than a palette of its own.

const RANGE_SHADER: Shader = preload("res://shaders/horizon.gdshader")

## `treeline` is in the mesh's own metres (the overlook's are relative to the
## road, a few tens of metres above the lake). `woods` is the daylight colour of
## whatever grows below it. `snow_bias` moves the snowline as a fraction of the
## layer's height; 1.0 keeps a range bare. `light_soft` widens the terminator for
## the overlooks' smooth-normalled faces, and `azimuth_flatten` takes the ring's
## panel-to-panel turn out of its light, and `slope_rock` bares steep ground
## (see the shader for all three).
const RING := {
	## 170 -> 240. The treeline is metres above the ring's own foot (-160), so
	## 170 left only the bottom third of the 900 m back layer wooded — the far
	## range read as bare pale rock to the skyline, which fed the "washed grey"
	## complaint. 240 puts real forest on the foot of every layer: the foothill
	## ring woods almost to its crests, the back range keeps a green skirt under
	## the rock, the way the treeline actually behaves on a tall face. Snow at
	## -0.32: the DEM crests only touch the layer top at their one hero summit,
	## and at -0.10 no cap showed anywhere on the ring.
	"treeline": 240.0, "woods": Color("34573f"), "snow_bias": -0.32, "light_soft": 0.3, "azimuth_flatten": 0.85
}
## Keyed by RoadChunk.Env.
const OVERLOOK := {
	# Forest: wooded to the crest, every ridge a darker green than the one behind.
	1: {"treeline": 320.0, "woods": Color("1f4632"), "snow_bias": 1.0, "light_soft": 0.8},
	# Mountain: pines skirt the lower slopes, bare rock above, snow on the tops.
	# Snow at -0.12 crept halfway down every summit, and half a view of white
	# caps over pale rock is what read as a wall of cream. A 50 m treeline left
	# the whole face bare grey; the green skirt is the colour the vista needs.
	3: {"treeline": 130.0, "woods": Color("27432f"), "snow_bias": -0.02, "light_soft": 0.8, "slope_rock": 1.0},
	# Country: green feet under pale open brows — chalk downland goes bare over
	# the treeline, and a firmer terminator keeps a rolling face from shading as
	# one soft balloon.
	4: {"treeline": 460.0, "woods": Color("5c7436"), "snow_bias": 1.0, "light_soft": 0.5, "slope_rock": 0.4},
}

static var _ring: ShaderMaterial
static var _overlooks: Dictionary = {}
static var _mood: Dictionary = {}


static func ring() -> ShaderMaterial:
	if _ring == null:
		_ring = _make(RING)
	return _ring


static func overlook(theme_id: int) -> ShaderMaterial:
	if not _overlooks.has(theme_id):
		_overlooks[theme_id] = _make(OVERLOOK.get(theme_id, RING))
	return _overlooks[theme_id]


static func apply_mood(mood: Dictionary) -> void:
	_mood = mood
	if _ring:
		_paint(_ring, RING)
	for theme_id in _overlooks:
		_paint(_overlooks[theme_id], OVERLOOK.get(theme_id, RING))


static func _make(profile: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = RANGE_SHADER
	mat.set_shader_parameter("treeline", float(profile["treeline"]))
	mat.set_shader_parameter("snow_bias", float(profile["snow_bias"]))
	mat.set_shader_parameter("light_soft", float(profile.get("light_soft", 0.0)))
	mat.set_shader_parameter("azimuth_flatten", float(profile.get("azimuth_flatten", 0.0)))
	mat.set_shader_parameter("slope_rock", float(profile.get("slope_rock", 0.0)))
	if not _mood.is_empty():
		_paint(mat, profile)
	return mat


static func _paint(mat: ShaderMaterial, profile: Dictionary) -> void:
	var haze: Color = _mood.get("horizon_color", Color("f6b06a"))
	## A dawn sky is only gold on the sun's side; the ranges stand all round
	## the horizon, so they take the air halfway to the cool side. Painted in
	## the gold alone, every shaded face away from the sun came out grey-brown.
	haze = haze.lerp(_mood.get("anti_horizon", haze), 0.5 * float(_mood.get("azimuth_split", 0.0)))
	var fog: Color = _mood.get("fog_color", Color("8b625f"))
	var light_angle: Vector3 = _mood.get("light_angle", Vector3(-7.0, 14.0, 0.0))
	var euler := Vector3(deg_to_rad(light_angle.x), deg_to_rad(light_angle.y), deg_to_rad(light_angle.z))
	## DirectionalLight points down its -Z; N·L wants the vector toward the sun.
	var toward_sun: Vector3 = Basis.from_euler(euler).z
	mat.set_shader_parameter("haze_color", haze)
	## Warm scree at the foot walking to cooler rock at the crest. One rock
	## colour lit by a backlit sun is a card whichever way the facets point.
	## Night fog is already a navy; darkening it again crushed the near range
	## into the same black triangles the Lambert overlooks used to be.
	## Rock sits darker than the air it is seen through. Both colours used to
	## land within a few percent of the haze's own value, so once the aerial
	## term had mixed in, near and far range had the same pale value and the
	## distance read as white-out instead of as depth — sunlit faces blew out
	## to sand-coloured dunes against a pale sky. Darker and bluer at both
	## ends keeps a range a mountain at any hour — but only just: the near
	## ring carries almost no haze, so the foot colour *is* its value, and at
	## the old depth a shaded panel rendered inside the frame's darkest three
	## percent, a navy cut-out against the sky.
	## Real rock, not a tint. The user wants mountains that look like
	## mountains: cool grey granite above dark green-grey scrub, white caps,
	## and only the air between eye and ridge making far ranges paler and
	## bluer. Night walks both toward the fog so the skyline stays moonlit.
	var daylight_r := clampf(fog.get_luminance() * 2.2, 0.15, 1.0)
	## Facing a low sun, a6a49d crest bleached to cream under the warm grade;
	## one step further went navy. Slate crest over green-grey scrub sits
	## between, each a hair darker than the air in front of it.
	mat.set_shader_parameter("foot_color", Color("4a5a48").lerp(fog.darkened(0.2), 0.5 * (1.0 - daylight_r)))
	## The crest is what a tall face is mostly made of, so this is effectively
	## the mid and far ranges' surface colour. Pale enough to light up cream
	## under the grade's warm highlights once, it now sits a shade deeper and
	## bluer — still clearly above the foot, but a slate the sun can put a lit
	## side on without bleaching.
	var crest: Color = Color("6b7683").lerp(fog.darkened(0.1), 0.5 * (1.0 - daylight_r))
	mat.set_shader_parameter("crest_color", crest)
	## What an up-facing plane collects from the dome, and the colour the
	## aerial term veils toward. It used to anchor on 8fa6c8 — a grey so close
	## to the haze's own value that a kilometre of "air" arrived as a grey
	## sheet, which is the washed-pale-range complaint. Airlight is scattered
	## skylight: anchor on the sky's mid band instead, so the veil is blue by
	## day, rose at dusk and navy at night — and a touch darker than the real
	## horizon, because a ridge never reads brighter than the sky behind it.
	var mid: Color = _mood.get("mid_color", Color("8fa6c8"))
	mat.set_shader_parameter("sky_color", haze.lerp(mid, 0.55).darkened(0.06))
	## Snow is only white by daylight. The shader is unshaded, so a constant
	## white would glow on a night skyline; walk it toward the crest colour as
	## the fog darkens.
	var daylight := clampf(fog.get_luminance() * 2.2, 0.15, 1.0)
	mat.set_shader_parameter("snow_color", crest.lerp(Color("f2f5fa"), daylight))
	## Whatever grows below the treeline, as dark as the light allows — and the
	## light allows more than it used to get. The foothill ring is forested
	## over almost its whole face, so this colour is most of what the nearest
	## mountains are made of; at the old depth it and the shaded rock behind
	## it merged into one near-black silhouette.
	var woods: Color = profile["woods"]
	mat.set_shader_parameter("forest_color", fog.darkened(0.15).lerp(woods, 0.85 * daylight))
	mat.set_shader_parameter("mist_color", fog.lerp(haze, 0.25).lerp(Color("9fb4cc"), 0.55 * daylight))
	mat.set_shader_parameter("sun_dir", toward_sun)
	# The lit-face tint follows the key. Under a warm sun it keeps the authored
	# warm cast; once the key goes blue (night's 9ec8de) the same warm cast
	# lands as sand dunes under moonlight, so it cools toward the light's own
	# hue instead. Day and dusk stay on the warm constant — blue in, cool out.
	var key: Color = _mood.get("light_color", Color("ffd59a"))
	var kl := maxf(key.get_luminance(), 0.001)
	var key_norm := Color(key.r / kl, key.g / kl, key.b / kl)
	var cool: Color = key_norm.lerp(Color(0.82, 0.90, 1.06), 0.45)
	var cool_weight := clampf((key.b - key.r) * 3.0, 0.0, 1.0)
	# The old constant (1.03,0.97,0.85) laid a full warm cast on every lit
	# face, and the grade's warm mids returned a neutral-warm rock as tan —
	# the "sand dunes" the reviewer kept rejecting. Daylight granite takes
	# almost no warm cast: a kilometre and a half of air scatters the warm
	# out of the key long before it reaches the ridge, so a lit face at
	# noon is slate, not caramel. The cast is reserved for a genuinely low
	# sun — dusk's ff9e62 is red-deep enough that alpenglow is real, and its
	# (r-b) of 0.62 sits clear of day's 0.40. Night's cool path is unchanged.
	var warm_depth := smoothstep(0.45, 0.60, key.r - key.b)
	var lit_cast := Color(0.93, 0.965, 1.045).lerp(Color(1.03, 0.97, 0.85), warm_depth)
	var key_tint: Color = lit_cast.lerp(cool, cool_weight)
	## Alpenglow. A sunrise lights the tops rose before it lights anything
	## gold; the gold key alone took the ranges through the daytime path and
	## the grade returned them as cream. A rose tint here also keeps the rock's
	## own slate in shade, since the shader only greys rock under a cool key.
	key_tint = key_tint.lerp(_mood.get("range_key_tint", key_tint), float(_mood.get("range_key_mix", 0.0)))
	mat.set_shader_parameter("key_tint", key_tint)
	## Light, because the haze it lays on is the mist colour and the mist is
	## pale: at 0.75 every range in the rain glowed off-white against a slate sky.
	mat.set_shader_parameter("weather_haze", 0.35 * float(_mood.get("rain", 0.0)))
