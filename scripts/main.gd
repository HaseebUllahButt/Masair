extends Node3D
## Boots the ride and owns the look.
##
## Every visual mood — sky, sun, fog, exposure, grading, cloud weather — is one
## row of MOODS. Switching mood only pushes numbers into a shader and an
## Environment, so T is instant and never rebuilds the streamed world.
##
## Deliberately no SSAO, no volumetric fog, no screen-space anything: this is a
## flat-shaded low-poly game and the mood comes from colour, a gradient sky and a
## little bloom. Effects that simulate rather than stylise made it look like an
## engine demo and cost most of the frame.

const SKY_SHADER: Shader = preload("res://shaders/sky.gdshader")
const GRADE_SHADER: Shader = preload("res://shaders/grade.gdshader")
const LowPoly := preload("res://scripts/low_poly.gd")
const RideAudioGD := preload("res://scripts/ride_audio.gd")

## Mood keys pushed straight through to the sky shader under the same name.
const SKY_UNIFORMS := [
	"zenith_color",
	"mid_color",
	"horizon_color",
	"ground_color",
	"band_low",
	"band_high",
	"horizon_glow",
	"energy",
	"sun_color",
	"sun_radius",
	"sun_halo",
	"sun_halo_falloff",
	"sun_disc",
	"moon_face",
	"cloud_lit",
	"cloud_dark",
	"cloud_cover",
	"cloud_sharpness",
	"cloud_scale",
	"cloud_speed",
	"cloud_opacity",
	"bank_cover",
	"bank_opacity",
	"bank_height",
	"bank_haze",
	"star_intensity",
	"galaxy_color",
]

@onready var road_streamer: Node3D = $RoadStreamer
@onready var traffic_manager: Node3D = $TrafficManager
@onready var player: Node3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var camera: Camera3D = $Player/CameraPivot/Camera3D

enum LightingMode { DUSK, DAY, NIGHT }

