shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

#include "res://shaders/wind.gdshaderinc"

uniform float wave_height = 0.18;
uniform float wave_speed = 0.72;
uniform float wave_scale = 1.0;
uniform float shimmer_amount = 1.0;
// The colour of the sky at the horizon, pushed per-mood by main.gd. Water is a
// mirror long before it is a substance: from the seat the far surface sits at
// a grazing angle, so the fresnel term below lays the sky's own colour across
// the distance and leaves the near water deep. Without it the lake was its
// albedo times whatever little light reached it — a black floor under every
// sunset.
uniform vec3 sky_mirror : source_color = vec3(0.10, 0.11, 0.12);
// The sky higher up, reflected where the eye looks down on the water steeply.
uniform vec3 sky_high : source_color = vec3(0.08, 0.10, 0.14);
// Stylised floor under the Fresnel term — see fragment().
uniform float mirror_floor : hint_range(0.0, 1.0) = 0.20;

varying vec3 world_position;

// Glitter needs irregular cells — a single sine at this scale reads as parallel
// bands (corduroy) across the whole basin, not sparkle. Two drifting octaves of
// value noise give a broken, shifting texture instead.
float whash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float wnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(whash(i), whash(i + vec2(1.0, 0.0)), u.x),
		mix(whash(i + vec2(0.0, 1.0)), whash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

float glitter(vec2 p, float t) {
	vec2 q = p * wave_scale;
	return wnoise(q * vec2(0.55, 0.9) + vec2(t * 0.30, -t * 0.21))
		* 0.65 + wnoise(q * vec2(1.3, 0.7) + vec2(-t * 0.17, t * 0.26)) * 0.35;
}

float water_height(vec2 p, float t) {
	// The slow swell under everything: ~400 m crests breathing at a few
	// centimetres, so the basin heaves rather than lying dead flat under the
	// chop. Same family as the wind the fields and hedges answer to.
	float swell = sin(dot(p, normalize(vec2(0.82, 0.57))) * 0.016 * wave_scale + t * 0.42) * 1.15;
	float broad = sin(dot(p, normalize(vec2(0.82, 0.57))) * 0.055 * wave_scale + t * 0.55) * 0.48;
	float crosswave = sin(dot(p, normalize(vec2(-0.38, 0.92))) * 0.105 * wave_scale - t * 0.78) * 0.30;
	float ripple = sin(dot(p, normalize(vec2(0.97, -0.24))) * 0.215 * wave_scale + t * 1.18) * 0.16;
	return (swell + broad + crosswave + ripple) * wave_height;
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += water_height(world.xz, TIME * wave_speed);
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * wave_speed;
	float step_size = 0.32;
	float center = water_height(world_position.xz, t);
	float right = water_height(world_position.xz + vec2(step_size, 0.0), t);
	float forward = water_height(world_position.xz + vec2(0.0, step_size), t);
	vec3 world_normal = normalize(vec3((center - right) / step_size, 1.0, (center - forward) / step_size));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 4.0);
	float shimmer = glitter(world_position.xz, t);
	vec3 water_color = COLOR.rgb * vec3(0.54, 0.84, 1.08);
	ALBEDO = water_color + vec3(0.012, 0.020, 0.022) * shimmer * shimmer_amount;
	// A lake is a mirror before it is a substance, and how much of one depends
	// on the angle it is seen at: Schlick's Fresnel. That light
	// arrives as radiance, not albedo: after dark the lit term on this mesh is a
	// rounding error, so the sky goes on EMISSION where the dusk can be seen.
	//
	// This used to be keyed on view distance, on the theory that from the seat
	// the grazing angle *is* the distance. It is only that for one eye height.
	// The bench sits ninety metres over the water, so the whole near basin lay
	// inside the "not yet a mirror" ramp and came out as the albedo under a
	// low orange key — a flat mauve slab across the bottom third of every view.
	// Taken against the flat surface normal the ramp is honest from the saddle
	// and from the bench alike, and needs no luck with NORMAL's sign.
	vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	float cos_flat = abs(dot(up_view, VIEW));
	// The floor sits well past water's physical F0 of 0.02. A real lake seen
	// from a hillside is full of reflected sky because the sky is bright and the
	// lake is not; in a low-poly scene with no reflected shores to break it up,
	// the physical number leaves the near basin a dead slab. A stylised floor
	// keeps the sky in it.
	float schlick = mirror_floor + (1.0 - mirror_floor) * pow(1.0 - mix(cos_flat, facing, 0.3), 5.0);
	// The reflected ray climbs as the eye looks down: grazing water shows the
	// horizon glow, steeper water the sky higher up.
	vec3 reflected = mix(sky_mirror, sky_high, smoothstep(0.08, 0.55, cos_flat));
	// At steep angles, preserve the sky's brightness while the water body
	// supplies its cool hue. The grazing horizon still carries warm sky;
	// the direct sun path remains in light(), with its original light colour.
	float body_view = smoothstep(0.06, 0.30, cos_flat);
	vec3 body_tint = water_color / max(max(water_color.r, water_color.g), max(water_color.b, 0.001));
	float reflected_luma = dot(reflected, vec3(0.2126, 0.7152, 0.0722));
	reflected = mix(reflected, body_tint * reflected_luma, body_view * 0.92);
	float wave_phase = center / max(wave_height, 0.001);
	// It is never the full uniform colour, though — a flat sheet of horizon
	// paint reads as fog or a floor, not water. The swell phase and the shimmer
	// streaks ride on the mirror so the surface keeps moving structure: long
	// bands where the swell rolls and a finer glitter on top. Kept under the
	// material's own shimmer_amount so the sea — kilometres of it — does not
	// carry the lake's sparkle density as stripes.
	// This used to run to ~1.93 on a bright swell, which doubled the reflected
	// sky and turned the far basin into a pale cream slab — the largest
	// "greyed out" area in every overlook view.
	float structure = 0.88 + 0.5 * shimmer * shimmer_amount + 0.15 * wave_phase;
	// The same gust front that bends the hedge dims and brightens the mirror:
	// broad patches of sun drift across the basin on the wind's own clock.
	structure *= 0.90 + 0.22 * wind_gust(world_position.xz, TIME);
	// Light scattered back up out of the body of the water. Small, but it is
	// what keeps deep water teal under a key of any colour instead of taking the
	// hue of the sunset like a painted floor would.
	vec3 body = water_color * 0.50 * (1.0 - schlick);
	// The vertex tones (depth, shore aprons, drift bands) ride on the mirror
	// too — at 0.35 the far half of the basin averaged back to one pale plane
	// at grazing angles; half-coupled, the baked bands modulate the reflected
	// sky and the sheet keeps its water-body structure.
	EMISSION = reflected * schlick * structure * mix(vec3(1.0), water_color * 2.4, 0.52) + body;
	METALLIC = 0.12;
	ROUGHNESS = mix(0.16, 0.055, fresnel);
	SPECULAR = 0.92;
}

