shader_type spatial;
render_mode unshaded, fog_disabled, shadows_disabled, specular_disabled, cull_back;

// Folded alpine range, lit by hand because the real key is behind it.
//
// At dusk the sun sits three degrees up, dead down the road, so every face the
// rider sees on the near arc is backlit. Plain Lambert makes that a black card;
// mixing the albedo toward the horizon colour makes it an orange sticker. Both
// have been tried. What is left is three cheap terms that still separate one
// facet from the next with no key at all:
//
//   key   half-Lambert wrap — the only term that survives on the sunlit arc
//   dome  how far a plane looks up, which is what lifts a scree shelf off the
//         slope below it when there is nothing but sky to light either
//   rake  the sun's cross axis, which splits the two walls of a gully
//
// COLOR.r snow cap, COLOR.g per-facet grit, COLOR.b height, COLOR.a layer haze.

uniform vec3 foot_color : source_color = vec3(0.24, 0.18, 0.16);
uniform vec3 crest_color : source_color = vec3(0.34, 0.33, 0.38);
uniform vec3 haze_color : source_color = vec3(0.96, 0.69, 0.42);
uniform vec3 sky_color : source_color = vec3(0.68, 0.70, 0.80);
uniform vec3 snow_color : source_color = vec3(0.90, 0.90, 0.93);
uniform vec3 sun_dir = vec3(0.15, 0.42, 0.90);
// Life zones. A range that is one rock colour from foot to crest is a model;
// forest up the lower slopes, bare rock above the treeline and snow on top is
// a mountain. Local mesh height, so the zones stay put on the ring.
uniform vec3 forest_color : source_color = vec3(0.12, 0.20, 0.15);
uniform float treeline = 105.0;
// Moves the snowline as a fraction of the layer's height. 1.0 keeps it bare.
uniform float snow_bias = 0.0;
// Widens the lit/shaded terminator. The ring's facets want a hard decision; the
// overlook ranges are smooth-normalled, and on a folded face the same hard
// step scattered dark blotches across a sunlit fell like camouflage.
uniform float light_soft : hint_range(0.0, 1.0) = 0.0;
// How much of each facet's sideways turn the light ignores. The ring's front is
// a run of near-vertical panels, each turned a few degrees from its neighbour
// where one massif hands the envelope to the next; lit honestly, every panel
// took its own value and the range read as a row of curtains. Facing them all
// at the eye keeps their slope — steep rock against gentle shelf — and drops the
// pleats.
uniform float azimuth_flatten : hint_range(0.0, 1.0) = 0.0;
// Bare rock where the ground is too steep to hold turf — sea cliffs, crags. Off
// for the ring, whose kilometre-wide facets would switch on and off as blocks;
// the overlooks are smooth-normalled and take it as a gradient.
uniform float slope_rock : hint_range(0.0, 1.0) = 0.0;
// Rain closes the distance. This shader is fog_disabled and draws its own air,
// so without it the far ranges stood crisp behind a sea the squall had already
// swallowed.
uniform float weather_haze : hint_range(0.0, 1.0) = 0.0;
// Mist lying in the valleys between ranges: the far layers rise out of it, and
// that is what separates one ridgeline from the next without a single line.
uniform vec3 mist_color : source_color = vec3(0.70, 0.76, 0.84);
uniform float mist_strength : hint_range(0.0, 1.0) = 0.38;

varying vec3 world_n;
varying float snow_v;
varying float grit_v;
varying float lift_v;
varying float haze_v;
varying float band_v;

varying vec3 world_p;
varying float along_v;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x),
		u.y
	);
}

void vertex() {
	world_n = MODEL_NORMAL_MATRIX * NORMAL;
	world_p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	snow_v = COLOR.r;
	grit_v = COLOR.g;
	lift_v = COLOR.b;
	haze_v = COLOR.a;
	band_v = VERTEX.y;
	along_v = VERTEX.x + VERTEX.z;
}

