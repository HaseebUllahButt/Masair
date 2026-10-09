shader_type spatial;

// The roadside ground: verge, banks and open fields out to the fog.
//
// Same vertex-colour material as LowPoly.terrain_material() — matte Lambert,
// no specular — plus the one thing a flat field needs to feel alive: light
// bands rolling across it on the same gust field the foliage sways to. Wind
// over standing corn reads as moving light long before it reads as moving
// geometry, and geometry is exactly what the coarse ribbon does not have
// enough of to wave.
//
// The bands fade with distance: past a few hundred metres the field is inside
// fog and a shimmer there would only sparkle against the haze.

#include "res://shaders/wind.gdshaderinc"

// Brightness swing of the rolling bands at their strongest. Kept low enough
// that a hillside under cloud-shadow reads as weather, not a zebra.
uniform float band_strength : hint_range(0.0, 0.5) = 0.13;
// The bands' reach: full strength inside this fraction, gone by band_fade.
uniform float band_fade = 260.0;
// A second, broader drift of sun-and-shadow — cloud light rather than gust
// front, so the ground breathes even between fronts.
uniform float drift_strength : hint_range(0.0, 0.3) = 0.06;

varying vec3 world_pos;
varying float view_dist;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	view_dist = distance(world_pos, CAMERA_POSITION_WORLD);
}

// sRGB decode for hex-authored vertex colour — the same decode the road and
// foliage shaders carry; see LowPoly._srgb().
vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	vec3 albedo = OUTPUT_IS_SRGB ? COLOR.rgb : to_linear(COLOR.rgb);
	float fade = 1.0 - smoothstep(band_fade * 0.45, band_fade, view_dist);
	if (fade > 0.001) {
		// The travelling gust front, sharpened so it reads as a bright band
		// racing the field rather than a slow gradient breathing.
		float front = sin(dot(world_pos.xz, WIND_DIR) * 0.085 - TIME * 0.75) * 0.5 + 0.5;
		float band = front * front * front;
		// Gust strength gates the band: the silvering arrives with the wind
		// that carries it instead of marching in lockstep everywhere.
		float gust = wind_gust(world_pos.xz, TIME);
		float light = band * mix(0.35, 1.0, gust);
		// Broad cloud drift, out of phase with the front so the two patterns
		// cross rather than doubling into one stronger stripe.
		float drift = sin(dot(world_pos.xz, WIND_CROSS) * 0.017 - TIME * 0.26) * 0.5 + 0.5;
		albedo *= 1.0 + (light * band_strength + drift * drift_strength - band_strength * 0.5 - drift_strength * 0.5) * fade;
	}
	ALBEDO = albedo;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	METALLIC = 0.0;
}
