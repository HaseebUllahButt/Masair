shader_type spatial;
render_mode cull_disabled;

// Foliage: vertex-coloured like everything else, but it moves.
//
// Static trees are the loudest tell that a world is a diorama. The sway is
// driven by world position so neighbouring trees are out of phase with each
// other, and weighted by height above the instance origin so trunks stay
// planted while crowns travel.

uniform float sway_strength = 0.055;
uniform float sway_speed = 1.05;
// Leaves are thin enough to pass light. A little of the albedo added back on the
// unlit side stops crowns reading as solid black cutouts against a bright sky.
uniform float translucency : hint_range(0.0, 1.0) = 0.22;

void vertex() {
	// Instance origin in world space: the per-tree phase offset.
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float phase = TIME * sway_speed + origin.x * 0.23 + origin.z * 0.17;
	// Height above the instance origin, so the sway hinges at the base.
	float lever = max(VERTEX.y, 0.0);
	float gust = 0.75 + 0.25 * sin(TIME * 0.31 + origin.z * 0.05);
	VERTEX.x += sin(phase) * sway_strength * lever * gust;
	VERTEX.z += cos(phase * 0.83) * sway_strength * 0.6 * lever * gust;
}

// sRGB decode for hex-authored vertex colour — see LowPoly._srgb(). No
// srgb_to_linear() builtin in this engine version.
vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	ALBEDO = to_linear(COLOR.rgb);  // hex-authored vertex colour — see LowPoly._srgb()
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	BACKLIGHT = vec3(translucency);
}