## One row per mood. Keys map 1:1 onto sky shader uniforms, Environment
## properties and the sun, so adding a mood is data rather than branches.
##
## The rule the numbers follow: fog carries the mood into the distance, but
## nearby scenery must keep its own colour. Dense fog plus strong sky ambient is
## what used to turn every environment into the same flat mauve.
const MOODS := {
	LightingMode.DUSK:
	{
		"zenith_color": Color("12183c"),
		"mid_color": Color("c45e78"),
		"horizon_color": Color("f6b06a"),
		"ground_color": Color("111a20"),
		"band_low": 0.08,
		"band_high": 0.50,
		"horizon_glow": 0.34,
		"energy": 1.0,
		"sun_color": Color(1.0, 0.55, 0.28),
		"sun_radius": 0.026,
		"sun_halo": 0.38,
		"sun_halo_falloff": 11.0,
		"sun_disc": 1.0,
		"moon_face": 0.0,
		"cloud_lit": Color("f4b07d"),
		"cloud_dark": Color("413b58"),
		"cloud_cover": 0.34,
		"cloud_sharpness": 0.36,
		"cloud_scale": 1.35,
		"cloud_speed": 0.004,
		"cloud_opacity": 0.72,
		"bank_cover": 0.50,
		"bank_opacity": 0.70,
		"bank_height": 0.13,
		"bank_haze": 0.62,
		"star_intensity": 0.0,
		"galaxy_color": Color("6b74b8"),
		"light_color": Color("ff9e62"),
		"light_energy": 1.42,
		"light_angle": Vector3(-7.0, 14.0, 0.0),
		"angular_distance": 0.8,
		# The warning at the top of this table is about exactly this row. A violet
		# fill at 0.28 against a 0.62 sun is nearly a third of the light arriving
		# as one hue from everywhere, and it took the grass, the trees and the
		# hills all the way to mauve — the sunset stopped being something the
		# landscape was lit by and became the only colour in it. Weaker fill,
		# stronger warm key: the drama is in the sky, and the ground should be
		# lit by it rather than painted with it.
		# Both of these are a colour times an energy, and both colours are dark, so
		# the product was doing almost nothing once the albedos stopped being a
		# gamma too bright. At dusk the sun is three degrees up and dead ahead and
		# puts nothing on a horizontal road at all — ambient and fill *are* the
		# light on the tarmac, and at the old numbers it came out at 0.02.
		# Rebalanced when the terrain stopped using wrapped diffuse. Wrap was
		# quietly donating half the key light to every surface facing away from the
		# sun; taking it out is what finally gave hillsides a shaded side, and it
		# also removed that donation from the exposure budget, so the shaded side
		# landed on the floor. This is the same total light arriving in a form that
		# models rather than flattens: cool fill and ambient, warm key, and the
		# split between the two is the entire look at dusk.
		"fill_color": Color("5b7ea0"),
		"fill_energy": 0.52,
		"ambient": 0.70,
		"ambient_color": Color("40556f"),
		"ambient_sky_mix": 0.30,
		"exposure": 0.96,
		"white": 1.62,
		"fog_color": Color("8b625f"),
		"fog_energy": 0.90,
		"fog_density": 0.0010,
		# The dusk sun sits three degrees above the horizon, dead ahead. Strong
		# sun scatter plus a ground fog layer therefore lit the tarmac itself
		# into a bright wedge that followed the camera down the road — a haze
		# sitting on the surface the player is trying to read. Scatter now only
		# warms the far distance, and the ground layer is gone entirely.
		"fog_sun_scatter": 0.14,
		"fog_aerial": 0.13,
		"fog_sky": 0.07,
		"fog_height": 3.0,
		"fog_height_density": 0.0,
		"glow": 0.52,
		"glow_bloom": 0.08,
		"contrast": 1.30,
		"saturation": 1.12,
	},
	LightingMode.DAY:
	{
		# Warm at the skyline, deep overhead. A blue that runs cyan all the way
		# down to the horizon is the daylight sky of a phone game: the air near
		# the ground carries the most dust and the longest path, so it goes pale
		# and warm, and that warm band is what makes the distance look like air
		# instead of paint. It also feeds the sky ambient, so it warms the light
		# on every shaded face in the world at the same time.
		"zenith_color": Color("1a5688"),
		"mid_color": Color("6aa3c4"),
		"horizon_color": Color("e6d0a8"),
		"ground_color": Color("505e57"),
		"band_low": 0.10,
		"band_high": 0.78,
		"horizon_glow": 0.20,
		"energy": 1.0,
		"sun_color": Color(1.70, 1.58, 1.30),
		"sun_radius": 0.019,
		"sun_halo": 0.30,
		"sun_halo_falloff": 18.0,
		"sun_disc": 1.0,
		"moon_face": 0.0,
		"cloud_lit": Color("f1ddbd"),
		"cloud_dark": Color("718897"),
		"cloud_cover": 0.46,
		"cloud_sharpness": 0.44,
		"cloud_scale": 1.18,
		"cloud_speed": 0.006,
		"cloud_opacity": 0.90,
		"bank_cover": 0.62,
		"bank_opacity": 0.90,
		"bank_height": 0.16,
		"bank_haze": 0.36,
		"star_intensity": 0.0,
		"galaxy_color": Color("6b74b8"),
		"light_color": Color("ffd59a"),
		"light_energy": 1.72,
		# Lower than midday. A sun near the zenith lights the tops of everything
		# and leaves the sides equal, which is the worst case for a world with no
		# shadows: raking it gives every box, tree and hillside a lit side and a
		# dark side without costing a single shadow map.
		"light_angle": Vector3(-22.0, -41.0, 0.0),
		"angular_distance": 0.35,
		# Ambient and fill together used to put 0.56 of flat pale blue on every
		# surface in the world against a 1.28 sun — nearly a third of the light,
		# arriving from everywhere at once. With no shadows in this game (the
		# directional map dots visibly on the tarmac) that flat component is the
		# only thing deciding how dark a shaded face gets, and at that strength
		# nothing was dark at all: greens went mint, tarmac went pale, and the
		# distance dissolved. Halved, with the difference given back to the sun,
		# so form comes from the light having a direction.
		# Raised from 0.08 / 0.20 when the terrain dropped wrapped diffuse. The note
		# above is still the rule — flat light is what took the greens to mint — but
		# those numbers were set against a material that was adding half a key's
		# worth of its own fill on top of them. Without it, nothing held a
		# north-facing slope off the floor.
		"fill_color": Color("7395ae"),
		"fill_energy": 0.18,
		"ambient": 0.32,
		"ambient_color": Color("6f8796"),
		"ambient_sky_mix": 0.52,
		# ACES with the white point down at 1.45 compresses everything above a
		# midtone into the shoulder, which is where the colour goes: a lit green
		# and a lit white came out within a few percent of each other. More
		# headroom, and the exposure back up to hold the midtones where they were.
		"exposure": 0.9,
		"white": 1.85,
		"fog_color": Color("9b9f92"),
		"fog_energy": 1.0,
		"fog_density": 0.00082,
		"fog_sun_scatter": 0.12,
		"fog_aerial": 0.22,
		"fog_sky": 0.07,
		"fog_height": 6.0,
		"fog_height_density": 0.005,
		"glow": 0.55,
		"glow_bloom": 0.06,
		# Contrast over saturation. Turning saturation up to compensate for a flat
		# image is what gives a scene the primary-colour look of a mobile game;
		# what it was actually missing was separation between light and dark.
		"contrast": 1.25,
		"saturation": 1.08,
	},
	LightingMode.NIGHT:
	{
		"zenith_color": Color("01040f"),
		"mid_color": Color("071428"),
		"horizon_color": Color("1a4560"),
		"ground_color": Color("010309"),
		"band_low": 0.10,
		"band_high": 0.62,
		"horizon_glow": 0.28,
		"energy": 1.0,
		"sun_color": Color(0.68, 0.72, 0.84),
		"sun_radius": 0.040,
		"sun_halo": 0.26,
		"sun_halo_falloff": 18.0,
		"sun_disc": 1.0,
		"moon_face": 1.0,
		"cloud_lit": Color("2e466b"),
		"cloud_dark": Color("040814"),
		"cloud_cover": 0.10,
		"cloud_sharpness": 0.28,
		"cloud_scale": 1.40,
		"cloud_speed": 0.003,
		"cloud_opacity": 0.28,
		"bank_cover": 0.32,
		"bank_opacity": 0.18,
		"bank_height": 0.10,
		"bank_haze": 0.62,
		"star_intensity": 5.2,
		"galaxy_color": Color("7d8ed4"),
		"light_color": Color("9dbbe8"),
		"light_energy": 0.68,
		"light_angle": Vector3(-46.0, 32.0, 0.0),
		"angular_distance": 0.6,
		"fill_color": Color("31527e"),
		"fill_energy": 0.26,
		"ambient": 0.36,
		"ambient_color": Color("1b3156"),
		"ambient_sky_mix": 0.30,
		"exposure": 0.91,
		"white": 1.52,
		"fog_color": Color("2b3f60"),
		"fog_energy": 1.0,
		"fog_density": 0.00115,
		"fog_sun_scatter": 0.20,
		"fog_aerial": 0.24,
		"fog_sky": 0.04,
		"fog_height": 3.5,
		"fog_height_density": 0.006,
		"glow": 0.58,
		"glow_bloom": 0.06,
		"contrast": 1.22,
		"saturation": 1.02,
	},
}

