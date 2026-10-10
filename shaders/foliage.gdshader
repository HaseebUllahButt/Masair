shader_type spatial;
render_mode cull_disabled;

// Foliage: vertex-coloured like everything else, but it moves.
//
// Static trees are the loudest tell that a world is a diorama. The sway is
// driven by the shared wind field (wind.gdshaderinc) sampled at the instance
// origin, so a gust travels across the whole landscape at walking speed and a
// hedge line flexes as one wave instead of every plant shivering on its own
// clock. Sway is weighted by height above the instance origin so trunks stay
// planted while crowns travel, and peaks stay inside the corridor allowance
// test_clearance measures (FOLIAGE_SWAY, road_chunk.gd).

#include "res://shaders/wind.gdshaderinc"

uniform float sway_strength = 0.055;
uniform float sway_speed = 1.05;
// Leaves are thin enough to pass light. A little of the albedo added back on the
// unlit side stops crowns reading as solid black cutouts against a bright sky.
uniform float translucency : hint_range(0.0, 1.0) = 0.26;
// Sun through the leaves. BACKLIGHT alone is grey light passing a grey sheet;
// real leaves glow yellow-green where the sun is behind them, and that rim is
// the whole difference between a tree against a low sun and a cardboard cutout.
uniform vec3 leaf_glow : source_color = vec3(1.0, 0.86, 0.42);
uniform float leaf_glow_strength : hint_range(0.0, 2.0) = 0.80;
// Self-shadowing a canopy would take a shadow map. The underside of a crown is
// dark and the top catches sky for the same reason every time, so it is painted
// from height in the mesh's own space: crowns and conifers stand on Y=0 and
// reach ~1, blobs are centred on it.
uniform float crown_depth : hint_range(0.0, 1.0) = 0.48;
// Per-tree value drift. A thousand instances of one hex colour is the mark of a
// procedural forest; a few percent either way makes it a wood.
uniform float instance_drift : hint_range(0.0, 0.3) = 0.12;
// Per-tree hue walk, independent of the value drift: a wood is not one green
// at different brightnesses — spruce goes blue-green, new leaf goes yellow,
// and dry tips go warm. This is most of what keeps a planted stand from
// reading as one plant pasted a hundred times.
uniform float instance_hue : hint_range(0.0, 1.0) = 0.55;
// Cool tint for sheltered canopy facets. The Environment supplies skylight,
// so these surfaces follow day and night instead of emitting their own light.
uniform vec3 canopy_sky : source_color = vec3(0.50, 0.62, 0.70);
uniform float canopy_sky_strength : hint_range(0.0, 1.0) = 0.5;
// A canopy is not a solid: light scattered through the leaves wraps round the
// crown, so the terminator is soft and far past 90°. Half-Lambert is the cheap
// form of that, and it is what keeps the side of a spruce turned from a low sun
// green instead of a black paper cutout.
uniform float wrap : hint_range(0.0, 1.0) = 0.62;

// Canopy hexes were authored nearly black ("1c3328" is 0.02 linear) back when
// ambient was strong enough to wash everything mint. Nothing multiplied onto an
// albedo that dark survives, so the darkest greens are lifted toward a real leaf
// value; bright verge greens, which already read, are left where they are.
uniform float leaf_floor : hint_range(0.0, 0.1) = 0.072;

// How much a passing gust flashes the leaf colour. Leaves turn their pale
// undersides to the light when the wind picks them up, which is the silvery
// ripple that runs down a hedge or across a crown — visible far beyond the
// distance the geometry's own movement resolves at.
uniform float gust_sheen : hint_range(0.0, 0.5) = 0.22;

// Mid-ground aerial perspective. The engine fog is deliberately thin — an
// overlook's kilometres-long view has to stay clear — but that leaves the
// 200–600 m band of trees at full chroma, which is the flat wall a roadside
// wood used to read as. This fades only foliage, and only as far as the first
// ridge: luminance is held so crowns keep their lit/shaded modelling, while
// chroma walks toward the mood's air colour (pushed to aerial_tint each mood
// change — day sage, dusk mauve, night navy) the way real air steals colour
// before it steals value.
uniform float aerial_strength : hint_range(0.0, 1.0) = 0.70;
uniform float aerial_near = 150.0;
uniform float aerial_far = 560.0;
uniform vec3 aerial_tint : source_color = vec3(0.61, 0.66, 0.72);

varying float crown_h;
varying float drift;
varying float drift_hue;
varying float gust_now;
varying float view_dist;

