shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

// Fireflies, and the balloon burners. Unshaded colour over the glow threshold
// blooms on its own, so a speck a few pixels across still reads as a light.
// Added, not painted: between flashes a firefly is nothing at all, not a dark
// bead hanging in the air. INSTANCE_CUSTOM.x is the blink phase and .y the blink rate, so no two flash
// together; .z scales brightness, which is how the burner flickers.

uniform vec3 glow_color : source_color = vec3(0.95, 1.0, 0.45);
uniform float energy = 3.2;
uniform float blink = 1.0;

varying float brightness;

void vertex() {
	// Per-instance data only exists in vertex(); the pulse is worked out here.
	float rate = 0.6 + INSTANCE_CUSTOM.y * 1.8;
	float wave = sin(TIME * rate + INSTANCE_CUSTOM.x * 6.2831853);
	// Mostly dim with a short bright pulse: a firefly is a flash, not a lamp.
	float pulse = mix(1.0, 0.04 + 0.96 * pow(max(wave, 0.0), 3.0), blink);
	brightness = pulse * max(INSTANCE_CUSTOM.z, 0.0);
}

void fragment() {
	ALBEDO = glow_color * energy * brightness;
}
