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
// Sun through the leaves. BACKLIGHT alone is grey light passing a grey sheet;
// real leaves glow yellow-green where the sun is behind them, and that rim is
// the whole difference between a tree against a low sun and a cardboard cutout.
uniform vec3 leaf_glow : source_color = vec3(1.0, 0.86, 0.42);
uniform float leaf_glow_strength : hint_range(0.0, 2.0) = 0.55;
// Self-shadowing a canopy would take a shadow map. The underside of a crown is
// dark and the top catches sky for the same reason every time, so it is painted
// from height in the mesh's own space: crowns and conifers stand on Y=0 and
// reach ~1, blobs are centred on it.
uniform float crown_depth : hint_range(0.0, 1.0) = 0.42;
// Per-tree value drift. A thousand instances of one hex colour is the mark of a
// procedural forest; a few percent either way makes it a wood.
uniform float instance_drift : hint_range(0.0, 0.3) = 0.09;
// Sky scattered through the canopy. With no shadows in this game the faces the
// rider sees are usually the ones turned from a low sun, and a crown lit only by
// ambient is a black shape. Leaves pass and bounce skylight all through a tree,
// so up-facing facets carry it and the underside keeps its shade.
uniform vec3 canopy_sky : source_color = vec3(0.50, 0.62, 0.70);
uniform float canopy_sky_strength : hint_range(0.0, 1.0) = 0.5;
// A canopy is not a solid: light scattered through the leaves wraps round the
// crown, so the terminator is soft and far past 90°. Half-Lambert is the cheap
// form of that, and it is what keeps the side of a spruce turned from a low sun
// green instead of a black paper cutout.
uniform float wrap : hint_range(0.0, 1.0) = 0.55;

// Canopy hexes were authored nearly black ("1c3328" is 0.02 linear) back when
// ambient was strong enough to wash everything mint. Nothing multiplied onto an
// albedo that dark survives, so the darkest greens are lifted toward a real leaf
// value; bright verge greens, which already read, are left where they are.
uniform float leaf_floor : hint_range(0.0, 0.1) = 0.072;

varying float crown_h;
varying float drift;

void vertex() {
	// Instance origin in world space: the per-tree phase offset.
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float phase = TIME * sway_speed + origin.x * 0.23 + origin.z * 0.17;
	// Height above the instance origin, so the sway hinges at the base.
	float lever = max(VERTEX.y, 0.0);
	crown_h = smoothstep(-0.35, 0.9, VERTEX.y);
	drift = fract(sin(dot(floor(origin.xz * 0.5), vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
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
	vec3 albedo = to_linear(COLOR.rgb);  // hex-authored vertex colour — see LowPoly._srgb()
	float leaf_lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	// A floor, not a gain: conifer tiers multiply a dark vertex shade into an
	// already dark instance colour and sat far below any fixed factor's reach.
	// Capped so a genuinely black prop on this material stays dark.
	albedo *= clamp(leaf_floor / max(leaf_lum, 1e-4), 1.0, 12.0);
	// Deep inside the crown, sky on top. Squared toward the base so the change
	// reads as a shadowed underside rather than a gradient painted up the tree.
	float depth = mix(1.0 - crown_depth, 1.08, crown_h * crown_h * (3.0 - 2.0 * crown_h));
	// Drift warms as it brightens, the way sun-bleached leaves do.
	albedo *= depth * (1.0 + drift * instance_drift * 2.0);
	albedo *= mix(vec3(1.0), vec3(1.05, 1.02, 0.9), max(drift, 0.0) * 2.0 * instance_drift * 4.0);
	ALBEDO = albedo;
	float up = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y * 0.5 + 0.5;
	EMISSION = albedo * canopy_sky * canopy_sky_strength * (0.35 + 0.65 * up) * depth;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	BACKLIGHT = vec3(translucency);
}

void light() {
	// Wrapped Lambert, plus the sun through the leaves: light
	// arriving from behind the face, strongest where the eye looks toward it.
	float ndl = dot(NORMAL, LIGHT);
	float wrapped = clamp((ndl + wrap) / (1.0 + wrap), 0.0, 1.0);
	DIFFUSE_LIGHT += wrapped * ATTENUATION * LIGHT_COLOR / PI;
	float behind = clamp(-ndl, 0.0, 1.0);
	float toward = pow(clamp(dot(-VIEW, LIGHT), 0.0, 1.0), 3.0);
	// DIFFUSE_LIGHT is multiplied by albedo afterwards, so no ALBEDO here.
	vec3 glow = leaf_glow * (translucency * behind + leaf_glow_strength * toward * (0.35 + 0.65 * behind));
	DIFFUSE_LIGHT += glow * ATTENUATION * LIGHT_COLOR / PI * 3.0;
}
