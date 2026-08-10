shader_type spatial;

// Tarmac.
//
// The road is the largest surface in every frame, and it used to be one flat
// vertex colour — the reason the old screenshots read as a ribbon of paper.
//
// Deliberately restrained. No cracks, patches or grime maps: this is a
// flat-shaded low-poly game, and detailed asphalt next to a ten-triangle tree
// just looks borrowed. A faint grain so the surface is not mathematically flat,
// and wheel tracks a shade darker than the rest of the lane.
//
// The tarmac stays matte on purpose. Giving the wheel tracks a lower roughness
// was physically reasonable and looked terrible: a low sun turned each polished
// strip into a hard light shaft running the length of the road.
//
// UV.x is lateral metres from the centreline, UV.y is metres travelled, so both
// stay put however the ribbon curves or climbs.

uniform float lane_width = 5.333;
uniform float half_width = 8.0;
// Two burnished strips per lane, where tyres have polished the aggregate.
uniform float track_offset = 0.85;
uniform float track_width = 0.70;
uniform float track_darkening : hint_range(0.0, 1.0) = 0.08;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.85;
uniform float grain_strength : hint_range(0.0, 1.0) = 0.045;
// 0 dry, 1 in the middle of a squall. Driven from the weather in main.gd.
//
// Wet tarmac is the one case where the polished wheel tracks are allowed to be
// specular. Dry, a low sun turned each strip into a hard shaft running the whole
// length of the road and it was reverted; standing water in the ruts is exactly
// what a real road does with a low sun, so the effect the dry surface could not
// justify is the effect the wet one is for.
uniform float wet : hint_range(0.0, 1.0) = 0.0;


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


// sRGB decode for hex-authored vertex colour. The StandardMaterial3D channels
// get this from vertex_color_is_srgb; a ShaderMaterial has to do it by hand, and
// this engine version has no srgb_to_linear() builtin to borrow.
vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
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


void fragment() {
	float lateral = UV.x;
	float along = UV.y;

	// Distance from the nearest lane centre, then a strip either side of it.
	float lane_phase = abs(fract(lateral / lane_width + 0.5) - 0.5) * lane_width;
	float track = 1.0 - smoothstep(0.0, track_width, abs(lane_phase - track_offset));
	// Fade out where the road stops being driven on.
	track *= 1.0 - smoothstep(half_width - 1.8, half_width - 0.3, abs(lateral));

	// Aggregate, stretched along the direction of travel so it does not shimmer
	// into moire at speed.
	float grain = vnoise(vec2(lateral * 18.0, along * 6.0)) - 0.5;

	// Water darkens tarmac and fills the ruts first, so the tracks go from
	// slightly darker than the lane to a great deal darker.
	float soaked = wet * (0.55 + track * 0.45);
	// Authored as a hex colour and delivered as a vertex colour, so it needs the
	// same sRGB decode the StandardMaterial3D channels get — see LowPoly._srgb().
	// Without it "3b3b3d" tarmac is a 0.231 linear mid grey and the road is the
	// brightest large surface in the frame instead of the darkest.
	ALBEDO = to_linear(COLOR.rgb)
		* (1.0 + grain * grain_strength * (1.0 - wet * 0.7))
		* (1.0 - track * track_darkening)
		* (1.0 - soaked * 0.55);
	METALLIC = 0.0;
	// Dry: no specular at all. The road is broad and nearly flat, so any
	// highlight on it becomes a shaft pointing straight at the camera. Wet: that
	// shaft is the point, and it is strongest where the water pools.
	//
	// 0.30, not a mirror finish. Taken much lower the road reflects the overcast
	// sky evenly enough to come out *brighter* than dry tarmac, the lane markings
	// stop reading, and the bike's own headlight burns a hard white hole in the
	// road two metres ahead of the wheel.
	ROUGHNESS = mix(base_roughness, 0.30, soaked);
	SPECULAR = soaked * 0.45;
}
