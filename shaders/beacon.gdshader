shader_type spatial;
render_mode unshaded, shadows_disabled;

// Aircraft warning light on a mast.
//
// Blinks off TIME rather than a script, so a beacon costs nothing per frame and
// there is no node to tick. Every beacon in the world shares this material and
// therefore flashes together — which is what real ones on the same airfield do.

uniform vec3 beacon_color : source_color = vec3(3.0, 0.28, 0.18);
uniform float period = 2.6;
uniform float duty : hint_range(0.02, 0.9) = 0.16;

void fragment() {
	float phase = fract(TIME / period);
	// Soft edges: a hard step pops, and at distance the light is a couple of
	// pixels where an instant on/off just looks like flicker.
	float on = smoothstep(0.0, 0.05, phase) * (1.0 - smoothstep(duty, duty + 0.10, phase));
	ALBEDO = beacon_color * (0.06 + 0.94 * on);
}
