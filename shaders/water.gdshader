shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

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
	float broad = sin(dot(p, normalize(vec2(0.82, 0.57))) * 0.055 * wave_scale + t * 0.55) * 0.48;
	float crosswave = sin(dot(p, normalize(vec2(-0.38, 0.92))) * 0.105 * wave_scale - t * 0.78) * 0.30;
	float ripple = sin(dot(p, normalize(vec2(0.97, -0.24))) * 0.215 * wave_scale + t * 1.18) * 0.16;
	return (broad + crosswave + ripple) * wave_height;
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
	// At grazing angles a lake is a mirror, not a surface: the far half of the
	// sheet carries the sky back to the eye. That light arrives as radiance, not
	// albedo — after dark the lit term on this mesh is a rounding error, so the
	// sky goes on EMISSION where the dusk can actually be seen. Keyed on view
	// distance rather than the wave normal's fresnel: from the seat the grazing
	// angle IS the distance, and this ramp needs no sign convention luck.
	//
	// It is never the full uniform colour, though — a flat sheet of horizon
	// paint reads as fog or a floor, not water. The swell phase and the shimmer
	// streaks ride on the mirror so the far surface keeps moving structure:
	// long bands where the swell rolls and a finer glitter on top.
	float dist_mirror = smoothstep(80.0, 420.0, length(VERTEX));
	float wave_phase = center / max(wave_height, 0.001);
	// Broad wash at the far grazing angle, kept under the material's own
	// shimmer_amount so the sea — kilometres of it — does not carry the lake's
	// sparkle density as stripes; the swell phase lays the darker lanes between
	// crests instead of brightening them.
	EMISSION = sky_mirror * dist_mirror * (0.46 + 0.55 * shimmer * shimmer_amount + 0.12 * wave_phase) * mix(vec3(1.0), water_color * 2.2, 0.45);
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
	// Deliberately broad. A tight lobe on a near-flat sheet is a single hot dot
	// on the horizon; real glitter is thousands of small facets each catching the
	// sun at a slightly different angle, and the wave normals above are standing
	// in for those facets. A low exponent is what spreads it into a path running
	// back toward the viewer instead of a spot sitting on the far shore.
	vec3 half_vector = normalize(LIGHT + VIEW);
	float spec = pow(max(dot(NORMAL, half_vector), 0.0), 22.0);
	// Grazing angles catch far more of it, which is what makes the path widen and
	// brighten as it runs away from the eye. Recomputed here rather than handed
	// over from fragment(): a varying written in fragment() and read in light()
	// is not something to rely on, and this is two instructions.
	float glance = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	float sparkle = glitter(world_position.xz, TIME * wave_speed);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * spec * mix(1.0, 3.4, glance) * (0.55 + 0.75 * sparkle * shimmer_amount);
}