## Length of a weather cell along the route. Rain is a band you ride into and out
## of — not a per-frame roll — so the sky ahead can be telling you about it for
## half a kilometre before the first drop.
@export var rain_band_m: float = 2600.0
## Noise values where rain starts and where it is at its heaviest. Most of the
## route is dry on purpose: weather you meet twice an hour is weather, weather
## you meet constantly is a filter.
const RAIN_ONSET := 0.58
const RAIN_FULL := 0.80

## Chosen in the start menu and fixed for the run. Removing route-driven time
## also removes the constant sky invalidation that used to arrive with it.
var lighting_mode: LightingMode = LightingMode.DAY
## 0 dry, 1 the middle of a squall.
var rain: float = 0.0

var _sky_mat: ShaderMaterial
var _grade_mat: ShaderMaterial
var _environment: Environment
var _fill: DirectionalLight3D
var _ride_audio: Node
var _rain_fx: GPUParticles3D
var _rain_process: ParticleProcessMaterial
var _road_material: ShaderMaterial
var _applied_rain: float = -1.0
var _applied_scenic: bool = false


func _ready() -> void:
	Engine.time_scale = 1.0  # a crashed run leaves it in slow motion
	_build_environment()
	_build_grade_overlay()
	_build_rain()
	_ride_audio = RideAudioGD.new()
	_ride_audio.name = "RideAudio"
	add_child(_ride_audio)
	road_streamer.bind_player(player)
	traffic_manager.bind_player(player)
	hud.bind_player(player)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_day"):
		_cycle_lighting()
	if _grade_mat:
		# Re-seeded every frame: a fixed noise pattern is a dirty lens, a moving
		# one is grain, and only the moving one breaks up gradient banding.
		_grade_mat.set_shader_parameter("seed", float(Time.get_ticks_msec() % 10000) * 0.37)
	_update_weather(delta)
	# Realtime sky can absorb a uniform write every frame, so rain eases the
	# overcast instead of jumping the deck in fifths.
	#
	# Riding onto the platform has to count as a change too. `_mood_now()` reads
	# the scenic state, but the only thing that used to trigger a re-apply was the
	# rain value moving — and dry weather pins that to exactly 0.0 and holds it
	# there, so `is_equal_approx` was true every frame and the scenic mood never
	# arrived. On a dry run the overlook was being lit by the riding mood for the
	# whole time the rider was parked at it, which is the one place in the game
	# that has a mood of its own.
	var scenic := _at_scenic_view()
	if _applied_rain < 0.0 or scenic != _applied_scenic or not is_equal_approx(rain, _applied_rain):
		_applied_rain = rain
		_applied_scenic = scenic
		_apply_lighting()


