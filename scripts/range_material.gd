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
	"treeline": 105.0, "woods": Color("2b4a3a"), "snow_bias": 0.0, "light_soft": 0.3, "azimuth_flatten": 0.85
}
## Keyed by RoadChunk.Env.
const OVERLOOK := {
	# Forest: wooded to the crest, every ridge a darker green than the one behind.
	1: {"treeline": 320.0, "woods": Color("1f4632"), "snow_bias": 1.0, "light_soft": 0.8},
	# Coast: turf over the headlands, bare where the sea has cut them.
	2: {"treeline": 150.0, "woods": Color("56703f"), "snow_bias": 1.0, "light_soft": 0.3, "slope_rock": 1.0},
	# Mountain: pines only at the foot, bare rock above, snow on the tops.
	3: {"treeline": 50.0, "woods": Color("27432f"), "snow_bias": -0.12, "light_soft": 0.8, "slope_rock": 1.0},
	# Country: grass fells, rounded and green to the top.
	4: {"treeline": 460.0, "woods": Color("5c7436"), "snow_bias": 1.0, "light_soft": 0.8, "slope_rock": 0.6},
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
	mat.set_shader_parameter("foot_color", fog.darkened(0.16).lerp(Color("3c4a62"), 0.38))
	var crest: Color = fog.lerp(Color("6a7a98"), 0.48).lightened(0.06)
	mat.set_shader_parameter("crest_color", crest)
	## What an up-facing plane collects from the dusk dome. This is the term
	## that keeps the backlit face off zero without smearing sunset over it.
	mat.set_shader_parameter("sky_color", haze.lerp(Color("8fa6c8"), 0.62).lightened(0.04))
	## Snow is only white by daylight. The shader is unshaded, so a constant
	## white would glow on a night skyline; walk it toward the crest colour as
	## the fog darkens.
	var daylight := clampf(fog.get_luminance() * 2.2, 0.15, 1.0)
	mat.set_shader_parameter("snow_color", crest.lerp(Color("f2f5fa"), daylight))
	## Whatever grows below the treeline, as dark as the light allows.
	var woods: Color = profile["woods"]
	mat.set_shader_parameter("forest_color", fog.darkened(0.16).lerp(woods, 0.62 * daylight).darkened(0.1))
	mat.set_shader_parameter("mist_color", fog.lerp(haze, 0.25).lerp(Color("9fb4cc"), 0.45 * daylight))
	mat.set_shader_parameter("sun_dir", toward_sun)
	mat.set_shader_parameter("weather_haze", 0.75 * float(_mood.get("rain", 0.0)))
