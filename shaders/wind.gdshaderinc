// One wind for the whole world.
//
// Foliage sway, the light bands running over the fields and the lake's swell
// all read from this same gust field, so a gust that bends the hedge is the
// same gust the rider watches crossing the corn. Two wavefronts at different
// wavelengths and headings are summed so the gust lines wander and interfere
// instead of marching past as parallel stripes.
//
// Returns ~[0, 1]: lull to gust. The first front is the readable one —
// ~75 m crests travelling near 9 m/s, which is the scale at which wind is
// actually seen moving over a field from the saddle.

const vec2 WIND_DIR = vec2(0.8192, 0.5736); // normalised (1.0, 0.7)
const vec2 WIND_CROSS = vec2(-0.3318, 0.9434); // mostly across the first front

float wind_gust(vec2 world_xz, float t) {
	float front = sin(dot(world_xz, WIND_DIR) * 0.085 - t * 0.75);
	float broad = sin(dot(world_xz, WIND_CROSS) * 0.031 - t * 0.42);
	return clamp(0.52 + 0.30 * front + 0.22 * broad, 0.0, 1.0);
}
