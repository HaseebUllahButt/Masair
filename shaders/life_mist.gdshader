shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// Mist lying on the water below an overlook: a flat sheet a few metres over the
// lake, its density a pattern of world-space noise that flows downwind. The
// sheet never moves; the wisps do. From a bench ninety metres up a standing
// card of mist reads as a sticker, and a sheet seen at the same grazing angle
// as the water reads as weather on it. Fog still applies, so far wisps take
// the air's own colour.

uniform vec3 mist_color : source_color = vec3(0.86, 0.84, 0.88);
uniform float opacity : hint_range(0.0, 1.0) = 0.3;
uniform vec2 flow = vec2(1.5, 0.0);
uniform float grain = 0.011;
uniform float seed = 0.0;
uniform float fade = 1.0;

varying vec3 world_pos;

float mhash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float mnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mhash(i), mhash(i + vec2(1.0, 0.0)), u.x),
		mix(mhash(i + vec2(0.0, 1.0)), mhash(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz - flow * TIME;
	// Two octaves drifting at slightly different rates, so the wisps tear and
	// re-form as they go instead of sliding past as one printed pattern.
	float n = mnoise(p * grain + seed) * 0.6
		+ mnoise(p * grain * 2.7 + vec2(seed * 1.7, -seed) - flow * TIME * 0.004) * 0.4;
	float wisps = smoothstep(0.42, 0.78, n);
	// Feathered all round, so the sheet has no edge anywhere.
	vec2 e = abs(UV * 2.0 - 1.0);
	float edge = (1.0 - smoothstep(0.45, 1.0, e.x)) * (1.0 - smoothstep(0.35, 1.0, e.y));
	ALBEDO = mist_color;
	ALPHA = clamp(wisps * edge * opacity * fade, 0.0, 1.0);
}
