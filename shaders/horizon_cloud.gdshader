shader_type spatial;
render_mode unshaded, fog_disabled, shadows_disabled, blend_mix, depth_draw_never, cull_disabled;

// Two-tone vapour so the collar does not melt into the sunset face.

uniform vec3 cloud_lit : source_color = vec3(1.0, 0.86, 0.72);
uniform vec3 cloud_dark : source_color = vec3(0.42, 0.28, 0.40);
uniform float opacity : hint_range(0.0, 1.0) = 0.72;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	float id = float(INSTANCE_ID);
	float bob = sin(TIME * 0.09 + id * 0.37) * 5.0;
	float along = sin(TIME * 0.055 + id * 0.21) * 9.0;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 radial = vec3(origin.x, 0.0, origin.z);
	float rl = length(radial);
	vec3 tangent = rl > 0.001 ? vec3(-origin.z, 0.0, origin.x) / rl : vec3(1.0, 0.0, 0.0);
	vec3 world_off = vec3(0.0, bob, 0.0) + tangent * along;
	VERTEX += inverse(mat3(MODEL_MATRIX)) * world_off;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	// Elliptical, not round. A circular falloff on a wide quad still reads as a
	// disc, and a row of discs on a skyline is the ring of floating plates the
	// collar kept turning into. Faster falloff up and down than across leaves a
	// bank lying along the crest. The x factor stays at 1.0 or above so the
	// lobe always reaches zero inside the quad — clip it and the soft edge
	// becomes a hard vertical cut, which is a worse artefact than the disc.
	float d = length(p * vec2(1.02, 1.30));
	// Noise stretched the same way, so the tears in the bank are horizontal.
	float n = vnoise(UV * vec2(3.4, 2.2) + COLOR.rg * 5.0);
	n = mix(n, vnoise(UV * vec2(7.6, 4.6) + 2.4), 0.44);
	// A long soft ramp rather than a rim. Anything tighter and the puff has a
	// visible edge, which on a skyline is a flying saucer parked on the peak.
	float lobe = smoothstep(1.0, 0.06, d) * smoothstep(0.18, 0.72, n);
	ALPHA = lobe * opacity * COLOR.a;
	ALBEDO = mix(cloud_dark, cloud_lit, clamp(n * 0.7 + (1.0 - d) * 0.45, 0.0, 1.0));
}
