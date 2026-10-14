shader_type canvas_item;
render_mode unshaded;

// Final pass over the tonemapped, colour-corrected image.
//
// Everything here is the part of a "graded" look that an Environment cannot do:
// falloff toward the corners, a little dirt in the signal, a warm/cool split
// by both screen position and luminance, and a whisper of defocus at the frame
// edge. Small effects, but they are the difference between an engine render and
// a photographed one, and on a world built from flat colour they carry more
// than they would over texture.

uniform sampler2D screen : hint_screen_texture, filter_linear, repeat_disable;

// How dark the corners go. Kept modest: a heavy vignette on a first-person view
// reads as a helmet, which this game does not have.
uniform float vignette : hint_range(0.0, 1.0) = 0.34;
// Where the falloff starts, as a fraction of the half-diagonal.
uniform float vignette_start : hint_range(0.1, 1.0) = 0.50;
// Per-pixel noise. At this amplitude it is invisible as grain and works as
// dithering: flat-coloured sky and ground are exactly where 8-bit output bands,
// and the bands are the most obvious cheap-render tell in the whole frame.
uniform float grain : hint_range(0.0, 0.1) = 0.014;
uniform float seed = 0.0;
// Warm the centre, cool the edges. This is the light falling off round a lens
// rather than a colour choice, and it stops the vignette reading as a grey mask
// dropped over the corners.
uniform float split_tone : hint_range(0.0, 0.5) = 0.065;
uniform vec3 warm : source_color = vec3(1.02, 0.94, 0.80);
uniform vec3 cool : source_color = vec3(0.85, 0.90, 1.00);
// Film never reaches black. After ACES and the contrast adjustment every
// backlit tree and the whole road clipped to 0, and a clipped shadow has no
// colour and no depth. Lifting the toe toward a cool lavender keeps the darkest
// pixels as shadow rather than hole — the single thing a flat-shaded frame
// needs most to look lit instead of cut out.
uniform float toe_lift : hint_range(0.0, 0.1) = 0.042;
uniform vec3 shadow_tint : source_color = vec3(0.52, 0.57, 0.76);
// The pastel split: apricot in the lights, lavender-teal in the darks, blended
// by luminance rather than screen position. It is what keeps a sunny frame
// warm where the sun lands and cool where it does not, which is most of the
// "dreamy" in a frame that would otherwise be one flat exposure.
uniform float lum_split : hint_range(0.0, 0.3) = 0.12;
uniform vec3 light_tint : source_color = vec3(1.06, 0.99, 0.88);
uniform vec3 dark_tint : source_color = vec3(0.93, 0.94, 1.00);
// Lens softness at the frame edge — the tilt-shift feel. The centre of the
// road stays optically sharp; only the last band of the frame drifts.
// Off. The blur sat exactly where the rider glances to see the ranges beside
// the road, and a defocused mountain reads as fog, not as distance.
uniform float edge_softness : hint_range(0.0, 1.0) = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 px = 1.0 / vec2(textureSize(screen, 0));

	// Squash the y term: on a 16:9 frame a circular falloff darkens the top and
	// bottom of the road long before it reaches the corners.
	vec2 p = (SCREEN_UV - 0.5) * vec2(1.0, 0.82);
	float r = length(p) / 0.5;
	float edge = smoothstep(vignette_start, 1.05, r);

	vec3 c = texture(screen, SCREEN_UV).rgb;

	// Edge defocus: a four-tap cross a little over a pixel wide, faded in with
	// the square of the vignette so the road ahead never loses its line.
	float soft = edge * edge * edge_softness;
	if (soft > 0.001) {
		vec2 blur = px * 1.6 * soft;
		vec3 soft_c = texture(screen, SCREEN_UV + vec2(blur.x, 0.0)).rgb
			+ texture(screen, SCREEN_UV - vec2(blur.x, 0.0)).rgb
			+ texture(screen, SCREEN_UV + vec2(0.0, blur.y)).rgb
			+ texture(screen, SCREEN_UV - vec2(0.0, blur.y)).rgb;
		c = mix(c, soft_c * 0.25, soft * 0.55);
	}

	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float toe = 1.0 - smoothstep(0.0, 0.22, lum);
	c += shadow_tint * toe * toe * toe_lift;

	// Blue lead protection. Both split-tones below buy their warmth by taking
	// the blue channel down against green — on sky and water, which arrive
	// already blue-dominant, that trade turns a clear blue into mint. Where
	// blue leads, apply each tint as a luminance-only multiplier so the frame
	// keeps its exposure shaping while the hue stays put. Warm pixels (clouds,
	// fields, the sunset itself) are unaffected: they get the full tints.
	float blue_lead = clamp((c.b - max(c.r, c.g)) * 6.0, 0.0, 1.0);

	// Luminance split-tone: dusk-pastel shadows, warm-cream highlights.
	vec3 lum_tint = mix(dark_tint, light_tint, smoothstep(0.06, 0.62, lum)) * (1.0 + lum_split) - lum_split;
	c *= mix(lum_tint, vec3(dot(lum_tint, vec3(0.2126, 0.7152, 0.0722))), blue_lead);

	vec3 pos_tint = mix(warm, cool, edge * 0.55) * (1.0 + split_tone) - split_tone;
	c *= mix(pos_tint, vec3(dot(pos_tint, vec3(0.2126, 0.7152, 0.0722))), blue_lead);
	c *= 1.0 - edge * vignette;

	c += (hash(SCREEN_UV * vec2(1279.0, 721.0) + seed) - 0.5) * grain;

	COLOR = vec4(max(c, vec3(0.0)), 1.0);
}