void fragment() {
	vec3 n = normalize(world_n);
	float steep = 1.0 - smoothstep(0.42, 0.72, n.y);
	vec3 eye_p = INV_VIEW_MATRIX[3].xyz;
	vec2 to_eye = eye_p.xz - world_p.xz;
	if (dot(to_eye, to_eye) > 1.0) {
		vec2 flat_dir = normalize(to_eye) * length(n.xz);
		n = normalize(mix(n, vec3(flat_dir.x, n.y, flat_dir.y), azimuth_flatten));
	}
	vec3 sun = normalize(sun_dir);
	float key = clamp(dot(n, sun) * 0.5 + 0.5, 0.0, 1.0);
	float dome = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 across = normalize(cross(sun, vec3(0.0, 1.0, 0.0)) + vec3(1e-4));
	float rake = clamp(dot(n, across) * 0.5 + 0.5, 0.0, 1.0);

	// Two broad octaves in the face's own frame: one carries rock patches, the
	// other stretches down the fall line so snow, scree and the treeline follow
	// the land instead of forming kilometre-wide rectangles. The old third
	// noise octave was too fine to survive the ride and only inflated fill cost.
	float patch = vnoise(vec2(along_v * 0.006, band_v * 0.008));
	float couloir = vnoise(vec2(along_v * 0.017, band_v * 0.004));
	float relief = patch * 0.58 + couloir * 0.42;

	// Two-tone light. A long smooth half-Lambert ramp is what made every face
	// the same soft pink gradient: at two kilometres the eye reads a range by
	// its lit side against its shaded side, so the terminator has to be a
	// decision, not a fade. Still soft enough that a rolling face does not band.
	float lit = smoothstep(0.40 - 0.22 * light_soft, 0.66 + 0.22 * light_soft, key + (rake - 0.5) * 0.30);
	// Floor raised from 0.40. The terminator still has to be a decision — that
	// is what makes a range read as two-sided form rather than a pink gradient —
	// but 0.40 was low enough that a shaded face had almost no value left to
	// carry shape once the rock colour and tint were applied.
	float lum = mix(0.52, 1.0, lit);
	lum += 0.16 * dome * dome;
	lum *= mix(0.90, 1.08, grit_v);
	lum *= mix(0.88 + 0.08 * light_soft, 1.08, relief);

	vec3 rock = mix(foot_color, crest_color, lift_v);
	// Keep the two sides of every form distinctly coloured: sunlit rock picks up
	// a restrained warm cast, while the away-facing side takes the cool sky dome
	// rather than collapsing into black. This gives the low-poly range shape at
	// distances where per-facet normals are no longer legible.
	//
	// The shade tint is cool but no longer blue-heavy: `foot_color` is already a
	// blue-grey scree, so pushing the shadow further towards blue as well as
	// darkening it is what turned a backlit peak into a navy spike.
	vec3 shade_tint = vec3(0.78, 0.84, 1.02);
	vec3 sun_tint = vec3(1.10, 1.00, 0.82);
	vec3 col = rock * lum * mix(shade_tint, sun_tint, lit);
	// Ambient, on both sides of the terminator.
	//
	// At dusk the sky is the brightest thing in the frame, so a face turned away
	// from a low sun is lit *almost entirely* by it. Gating this term on `lit`
	// left the shaded side with nothing but the 0.40 luminance floor, which is
	// what put a hard black-blue spike in front of the hazed ranges at the
	// mountain overlook: one steep backlit peak, correctly shaped, reading as a
	// hole cut in the picture. The shade side now collects skylight, weighted to
	// how much sky it actually faces.
	col += haze_color * (0.010 + 0.024 * dome) * mix(0.45, 1.0, lit);
	col += sky_color * dome * dome * 0.13 * (1.0 - lit);

	// Treeline, ragged, by height alone. Gating it on the facet normal switched
	// whole kilometre-wide quads on and off and left hard green rectangles in
	// the middle of the skyline.
	float ragged = (couloir - 0.5) * 90.0 + (grit_v - 0.5) * 30.0;
	float forest = 1.0 - smoothstep(treeline - 30.0, treeline + 30.0, band_v + ragged);
	vec3 woods = forest_color * mix(0.62, 1.05, lit) * (0.9 + 0.2 * dome);
	forest *= 1.0 - steep * slope_rock;
	col = mix(col, woods, forest * 0.9);

	// Snow on the summits only. A fixed snowline in metres put the whole upper
	// half of the tall back layers under snow, and four white layers merged into
	// one pale wall. Relative to the layer's own top, only the planted heroes
	// reach it; the cols between them stay rock.
	float snow_edge = 0.64 + snow_bias + (relief - 0.5) * 0.22 - (rake - 0.5) * 0.08;
	float hold = smoothstep(0.05, 0.38, n.y);
	// The nearest ring is foothills: caps start on the ranges behind.
	hold *= smoothstep(0.1, 0.2, haze_v);
	float cap = smoothstep(snow_edge - 0.03, snow_edge + 0.05, lift_v) * hold;
	// Rock ribs cut through the snowfield down the couloirs.
	cap *= smoothstep(0.22, 0.46, couloir + (lift_v - snow_edge) * 1.4);
	float snow_amt = max(snow_v * hold, cap);
	vec3 snow_lit = mix(snow_color, snow_color * haze_color * 1.3, 0.40);
	vec3 snow_shade = snow_color * vec3(0.56, 0.66, 0.88) * 0.78 + sky_color * 0.08;
	col = mix(col, mix(snow_shade, snow_lit, lit), snow_amt);

	// Valley mist lying at the foot of each layer, so every ridgeline stands
	// out of the one in front of it.
	float foot = 1.0 - smoothstep(-140.0, 60.0, band_v);
	col = mix(col, mist_color, foot * foot * mist_strength * (0.4 + haze_v));
	// Aerial perspective is the depth cue. Each layer steps most of the way to
	// the air behind it, snow included — an unhazed cap on the farthest range
	// glowed brighter than the near one and flattened the stack.
	vec3 air = mix(mist_color, haze_color, 0.5);
	col = mix(col, air, clamp(haze_v * 0.95 + weather_haze * (0.45 + haze_v), 0.0, 0.94));
	// Soften the ring into the air at the extreme edges of a wide lens, but
	// keep the mountains when the rider looks aside.
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 fwd = -INV_VIEW_MATRIX[2].xyz;
	vec3 radial = world_p - cam;
	radial.y = 0.0;
	fwd.y = 0.0;
	float ahead = 0.0;
	if (dot(radial, radial) > 1.0 && dot(fwd, fwd) > 1e-6) {
		ahead = dot(normalize(radial), normalize(fwd));
	}
	float side = 1.0 - smoothstep(0.12, 0.78, ahead);
	col = mix(col, air, side * 0.08);
	ALBEDO = col;
}