void vertex() {
	// Instance origin in world space: the per-tree phase offset and the point
	// the gust field is sampled at.
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	view_dist = distance(origin, CAMERA_POSITION_WORLD);
	float gust = wind_gust(origin.xz, TIME);
	gust_now = gust;
	// Height above the instance origin, so the sway hinges at the base.
	float lever = max(VERTEX.y, 0.0);
	crown_h = smoothstep(-0.35, 0.9, VERTEX.y);
	drift = fract(sin(dot(floor(origin.xz * 0.5), vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
	// Second hash, different lattice: hue must not track value or the brighter
	// trees would always be the warmer ones.
	drift_hue = fract(sin(dot(floor(origin.xz * 0.5) + 19.19, vec2(26.651, 91.17))) * 24634.6345) - 0.5;

	// Three motions. A slow per-plant rock, still phased from the origin so
	// neighbours disagree; a lean downwind with the gust, which is what makes a
	// front read as one wave arriving rather than every plant doing its own
	// wobble; and a small fast flutter for leaf shimmer. The sum stays under
	// ~1.0 * sway_strength at peak gust, the same envelope the corridor test
	// was tuned against.
	float phase = TIME * sway_speed + origin.x * 0.23 + origin.z * 0.17;
	vec2 rock = vec2(sin(phase) * 0.30, cos(phase * 0.83) * 0.22);
	vec2 lean = WIND_DIR * (gust * 0.85 - 0.30);
	float flutter = sin(TIME * 5.3 + VERTEX.x * 5.0 + origin.x * 3.1 + origin.z * 2.3) * 0.07;
	vec2 sway = rock + lean + vec2(flutter, flutter * 0.6);
	VERTEX.x += sway.x * sway_strength * lever;
	VERTEX.z += sway.y * sway_strength * lever;
}

// sRGB decode for hex-authored vertex colour — see LowPoly._srgb(). No
// srgb_to_linear() builtin in this engine version.
vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	// Match StandardMaterial3D: Compatibility shades in sRGB; only linear
	// renderers need the vertex-colour decode; an unconditional decode crushed leaves.
	vec3 albedo = OUTPUT_IS_SRGB ? COLOR.rgb : to_linear(COLOR.rgb);
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
	// The value gradient alone shades a crown; this paints its temperature too —
	// cool, shadowed skirts under a warm sunlit top. It is the same warm/cool
	// split the key and fill put on everything else, pre-baked because foliage
	// has no shadow map to find it in.
	albedo *= mix(vec3(0.87, 0.96, 1.12), vec3(1.12, 1.06, 0.82), smoothstep(0.08, 0.85, crown_h));
	// Same tree, different green. Cool spruce-blue one way, warm new-leaf the
	// other — kept narrow enough that every tint still reads as foliage.
	vec3 hue_walk = mix(vec3(0.94, 1.00, 1.10), vec3(1.12, 1.01, 0.83), drift_hue + 0.5);
	albedo *= mix(vec3(1.0), hue_walk, instance_hue);
	// The gust's silvering: a flash of paler leaf on the windward pass, keyed to
	// the same field that is bending the plant. Weighted toward the crown top,
	// where the leaves actually turn over.
	albedo *= 1.0 + (gust_now - 0.5) * gust_sheen * (0.5 + 0.5 * crown_h);
	// Aerial depth: held to luminance, so a distant crown keeps its shaded side
	// but loses its green — the difference between a wood reading as layered
	// distance and one reading as a pasted cut-out. At night aerial_tint is
	// navy, so the same line darkens instead of washing.
	float airy = smoothstep(aerial_near, aerial_far, view_dist) * aerial_strength;
	if (airy > 0.001) {
		float lum = max(dot(albedo, vec3(0.2126, 0.7152, 0.0722)), 1e-4);
		float tint_lum = max(dot(aerial_tint, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
		vec3 aired = aerial_tint * (lum / tint_lum);
		albedo = mix(albedo, mix(vec3(lum), aired, 0.65), airy);
	}
	// Keep a cool canopy tint, but let the environment and wrapped light
	// illuminate it. Self-emission made the trees glow green after dark.
	ALBEDO = albedo * mix(vec3(1.0), canopy_sky, canopy_sky_strength * 0.2);
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
	// The gold lives on the silhouette, not the body: ungated, a sunward crown
	// blows out to a flat cream balloon. Fresnel keeps the rim to the leaf edge
	// and crown_h to the top of the canopy, where backlit leaves actually sit.
	float rim_edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	vec3 glow = leaf_glow * (translucency * behind
		+ leaf_glow_strength * toward * (0.15 + 0.85 * behind) * (0.30 + 0.70 * rim_edge) * (0.45 + 0.55 * crown_h));
	DIFFUSE_LIGHT += glow * ATTENUATION * LIGHT_COLOR / PI * 3.0;
}
