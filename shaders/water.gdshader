shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform float wave_height = 0.18;
uniform float wave_speed = 0.72;

varying vec3 world_position;

float water_height(vec2 p, float t) {
	float broad = sin(dot(p, normalize(vec2(0.82, 0.57))) * 0.055 + t * 0.55) * 0.48;
	float crosswave = sin(dot(p, normalize(vec2(-0.38, 0.92))) * 0.105 - t * 0.78) * 0.30;
	float ripple = sin(dot(p, normalize(vec2(0.97, -0.24))) * 0.215 + t * 1.18) * 0.16;
	return (broad + crosswave + ripple) * wave_height;
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += water_height(world.xz, TIME * wave_speed);
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * wave_speed;
	float step_size = 0.32;
	float center = water_height(world_position.xz, t);
	float right = water_height(world_position.xz + vec2(step_size, 0.0), t);
	float forward = water_height(world_position.xz + vec2(0.0, step_size), t);
	vec3 world_normal = normalize(vec3((center - right) / step_size, 1.0, (center - forward) / step_size));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 4.0);
	float shimmer = 0.5 + 0.5 * sin(world_position.x * 0.42 + world_position.z * 0.16 + t * 1.4);
	vec3 water_color = COLOR.rgb * vec3(0.54, 0.84, 1.08);
	ALBEDO = water_color + vec3(0.018, 0.035, 0.045) * fresnel + vec3(0.012, 0.020, 0.022) * shimmer;
	METALLIC = 0.12;
	ROUGHNESS = mix(0.16, 0.055, fresnel);
	SPECULAR = 0.92;
}

// The sun path.
//
// A lake at a viewpoint is the largest single surface in the frame, and without
// a path of light on it there is nothing to look at and nothing to say where the
// sun is: it reads as a sheet of coloured glass laid in the valley. Painting one
// into the vertex colour was tried and cannot work — it has to sit on the line
// between the viewer and the sun, and that line moves with the head and with the
// time of day, neither of which a baked mesh knows.
//
// Taking over light() means owning the diffuse term too, which is fine: water is
// almost all specular anyway, and a lake wants far less diffuse than a Lambert
// surface would give it.
void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * ndl * 0.42;
	// Deliberately broad. A tight lobe on a near-flat sheet is a single hot dot
	// on the horizon; real glitter is thousands of small facets each catching the
	// sun at a slightly different angle, and the wave normals above are standing
	// in for those facets. A low exponent is what spreads it into a path running
	// back toward the viewer instead of a spot sitting on the far shore.
	vec3 half_vector = normalize(LIGHT + VIEW);
	float spec = pow(max(dot(NORMAL, half_vector), 0.0), 22.0);
	// Grazing angles catch far more of it, which is what makes the path widen and
	// brighten as it runs away from the eye. Recomputed here rather than handed
	// over from fragment(): a varying written in fragment() and read in light()
	// is not something to rely on, and this is two instructions.
	float glance = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	float sparkle = 0.5 + 0.5 * sin(
		world_position.x * 0.42 + world_position.z * 0.16 + TIME * wave_speed * 1.4
	);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * spec * mix(1.0, 3.4, glance) * (0.55 + 0.75 * sparkle);
}