// The sun path.
//
// A lake at a viewpoint is the largest single surface in the frame, and without
// a path of light on it there is nothing to look at and nothing to say where the
// sun is: it reads as a sheet of coloured glass laid in the valley. Painting one
// into the vertex colour was tried and cannot work — it has to sit on the line
// between the viewer and the sun, and that line moves with the head and with the
// time of day, neither of which a baked mesh knows.
//
// Taking over light() means owning the diffuse term too, which is fine: water is
// almost all specular anyway, and a lake wants far less diffuse than a Lambert
// surface would give it.
void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * ndl * 0.42;
	// Real glitter is thousands of small facets each catching the sun at a
	// slightly different angle; the wave normals and the glint noise below
	// stand in for those facets.
	vec3 half_vector = normalize(LIGHT + VIEW);
	float ndh = max(dot(NORMAL, half_vector), 0.0);
	// Grazing angles catch far more of it, which is what makes the path widen and
	// brighten as it runs away from the eye. Recomputed here rather than handed
	// over from fragment(): a varying written in fragment() and read in light()
	// is not something to rely on, and this is two instructions.
	float glance = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	float sparkle = glitter(world_position.xz, TIME * wave_speed);
	// The broad lobe laid one even cream sheet over half the basin whenever
	// the view faced the sun — from the bench it read as a sand bar, not
	// water, in every forest overlook by day. The waves here are a few
	// centimetres high, so real glitter stays close to the sun's mirror line:
	// a narrow sheen, and the path itself made of glints — a finer, faster
	// noise thresholded hard, so the sun breaks into moving points with dark
	// water between them, densest on the line to the sun.
	float sheen = pow(ndh, 120.0) * (0.3 + 0.3 * sparkle * shimmer_amount);
	// The second octave is turned against the first, or the two lattices line
	// up and the thresholded points sit on a grid — from the bench the whole
	// basin read as a screen door. The glint lobe is kept tight to the sun's
	// own line: at a broad one every wave across the lake caught the moon too.
	// Only near the sun's line: below ndh 0.9 the lobe is under one percent,
	// and the noise is the lake's costliest term — the basin fills half the
	// seated frame and almost none of it is on the path.
	float glint = 0.0;
	if (ndh > 0.9) {
		float t = TIME * wave_speed;
		vec2 turned = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * world_position.xz;
		float fine = wnoise(world_position.xz * 1.7 + vec2(t * 0.9, -t * 0.7)) * 0.6
			+ wnoise(turned * 3.1 + vec2(-t * 1.3, t * 1.1)) * 0.4;
		glint = smoothstep(0.70, 0.90, fine) * pow(ndh, 48.0) * shimmer_amount;
	}
	float core = pow(ndh, 600.0);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * (sheen + glint * 3.0 + core * 1.4) * mix(1.0, 2.0, glance);
}