func _cycle_lighting() -> void:
	## T previews the three authored looks; there is no distance-driven ride time.
	lighting_mode = ((lighting_mode + 1) % LightingMode.size()) as LightingMode
	_apply_lighting()
	if hud.has_method("show_lighting_mode"):
		hud.call("show_lighting_mode", lighting_mode)


func preview_mood(mood: int) -> void:
	## Title screen live-preview: swap the sky without touching traffic or score.
	lighting_mode = clampi(mood, 0, LightingMode.size() - 1) as LightingMode
	_applied_rain = -1.0
	_apply_lighting()


func begin_ride(mood: int, difficulty: int) -> void:
	preview_mood(mood)
	if traffic_manager.has_method("set_difficulty"):
		traffic_manager.call("set_difficulty", difficulty)
	var game := get_node_or_null("/root/GameManager")
	if game and game.has_method("set_difficulty"):
		game.call("set_difficulty", difficulty)


func _route_metres() -> float:
	## Position on the route, not distance scored. Near-miss bonus metres must not
	## be able to push the sun across the sky.
	return maxf(player.track_z, 0.0)


func _build_environment() -> void:
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = SKY_SHADER

	var sky := Sky.new()
	sky.sky_material = _sky_mat
	# Realtime radiance is the cheap path for a sky that uses TIME (cloud drift,
	# twinkle) and that weather eases every frame. Incremental plus a frozen
	# phase was cheaper, and it is also why rain used to step the whole look.
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	_sky_mat.set_shader_parameter("sky_phase", float(_path_seed() % 1000) * 0.17)

	_environment = Environment.new()
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = sky
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Road and water already use authored sky/specular reflections. SSR added
	# 4–6 ms on the target integrated GPU and was the largest sustained loss of
	# frame headroom, especially while the scenic landscape was streaming.
	_environment.ssr_enabled = false
	_environment.tonemap_mode = Environment.TONE_MAPPER_ACES

	# Bloom. The world is built from HDR vertex colours — lamps, windows, dials,
	# the sun — and without a glow pass all of that just clips to flat white.
	#
	# The weights matter more than the intensity. Levels 6-7 are near-fullscreen
	# blurs, so giving them real weight smears the bright horizon band over the
	# entire image and the game turns into one orange wash. Weight the tight
	# levels, let 5 carry a little spill, and leave the widest two alone.
	_environment.glow_enabled = true
	_environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	# Only genuinely-HDR pixels bloom. Below ~1.2 the lit sky itself qualifies.
	_environment.glow_hdr_threshold = 1.25
	_environment.glow_hdr_scale = 2.0
	_environment.glow_intensity = 0.55
	_environment.glow_strength = 1.0
	for level in [1, 2, 3, 4, 5, 6, 7]:
		_environment.set("glow_levels/%d" % level, [0.0, 0.4, 1.0, 0.5, 0.15, 0.0, 0.0][level - 1])

	_environment.fog_enabled = true
	_environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL

	_environment.adjustment_enabled = true
	_environment.adjustment_color_correction = _grade_lut()

	world_env.environment = _environment

	# The sky shader draws its own disc, so the light has to be published to the
	# sky rather than kept light-only.
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	# The filtered directional shadow map visibly resolves into a dotted mesh on
	# the flat road. Keep directional light and authored face shading, but skip the
	# extra shadow render passes entirely; this is cleaner and substantially cheaper.
	sun.shadow_enabled = false

	_build_fill_light()
	_apply_lighting()


