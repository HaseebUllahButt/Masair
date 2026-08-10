shader_type canvas_item;
render_mode unshaded;

// Final pass over the tonemapped, colour-corrected image.
//
// Everything here is the part of a "graded" look that an Environment cannot do:
// falloff toward the corners, a little dirt in the signal, and a warm/cool split
// that acts on screen position rather than on luminance. Small effects, but they
// are the difference between an engine render and a photographed one, and on a
// world built from flat colour they carry more than they would over texture.

uniform sampler2D screen : hint_screen_texture, filter_linear, repeat_disable;

// How dark the corners go. Kept modest: a heavy vignette on a first-person view
// reads as a helmet, which this game does not have.
uniform float vignette : hint_range(0.0, 1.0) = 0.30;
// Where the falloff starts, as a fraction of the half-diagonal.
uniform float vignette_start : hint_range(0.1, 1.0) = 0.52;
// Per-pixel noise. At this amplitude it is invisible as grain and works as
// dithering: flat-coloured sky and ground are exactly where 8-bit output bands,
// and the bands are the most obvious cheap-render tell in the whole frame.
uniform float grain : hint_range(0.0, 0.1) = 0.010;
uniform float seed = 0.0;
// Warm the centre, cool the edges. This is the light falling off round a lens
// rather than a colour choice, and it stops the vignette reading as a grey mask
// dropped over the corners.
uniform float split_tone : hint_range(0.0, 0.5) = 0.055;
uniform vec3 warm : source_color = vec3(1.00, 0.94, 0.82);
uniform vec3 cool : source_color = vec3(0.80, 0.88, 1.00);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec3 c = texture(screen, SCREEN_UV).rgb;

	// Squash the y term: on a 16:9 frame a circular falloff darkens the top and
	// bottom of the road long before it reaches the corners.
	vec2 p = (SCREEN_UV - 0.5) * vec2(1.0, 0.82);
	float r = length(p) / 0.5;
	float edge = smoothstep(vignette_start, 1.05, r);

	c *= mix(warm, cool, edge * 0.85) * (1.0 + split_tone) - split_tone;
	c *= 1.0 - edge * vignette;

	c += (hash(SCREEN_UV * vec2(1279.0, 721.0) + seed) - 0.5) * grain;

	COLOR = vec4(max(c, vec3(0.0)), 1.0);
}
