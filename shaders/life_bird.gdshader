shader_type spatial;
render_mode cull_disabled, specular_disabled;

// Birds over the overlooks. A flock is one MultiMesh, so the wingbeat lives
// here instead of in a skeleton. Per bird, in INSTANCE_CUSTOM:
//   x  phase of the beat, 0..1, so a flock never flaps in unison
//   y  how much of a beat: 0 glides, 1 is full flapping flight
//   z  beat rate in radians per second, divided by 40 to stay inside 0..1
//   w  wing fold: 0 open, 1 tucked for a stoop
// The instance colour is the bird's colour.

uniform float beat_amp = 0.62;

void vertex() {
	float ax = abs(VERTEX.x);
	float fold = INSTANCE_CUSTOM.w;
	// A stooping raptor pulls its wings in and back into a dart.
	VERTEX.x *= 1.0 - fold * 0.58;
	VERTEX.z += fold * ax * 0.55;
	float beat = sin(TIME * INSTANCE_CUSTOM.z * 40.0 + INSTANCE_CUSTOM.x * 6.2831853);
	float flap = INSTANCE_CUSTOM.y * (1.0 - fold);
	// Curved, not hinged: the tip travels further than the elbow, which is the
	// difference between a wing and a pair of paddles.
	VERTEX.y += beat * flap * beat_amp * (ax * 0.55 + ax * ax * 1.1);
	// Held in a shallow V while gliding. At a few pixels across that dihedral
	// is what reads as a bird rather than as a plus sign.
	VERTEX.y += ax * 0.16 * (1.0 - flap) * (1.0 - fold);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.9;
}