func _build_fill_light() -> void:
	## Sky-coloured bounce from the opposite side. Ambient alone leaves the shaded
	## face of every low-poly shape reading as one dead value; a weak cool fill is
	## the cheapest way to keep silhouettes round and shadows from going to mud.
	_fill = DirectionalLight3D.new()
	_fill.name = "Fill"
	_fill.shadow_enabled = false
	_fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	# Steep, and from the side the key is not.
	#
	# At 32° it was nearly as low as the sun and pointing down the route, which
	# meant the two lights agreed about which faces mattered: anything turned
	# across the road got neither. That is most of the overlook — the headland
	# face, the shore and the near fells all present themselves broadside to a
	# rider looking out across the valley — and it is why the whole foreground
	# there came out at a value of about three percent.
	#
	# Raised to 64° it stands in for skylight, which is what a fill is: the ground
	# and every slope facing anywhere near up now collects it, vertical faces
	# still do not, and the low warm key keeps its monopoly on the faces it rakes.
	# Low warm key, high cool fill — the whole sunset landscape in two lights.
	_fill.rotation_degrees = Vector3(-64.0, 152.0, 0.0)
	add_child(_fill)


func _grade_lut() -> GradientTexture1D:
	## Per-channel curve, applied after tonemapping: shadows sit slightly cool and
	## lifted, highlights run warm. This is the split-tone that stops ACES output
	## from looking like untouched engine grey.
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.22, 0.58, 1.0])
	gradient.colors = PackedColorArray(
		[
			Color(0.014, 0.026, 0.039),
			Color(0.190, 0.226, 0.244),
			Color(0.600, 0.568, 0.520),
			Color(1.000, 0.956, 0.875),
		]
	)
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	texture.width = 256
	return texture


func _hour_mood() -> Dictionary:
	return MOODS[lighting_mode]


func _mood_now() -> Dictionary:
	## The one place a mood is resolved. The hour, and then the weather on top of
	## it — so rain works at every hour instead of being a fourth preset that
	## throws the time of day away.
	var mood: Dictionary = _hour_mood()
	if rain > 0.001:
		mood = _overcast(mood, rain)
	# The overlook is the route's earned reveal. Weather may recolour it, but it
	# must not erase it. From the parking as well as the bench: looking at the
	# lake from the bike used the riding fog and the far shore vanished.
	if _at_scenic_view():
		mood = _protect_scenic_visibility(mood)
	return mood


func _at_scenic_view() -> bool:
	## Sitting on the bench, or parked on the platform beside it. Both are the
	## overlook being looked at rather than ridden past, and both want its mood.
	if bool(player.get("seated")):
		return true
	var path := get_node_or_null("/root/RoadPath")
	return path != null and bool(path.call("at_platform", player.track_z, player.lateral))


static func _protect_scenic_visibility(mood: Dictionary) -> Dictionary:
	## Aerial perspective, not clarity.
	##
	## This used to clamp the fog off — density down 7x, aerial down 5x — on the
	## theory that a view you have ridden a 3 km detour to reach should be seen
	## rather than hidden. What it actually removed was the one cue that tells a
	## human eye how far away anything is: each successive ridge stepping paler,
	## bluer and lower in contrast toward the sky. Every layer arrived at the same
	## value, and a lake basin, a far shore and four mountain ranges collapsed
	## into a single flat card. The riding view keeps its fog and reads as deep;
	## the overlook threw its own depth away.
	##
	## So: density *low* — an exponential curve dense enough to eat the far range
	## is not perspective, it is weather — and `fog_aerial` high, because aerial
	## perspective blends toward the sky rather than toward a flat fog colour, so
	## distant ridges take the sky's own hue and the relationship holds at every
	## time of day. Roughly 7% haze on the near shore, 14% on the far, half on the
	## furthest range: a ladder the eye reads as kilometres.
	var out: Dictionary = mood.duplicate()
	out["fog_density"] = minf(float(out["fog_density"]), 0.00016)
	out["fog_aerial"] = maxf(float(out["fog_aerial"]), 0.55)
	# The sky is the far end of that ladder and must not be fogged onto itself.
	out["fog_sky"] = minf(float(out["fog_sky"]), 0.02)
	# No ground layer. A haze slab lying in the basin is a horizontal band across
	# the middle of the view, which is the one place a vista cannot afford one.
	out["fog_height_density"] = 0.0
	# Agree with the sky rather than fighting it: the dusk fog colour is a muddy
	# mauve that reads as dirt on the lens when it is carrying a whole valley.
	out["fog_color"] = (out["fog_color"] as Color).lerp(out["mid_color"], 0.55)
	out["contrast"] = maxf(float(out["contrast"]), 1.20)
	out["saturation"] = maxf(float(out["saturation"]), 1.10)
	# A small lift only. The old +1.02 exposure and +0.42 sky ambient were there
	# to rescue detail out of silhouette back when the light had no darks in it
	# to begin with; now that shaded slopes land honestly dark, lifting this hard
	# just flattens the form the light is finally producing.
	out["exposure"] = maxf(float(out["exposure"]), 1.02)
	# Enough sky in the ambient that a slope turned away from a low sun settles
	# into a cool blue rather than into nothing. At 0.36 the shaded side of every
	# fell in the forest and mountain views was reading as flat black, which is
	# not a dark — it is an absence, and it takes the whole near half of the
	# composition out of the picture.
	out["ambient_sky_mix"] = maxf(float(out["ambient_sky_mix"]), 0.52)
	out["ambient"] = maxf(float(out["ambient"]), 0.86)
	return out


