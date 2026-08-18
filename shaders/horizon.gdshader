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

varying vec3 world_n;
varying float snow_v;
varying float grit_v;
varying float lift_v;
varying float haze_v;
varying float band_v;

varying vec3 world_p;
varying float along_v;

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
	vec3 sun = normalize(sun_dir);
	float key = clamp(dot(n, sun) * 0.5 + 0.5, 0.0, 1.0);
	float dome = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 across = normalize(cross(sun, vec3(0.0, 1.0, 0.0)) + vec3(1e-4));
	float rake = clamp(dot(n, across) * 0.5 + 0.5, 0.0, 1.0);

	// Bedding planes. Long period and low amplitude: a hint that the rock is
	// layered, not contour stripes painted round the hill. Driven by height
	// alone — folding the per-facet tone in here only added to the flutes.
	float strata = 0.5 + 0.5 * sin(band_v * 0.031);
	float grain = 0.5 + 0.5 * sin(along_v * 0.045) * sin(band_v * 0.078 + grit_v * 9.0);

	vec3 rock = mix(foot_color, crest_color, lift_v);

	// Floor is high enough that a backlit night face still has a slope, not a
	// hole. Dome carries most of the form when the key is behind the range.
	float lum = 0.18 + 0.46 * key + 0.28 * key * key;
	lum += 0.28 * dome * dome;
	lum *= mix(0.88, 1.12, rake);
	lum *= mix(0.86, 1.14, grit_v);
	lum *= mix(0.92, 1.08, strata);
	lum *= mix(0.90, 1.10, grain);
	lum = mix(lum, 0.52, haze_v * 0.36);

	vec3 col = rock * lum;
	col = mix(col * vec3(0.74, 0.81, 1.04), col, key);
	col += sky_color * (0.12 * dome * dome * (1.0 - key * 0.65));
	vec3 snow_col = snow_color * mix(0.78, 1.12, key);
	col = mix(col, snow_col, snow_v);
	col = mix(col, haze_color, haze_v * 0.30 * (1.0 - snow_v));
	// Soften the ring into the air at the extreme edges of a wide lens, but
	// keep the mountains when the rider looks aside — the old 0.55 mix turned
	// a 60° glance into a dark slab of haze.
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
	col = mix(col, haze_color, side * mix(0.22, 0.10, snow_v));
	ALBEDO = col;
}
