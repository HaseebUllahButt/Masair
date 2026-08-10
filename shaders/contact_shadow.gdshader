shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// One soft contact patch replaces four cascaded shadow-map renders per car.
// The nested ellipses keep the centre grounded without exposing a hard quad edge.
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float radius = dot(p, p);
	float soft = 1.0 - smoothstep(0.18, 1.0, radius);
	float core = 1.0 - smoothstep(0.0, 0.46, radius);
	ALBEDO = vec3(0.025, 0.030, 0.040);
	ALPHA = soft * 0.38 + core * 0.16;
}