static func _blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	## Every mood key is a Color, a Vector3 or a number, and all three interpolate
	## honestly — which is the whole reason the moods were written as data. Sun
	## angle included: lerping the euler is what walks the sun down the sky.
	var out := {}
	for key in a:
		var from: Variant = a[key]
		if from is Color:
			out[key] = (from as Color).lerp(b[key], t)
		elif from is Vector3:
			out[key] = (from as Vector3).lerp(b[key], t)
		else:
			out[key] = lerpf(float(from), float(b[key]), t)
	return out


static func _dull(c: Color, amount: float) -> Color:
	## Toward flat, slightly cool grey at its own brightness. Overcast does not
	## darken colour so much as drain it, and multiplying everything down instead
	## just reads as dusk arriving early.
	var lum: float = c.r * 0.3 + c.g * 0.55 + c.b * 0.15
	return c.lerp(Color(lum * 0.86, lum * 0.90, lum * 1.0), amount)


static func _overcast(mood: Dictionary, r: float) -> Dictionary:
	## Rain as a layer over whatever hour it is, not a mood of its own.
	##
	## The sky closes over, the sun stops being a body and becomes a direction,
	## colour drains, and the viewing distance shuts down — that last one is what
	## makes riding into a squall feel like riding into something rather than
	## watching a filter fade in.
	var out: Dictionary = mood.duplicate()
	for key in ["zenith_color", "mid_color", "horizon_color", "ground_color", "cloud_lit", "cloud_dark", "ambient_color", "fog_color"]:
		out[key] = _dull(mood[key], r * 0.55)
	# Steel, not brown: dulling a warm day horizon on its own just makes mud.
	out["zenith_color"] = (out["zenith_color"] as Color).lerp(Color("3d4c5c"), r * 0.78)
	out["mid_color"] = (out["mid_color"] as Color).lerp(Color("6e7886"), r * 0.82)
	out["horizon_color"] = (out["horizon_color"] as Color).lerp(Color("90969e"), r * 0.90)
	out["cloud_lit"] = (out["cloud_lit"] as Color).lerp(Color("c8ccd2"), r * 0.62)
	out["cloud_dark"] = (out["cloud_dark"] as Color).lerp(Color("3a4450"), r * 0.62)
	out["fog_color"] = (out["fog_color"] as Color).lerp(Color("7a828c"), r * 0.70)
	out["cloud_cover"] = lerpf(mood["cloud_cover"], 0.90, r)
	out["cloud_opacity"] = lerpf(mood["cloud_opacity"], 1.0, r)
	# A rain deck is a sheet, not chopped cumulus: soften the edges and grow the
	# masses so the sky closes over instead of tiling into noise.
	out["cloud_sharpness"] = lerpf(mood["cloud_sharpness"], 0.14, r)
	out["cloud_scale"] = lerpf(mood["cloud_scale"], 1.05, r)
	out["cloud_speed"] = lerpf(mood["cloud_speed"], 0.012, r)
	out["bank_cover"] = lerpf(mood["bank_cover"], 0.88, r)
	out["bank_opacity"] = lerpf(mood["bank_opacity"], 1.0, r)
	out["bank_height"] = lerpf(mood["bank_height"], 0.22, r)
	out["bank_haze"] = lerpf(mood["bank_haze"], 0.88, r)
	out["sun_disc"] = mood["sun_disc"] * (1.0 - r)
	out["sun_halo"] = mood["sun_halo"] * (1.0 - r * 0.85)
	out["horizon_glow"] = mood["horizon_glow"] * (1.0 - r * 0.7)
	out["star_intensity"] = mood["star_intensity"] * (1.0 - r)
	out["light_energy"] = mood["light_energy"] * (1.0 - r * 0.58)
	out["fill_energy"] = mood["fill_energy"] * (1.0 - r * 0.3)
	out["angular_distance"] = lerpf(mood["angular_distance"], 3.0, r)
	out["fog_density"] = mood["fog_density"] * (1.0 + r * 2.8)
	out["fog_aerial"] = lerpf(mood["fog_aerial"], 0.45, r)
	out["fog_sky"] = lerpf(mood["fog_sky"], 0.28, r)
	out["fog_sun_scatter"] = mood["fog_sun_scatter"] * (1.0 - r)
	out["saturation"] = mood["saturation"] * (1.0 - r * 0.34)
	out["contrast"] = lerpf(mood["contrast"], 1.0, r * 0.6)
	out["glow"] = mood["glow"] * (1.0 - r * 0.35)
	return out


