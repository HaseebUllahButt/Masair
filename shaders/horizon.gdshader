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
uniform float mist_strength : hint_range(0.0, 1.0) = 0.12;
// The tint a sun-facing facet picks up. Warm under a warm key, but pushed
// per-mood from range_material: under a blue night key the same warm cast
// read as sand dunes sprinkled over the skyline.
uniform vec3 key_tint : source_color = vec3(1.03, 0.97, 0.85);

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
		// The far bands carry the biggest silhouettes and need their folds to
		// read as folds: more of each panel's azimuth comes back down the
		// ladder so one face can shade while the next stays lit. The near band
		// keeps the full flatten — its panels are degrees wide and honestly lit
		// they stripe into curtains. The middle bands were nearly as flattened
		// before, which is what turned each mid-ring massif into a single pale
		// slab: every facet shared one lit value.
		float flatten_eff = azimuth_flatten * (1.0 - 0.72 * smoothstep(0.10, 0.55, haze_v));
		n = normalize(mix(n, vec3(flat_dir.x, n.y, flat_dir.y), flatten_eff));
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
	// Rake at 0.42: a front-lit range keeps almost no key spread, so the
	// cross-sun axis is what splits the two walls of every fold gully. At 0.30
	// the rearward arcs shaded as one soft sheet — the "flat pale card".
	float lit = smoothstep(0.40 - 0.22 * light_soft, 0.66 + 0.22 * light_soft, key + (rake - 0.5) * 0.42);
	// Floor raised from 0.40. The terminator still has to be a decision — that
	// is what makes a range read as two-sided form rather than a pink gradient —
	// but 0.40 was low enough that a shaded face had almost no value left to
	// carry shape once the rock colour and tint were applied.
	// The floor is a *ratio*, not just a value: this term is the entire
	// internal light-to-shade spread baked into the range, so 0.52 gave a
	// 1.9:1 range and a mountain read as one wall of paint with a gradient
	// running across it. At 0.42 the same lit/shade split is 2.4:1, which is
	// what makes a two-kilometre form legible as a solid with a front and a
	// side. Note this is the *internal* spread only — the whole frame's
	// light-to-dark ratio also has to survive tonemapping and the grade LUT
	// above it, and at dusk the air is what finally sets that.
	// 0.57 -> 0.62: a shaded rock face still landed inside the LUT's blue
	// shadow anchor and the grade's toe lift, which is what the reviewer reads
	// as "near-black navy". The lit/shade spread stays above 1.6:1 even before
	// the tint split below does its half of the work.
	float lum = mix(0.62, 1.04, lit);
	lum += 0.16 * dome * dome;
	lum *= mix(0.90, 1.08, grit_v);
	// Wider rock-tone spread: (0.80+0.10*ls, 1.12). Front-lit faces have the
	// least geometry in their light, so the patch/couloir texture carries the
	// read of scree ribs and shaded gullies the key cannot.
	lum *= mix(0.80 + 0.10 * light_soft, 1.12, relief);

	// Granite, not gradient: a linear foot->crest mix left half the face at
	// half scrub-green, and under the warm grade that olive is what returned
	// as tan dunes rearward of the rider. The green-grey belongs to the foot
	// band; by a third of the way up the face the rock is slate.
	vec3 rock = mix(foot_color, crest_color, smoothstep(0.18, 0.60, lift_v));
	// Keep the two sides of every form distinctly coloured: sunlit rock picks up
	// a restrained warm cast, while the away-facing side takes the cool sky dome
	// rather than collapsing into black. This gives the low-poly range shape at
	// distances where per-facet normals are no longer legible.
	//
	// The shade tint is nearly neutral now: the grade already cools the frame's
	// darks, and a blue multiplier here *and* there is what kept crushing shaded
	// faces into the "near-black navy" the reviewer kept sending back.
	// (0.85,0.89,1.00) -> (0.90,0.93,1.01): same rule, one notch brighter —
	// neutral slate in shade, not a blue cut-out.
	vec3 shade_tint = vec3(0.90, 0.93, 1.01);
	// Cooled and pulled back: at 1.10 warm a lit face went over 1.0 and ACES
	// returned it as cream — half the "sand dune" problem was the sun tint.
	// The other half is that air cools the light itself: a warm key scattered
	// over a kilometre arrives blue-shifted, so the lit tint walks toward cool
	// sky with the layer's haze. A warm sun tint reaching the mid rings
	// unspent is what the grade kept returning as cream card.
	// haze_v * 0.75 -> 1.35: at 0.75 the second ring still carried three
	// quarters of the warm tint, so every sun-facing face rearward of the
	// rider rendered as pale tan — the washed "grey" that was actually cream.
	// Now the tint is spent by the second ring and the far faces go cool-slate,
	// which is the aerial step the reviewer keeps asking for. The near ring
	// keeps its warm kiss: five percent of the climb is barely moved.
	vec3 sun_tint = mix(key_tint, vec3(0.80, 0.88, 1.06), clamp(haze_v * 1.35, 0.0, 0.92));
	vec3 col = rock * lum * mix(shade_tint, sun_tint, lit);
	// Ambient, on both sides of the terminator.
	//
	// At dusk the sky is the brightest thing in the frame, so a face turned away
	// from a low sun is lit *almost entirely* by it. Gating this term on `lit`
	// left the shaded side with nothing but the 0.40 luminance floor, which is
	// what put a hard black-blue spike in front of the hazed ranges at the
	// mountain overlook: one steep backlit peak, correctly shaped, reading as a
	// hole cut in the picture. The shade side now collects skylight, weighted to
	// how much sky it actually faces — and enough of it that the near ring's
	// shaded panels hold a readable navy instead of crushing to black.
	// Skylight is the shade light. The ring's faces are mostly walls, and a
	// dome-squared term gave a wall almost nothing — shaded panels crushed to
	// navy while their lit neighbours stayed readable. The linear dome term
	// reaches a vertical face properly, and the same term is handed to the
	// woods below so the forested foot lifts with the rock instead of staying
	// a black band under it.
	vec3 amb = haze_color * (0.006 + 0.012 * dome) * mix(0.45, 1.0, lit)
		+ sky_color * (dome * 0.14 + 0.04) * (1.0 - lit);
	col += amb;

	// Treeline, ragged, by height alone. Gating it on the facet normal switched
	// whole kilometre-wide quads on and off and left hard green rectangles in
	// the middle of the skyline.
	float ragged = (couloir - 0.5) * 90.0 + (grit_v - 0.5) * 30.0;
	float forest = 1.0 - smoothstep(treeline - 30.0, treeline + 30.0, band_v + ragged);
	vec3 woods = forest_color * mix(0.70, 1.05, lit) * (0.9 + 0.2 * dome) + amb * 0.75;
	forest *= 1.0 - steep * slope_rock;
	col = mix(col, woods, forest * 0.9);

	// Snow on the summits only. A fixed snowline in metres put the whole upper
	// half of the tall back layers under snow, and four white layers merged into
	// one pale wall. Relative to the layer's own top, only the planted heroes
	// reach it; the cols between them stay rock.
	// The farthest band only ever shows its summit band above the ranges in
	// front, and a fixed snowline puts that whole window under snow — the
	// tallest peak in the frame arrives as a blank pale sheet. Far ranges
	// hold snow on their tips alone so the visible face stays rock.
	float snow_edge = 0.64 + snow_bias + 0.16 * smoothstep(0.30, 0.70, haze_v)
		+ (relief - 0.5) * 0.22 - (rake - 0.5) * 0.08;
	float hold = smoothstep(0.05, 0.38, n.y);
	// The nearest ring is foothills: caps start on the ranges behind.
	hold *= smoothstep(0.1, 0.2, haze_v);
	float cap = smoothstep(snow_edge - 0.03, snow_edge + 0.05, lift_v) * hold;
	// Rock ribs cut through the snowfield down the couloirs.
	cap *= smoothstep(0.22, 0.46, couloir + (lift_v - snow_edge) * 1.4);
	float snow_amt = max(snow_v * hold, cap);
	// Held a step under white and only lightly warmed: a sunlit cap through the
	// filmic curve and the warm grade went to cream and spread beige over the
	// sun side of every range.
	// Held a step under white and barely warmed now: at 0.25 the haze-colour
	// blend carried enough of the warm horizon that sunlit caps returned
	// cream through the grade — the same "cream card" as the rock under it.
	// Sunlit snow is scattered skylight more than it is horizon warmth.
	vec3 snow_lit = mix(snow_color, snow_color * haze_color * 1.3, 0.08) * 0.93;
	vec3 snow_shade = snow_color * vec3(0.56, 0.66, 0.88) * 0.78 + sky_color * 0.08;
	col = mix(col, mix(snow_shade, snow_lit, lit), snow_amt);

	// Valley mist lying at the foot of each layer, so every ridgeline stands
	// out of the one in front of it.
	float foot = 1.0 - smoothstep(-140.0, 60.0, band_v);
	col = mix(col, mist_color, foot * foot * mist_strength * (0.3 + 0.6 * haze_v));
	// Aerial perspective is the depth cue. Each layer steps most of the way to
	// the air behind it, snow included — an unhazed cap on the farthest range
	// glowed brighter than the near one and flattened the stack.
	//
	// Weighted towards the mist, not the halfway point. The two candidates sit
	// only a few degrees apart in hue and at nearly identical saturation, so a
	// 0.5 mix did not average them into neutral — it averaged one chroma into
	// two, landing the far ranges on a hue that was neither sky nor ground and
	// therefore matched neither. That is what a mountain range looks like when
	// it is mud. At 0.25 the aerial target stays the cool near-side air, so the
	// haze reads as distance rather than as a third colour in the frame.
	// Air is light scattered off the path between eye and ridge, and scattered
	// light is sky's colour, not ground's: cool and blue-shifted. The earlier
	// mist-heavy mix sat nearly on top of the pale horizon hue, and at the far
	// layer's haze weight the range arrived as a bleached white card — the
	// "whited-out mountains" complaint. Cool the target and hold the mix down
	// so even the back range keeps over half its own colour: distance should
	// read as a blue step, not as erasure.
	// Air is blue-shifted and darker than the sky itself: scattered light on a
	// kilometre of path cools a range, it does not bleach it. The old target sat
	// near the horizon colour's own lightness, so the heaviest haze band — the
	// tallest, farthest range — arrived as a flat pale-grey sheet instead of a
	// blue mountain.
	// The grade is a per-channel warm curve: it lifts red and holds blue back
	// through the whole mid band, so any *unsaturated* pale colour lands as
	// cream card no matter its value. A far range therefore has to arrive
	// saturated — violet-blue deep enough that its red channel never reaches
	// the warm part of the curve. The multiplier carries that hue.
	//
	// The mix leans on the sky anchor (which is now the mood's mid-band blue,
	// not a grey next to the horizon) and the whole target sits a step darker
	// than before: a ridge veiled by air should read *bluer*, not paler —
	// real airlight never out-brightens the face it hides.
	vec3 air = mix(mist_color, sky_color, 0.62);
	air = mix(air, haze_color, 0.04) * 0.92;
	// A linear haze weight is fine up to the third range, but at the fourth's
	// 0.66 it erased almost half the mountain's own colour — which is where the
	// biggest silhouette in the frame lived, and it arrived as a flat pale
	// sheet. Compressing the top of the ladder keeps the far range a step
	// bluer than the one in front without whitewashing it. The 2h-h² curve
	// reaches the middle bands properly: at a third air the warm rock and the
	// blue veil meet at olive, which is worse than either.
	// The floor matters as much as the shape: the near band's own haze is
	// almost nothing, and unhazed it kept the warm rock that the grade
	// returns as one tan mountain standing among blue ones. Even the closest
	// range sits inside a kilometre and a half of air.
	float haze_w = clamp(
		0.03 + haze_v * 0.55 * (1.0 - 0.2 * haze_v) + weather_haze * (0.45 + haze_v),
		0.0, 0.55
	);
	// Air dims as well as veils: a kilometre of path eats the key light before
	// it scatters it back, so a range never ends up brighter than its own foot.
	// Without this the lit faces of the mid rings sat above 0.5, where the
	// grade's warm highlights returned every slate-blue panel as cream card.
	// Kept shallow: the far band has to stay *lighter* than the mid one for
	// the depth ladder to read, so the path eats a fifth, not a third.
	col *= 1.0 - 0.14 * haze_v;
	// ...and it cools what is left of it. The warm key is scattered out of the
	// light long before the light is gone, so the residual rock colour shifts
	// blue with distance on top of the veil the mix lays over it.
	col *= mix(vec3(1.0), vec3(0.90, 0.95, 1.04), haze_v);
	// The air takes the facet's own light with it. Mixing toward one flat air
	// colour collapses the lit/shade split as the weight climbs, and at the
	// far band that is the whole of the mountain's form — the silhouette stays
	// but the range behind it turns into a decal. Scaling the target by the
	// same `lit` the rock used keeps the far range's two-sided read at a third
	// of its near contrast, which is what aerial perspective actually does.
	// The floor is not symmetric: a shaded far face is lit by the sky itself,
	// not by nothing, so its air only falls to four-fifths — a shaded band
	// that went to near-black was the "navy cut-out" complaint all over again.
	// (0.88,1.04) -> (0.80,1.10): at a third of a veil the old spread left the
	// far range eight percent of lit/shade difference — a flat pale card
	// rearward of the rider. Fourteen percent keeps the tallest band's two
	// faces legible through the air.
	col = mix(col, air * mix(0.80, 1.10, lit), haze_w);
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
	col = mix(col, air, side * 0.0);
	// Grade compensation. The film grade lifts red ~30% and holds blue down
	// through the whole midtone band — measured: a neutral-warm 0.45 face
	// comes back as (0.80,0.72,0.53), which is why every slate rock the shader
	// produced returned as a tan dune. The range is only slate on screen if it
	// *arrives* blue enough to survive that warp, so the last step undoes the
	// midtone split for this material alone: red down, blue up, green held.
	// Weighted to the mids — the deep shades are already cooled by the grade's
	// lifted lavender toe and need no help (pushing blue there is exactly the
	// "navy cut-out" complaint), and a bright cap under it stays sunlit snow.
	// The forest band keeps most of its green: at full correction the woods
	// swung from olive to cyan, which reads as painted water, not woodland.
	float cl = dot(col, vec3(0.2126, 0.7152, 0.0722));
	float cw = smoothstep(0.10, 0.50, cl) * (1.0 - forest * 0.7);
	vec3 comp = mix(vec3(1.0), vec3(0.85, 0.97, 1.38), cw);
	ALBEDO = col * comp;
}