func _weather_hash(cell: int) -> int:
	var seed_value: int = _path_seed()
	var h: int = (cell * 374761393 + seed_value * 668265263) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	return h ^ (h >> 16)


func _path_seed() -> int:
	var path := get_node_or_null("/root/RoadPath")
	return int(path.world_seed) if path else 1


func _weather_noise(x: float) -> float:
	var cell := floori(x)
	var f: float = x - float(cell)
	f = f * f * (3.0 - 2.0 * f)
	var a: float = float(_weather_hash(cell) & 0xffff) / 65535.0
	var b: float = float(_weather_hash(cell + 1) & 0xffff) / 65535.0
	return lerpf(a, b, f)


func rain_at(metres: float) -> float:
	## Deterministic weather along the route, seeded from the world. Two cell
	## sizes so a front has ragged edges instead of arriving as a clean ramp, and
	## restarting the run gets different weather along with a different road.
	var n: float = _weather_noise(metres / rain_band_m) * 0.68
	n += _weather_noise(metres / (rain_band_m * 0.41) + 37.0) * 0.32
	return smoothstep(RAIN_ONSET, RAIN_FULL, n)


func _update_weather(delta: float) -> void:
	# Eased, not read straight: the noise is smooth in metres, but a restart or a
	# continue jumps the route position and the sky must not snap with it.
	rain = lerpf(rain, rain_at(_route_metres()), 1.0 - exp(-1.6 * delta))
	if rain < 0.002:
		rain = 0.0
	if _road_material:
		_road_material.set_shader_parameter("wet", rain)
	if _rain_fx:
		_rain_fx.emitting = rain > 0.01
		_rain_fx.amount_ratio = clampf(rain, 0.0, 1.0)
		if _rain_fx.emitting:
			_rake_rain()


func _rake_rain() -> void:
	## Lay the drops back along the direction of travel.
	##
	## The streak is a stretched quad aligned to the particle's own velocity, and
	## a drop falling straight down therefore draws a vertical line — which is
	## what real rain does and what nobody has ever seen from a bike at 165 km/h.
	## What a rider sees is the drop's velocity *relative to the helmet*, so the
	## bike's speed is added into the particle here. The drops do drift backwards
	## in world space as a result; over a 1.3 second life, at a distance where
	## they are two pixels wide, nothing about that is visible.
	const FALL := 17.0
	## Roughly 65° back from vertical. Past that the streaks stop reading as
	## weather and start reading as speed lines drawn over the top of it.
	const MAX_RAKE := 2.2
	var back: float = clampf(player.speed / FALL, 0.0, MAX_RAKE)
	_rain_process.direction = Vector3(0.0, -1.0, -back).normalized()
	var magnitude: float = sqrt(1.0 + back * back) * FALL
	_rain_process.initial_velocity_min = magnitude * 0.86
	_rain_process.initial_velocity_max = magnitude * 1.18


func _build_grade_overlay() -> void:
	## Vignette, split tone and dither, in one fullscreen pass over the finished
	## image — see shaders/grade.gdshader. An Environment can tonemap and colour
	## correct but cannot fall off toward the corners, and on a world made of flat
	## colour the dither is what keeps a clear sky from banding.
	##
	## Layer 0 so it sits over the 3D viewport and under the HUD, which is on 1.
	var layer := CanvasLayer.new()
	layer.name = "Grade"
	layer.layer = 0
	var rect := ColorRect.new()
	rect.name = "GradeRect"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grade_mat = ShaderMaterial.new()
	_grade_mat.shader = GRADE_SHADER
	rect.material = _grade_mat
	layer.add_child(rect)
	add_child(layer)


func _build_rain() -> void:
	## One emitter, unparented from the camera on purpose: with global particle
	## coordinates the drops are left behind in world space as the bike drives out
	## from under them, which is exactly the streak past the lens that sells
	## speed. Parented to the head they would hang in front of it like a curtain.
	_road_material = LowPoly.road_material()

	_rain_process = ParticleProcessMaterial.new()
	var process := _rain_process
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(17.0, 7.0, 34.0)
	process.direction = Vector3(0.0, -1.0, 0.0)
	process.spread = 3.0
	process.initial_velocity_min = 15.0
	process.initial_velocity_max = 21.0
	process.gravity = Vector3(0.0, -9.8, 0.0)
	process.scale_min = 0.7
	process.scale_max = 1.4

	# Lay each quad along its own velocity. This is what turns a sprite into a
	# streak, and it is a process-material flag rather than a billboard mode:
	# BILLBOARD_PARTICLES is sprite-sheet animation and does nothing here.
	process.particle_flag_align_y = true

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Not billboarded: with align_y on, the quad's remaining freedom is its
	# facing, and that comes from the emitter's heading at spawn — which is the
	# direction the camera is looking down anyway. Billboarding on top of align_y
	# fights it and spins the streaks about their own length.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.80, 0.87, 0.96, 0.34)
	material.disable_receive_shadows = true

	var quad := QuadMesh.new()
	quad.size = Vector2(0.026, 0.55)
	quad.material = material

	_rain_fx = GPUParticles3D.new()
	_rain_fx.name = "Rain"
	_rain_fx.amount = 560
	_rain_fx.lifetime = 1.3
	_rain_fx.explosiveness = 0.0
	_rain_fx.local_coords = false
	_rain_fx.draw_pass_1 = quad
	_rain_fx.process_material = process
	_rain_fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Ahead and above: the box has to be where the bike is about to be, or at
	# 50 m/s it outruns its own weather.
	_rain_fx.position = Vector3(0.0, 8.0, 18.0)
	_rain_fx.emitting = false
	player.add_child(_rain_fx)


func _apply_lighting() -> void:
	var mood: Dictionary = _mood_now()
	# Headlight off the sunlight rather than off the name of the mood, so it comes
	# up on its own as the clock rides into the night, and fades rather than
	# switching — the clock spends most of its time between two rows.
	#
	# Measured against the table's own two ends rather than against a fixed
	# number. It used to test `< 0.5`, which was true of the night row when that
	# row said 0.42; rebalancing the moods took night to 0.80 and the condition
	# silently became unreachable, so the beam never came on at any hour.
	#
	# The hour, not the weather: a squall drops the sun energy far enough to trip
	# this, and a full-strength beam laid across a bright overcast road reads as a
	# rendering fault rather than as a rider switching the lights on.
	if player.has_method("set_night_lighting"):
		var sun_now := float(_hour_mood()["light_energy"])
		var noon := float(MOODS[LightingMode.DAY]["light_energy"])
		var midnight := float(MOODS[LightingMode.NIGHT]["light_energy"])
		player.call("set_night_lighting", clampf(inverse_lerp(noon, midnight, sun_now), 0.0, 1.0))

	for uniform in SKY_UNIFORMS:
		_sky_mat.set_shader_parameter(uniform, mood[uniform])

	_environment.ambient_light_energy = mood["ambient"]
	# A sunset sky is overwhelmingly one hue, so pure sky ambient paints the whole
	# world that hue and every surface loses its own colour. Mixing a cool tint
	# back in is what keeps lit faces warm and shaded faces violet.
	_environment.ambient_light_color = mood["ambient_color"]
	_environment.ambient_light_sky_contribution = mood["ambient_sky_mix"]
	_environment.tonemap_exposure = mood["exposure"]
	_environment.tonemap_white = mood["white"]
	_environment.fog_light_color = mood["fog_color"]
	_environment.fog_light_energy = mood["fog_energy"]
	_environment.fog_density = mood["fog_density"]
	_environment.fog_sun_scatter = mood["fog_sun_scatter"]
	_environment.fog_aerial_perspective = mood["fog_aerial"]
	_environment.fog_sky_affect = mood["fog_sky"]
	_environment.fog_height = mood["fog_height"]
	_environment.fog_height_density = mood["fog_height_density"]
	_environment.glow_intensity = mood["glow"]
	_environment.glow_bloom = mood["glow_bloom"]
	_environment.adjustment_contrast = mood["contrast"]
	_environment.adjustment_saturation = mood["saturation"]
	sun.light_color = mood["light_color"]
	sun.light_energy = mood["light_energy"]
	sun.rotation_degrees = mood["light_angle"]
	sun.light_angular_distance = mood["angular_distance"]
	_fill.light_color = mood["fill_color"]
	_fill.light_energy = mood["fill_energy"]
