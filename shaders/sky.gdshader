shader_type sky;
render_mode use_debanding;

// Masair sky.
//
// Replaces ProceduralSkyMaterial, which could only give a vertical two-stop
// ramp — the reason every old screenshot had an empty upper half. Everything
// here is analytic: a three-stop gradient, one celestial body (sun by day,
// moon at night, same uniforms), two layers of drifting cloud, and stars.
//
// The cloud plane is projected off EYEDIR rather than raymarched, so the whole
// sky is a handful of noise taps. The radiance cubemap runs the same code, so
// clouds and sunset colour also light the world through ambient — that link is
// what keeps the ground colour and the sky agreeing when the mood changes.

group_uniforms gradient;
// Three stops, not two. A sunset is hot orange at the skyline, a wide pink /
// salmon band above it, then violet into deep blue — the pink band is the part
// that actually reads as dusk, and a two-stop ramp cannot produce it.
uniform vec3 zenith_color : source_color = vec3(0.10, 0.09, 0.28);
uniform vec3 mid_color : source_color = vec3(0.78, 0.42, 0.55);
uniform vec3 horizon_color : source_color = vec3(1.00, 0.52, 0.34);
uniform vec3 ground_color : source_color = vec3(0.11, 0.10, 0.17);
// Heights (in EYEDIR.y) where the mid band peaks and where zenith takes over.
uniform float band_low : hint_range(0.01, 0.6) = 0.12;
uniform float band_high : hint_range(0.05, 1.5) = 0.62;
uniform float horizon_glow : hint_range(0.0, 3.0) = 0.55;
uniform float energy : hint_range(0.0, 3.0) = 1.0;

group_uniforms celestial;
uniform vec3 sun_color : source_color = vec3(1.0, 0.72, 0.42);
// Angular radius in radians. The real sun is 0.0047; a stylised game wants a
// disc you can actually see, and at dusk a big low sun is the whole picture.
uniform float sun_radius : hint_range(0.0, 0.3) = 0.035;
uniform float sun_halo : hint_range(0.0, 4.0) = 0.9;
// 0 hides the body entirely while the light keeps shining — an after-sunset sky
// has no disc in it, only the glow the sun left behind.
uniform float sun_disc : hint_range(0.0, 1.0) = 1.0;
uniform float sun_halo_falloff : hint_range(1.0, 60.0) = 9.0;
// 0 = plain bright disc, 1 = limb darkening plus maria. Same body either way.
uniform float moon_face : hint_range(0.0, 1.0) = 0.0;

group_uniforms clouds;
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.83, 0.75);
uniform vec3 cloud_dark : source_color = vec3(0.35, 0.28, 0.44);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_sharpness : hint_range(0.05, 1.0) = 0.34;
uniform float cloud_scale : hint_range(0.2, 8.0) = 1.7;
uniform float cloud_speed = 0.004;
uniform float cloud_opacity : hint_range(0.0, 1.0) = 1.0;
// Static phase by design. TIME here forces Godot to rebuild the sky radiance
// cubemap every frame; that was the repeating cloud hitch on integrated GPUs.
uniform float sky_phase = 37.0;

group_uniforms cloud_bank;
// A second deck, far away and low down. The main deck is weather overhead: you
// see its underside, and looking down the road there is nothing underneath to
// see, which is why the forward sky used to be a bare ramp with a few wisps at
// the very top of the frame. This one is projected much harder into the
// skyline, so it reads as cumulus thirty kilometres off rather than more of the
// same cloud.
uniform float bank_cover : hint_range(0.0, 1.0) = 0.5;
uniform float bank_opacity : hint_range(0.0, 1.0) = 0.0;
// How far up the bank reaches, in EYEDIR.y. Small: past a few degrees it stops
// being distant and starts being a second layer of overhead weather.
uniform float bank_height : hint_range(0.02, 0.5) = 0.14;
// How much of the horizon colour the bank takes on. Distance washes a cloud out
// toward the colour of the air in front of it; without this the bank sits on the
// skyline as a hard cut-out and destroys the depth it was added for.
uniform float bank_haze : hint_range(0.0, 1.0) = 0.55;

group_uniforms stars;
uniform float star_intensity : hint_range(0.0, 4.0) = 0.0;
uniform vec3 galaxy_color : source_color = vec3(0.42, 0.46, 0.72);
// Seconds between meteors. Long on purpose — a streak every few seconds reads
// as an effect on a loop rather than something you were lucky to catch.
uniform float meteor_period = 26.0;
// Pole of the great circle the galactic band runs along.
uniform vec3 galaxy_axis = vec3(0.46, 0.38, -0.80);

const mat2 ROT = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}


float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// Quintic interpolation keeps both the value and its slope continuous across
	// noise cells. The old cubic blend also used u.y for the first horizontal
	// interpolation below, which stretched whole cells into the square/triangular
	// shards visible in the sky.
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}


float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	for (int i = 0; i < octaves; i++) {
		sum += amp * vnoise(p);
		norm += amp;
		p = ROT * p * 2.04;
		amp *= 0.5;
	}
	return sum / norm;
}


// Flat cloud deck seen from below. Dividing by (y + bias) instead of y keeps the
// projection finite at the horizon, which reads as haze rather than a smeared
// singularity.
vec2 cloud_uv(vec3 dir) {
	return dir.xz / (max(dir.y, 0.0) + 0.14) * cloud_scale;
}


void sky() {
	int octaves = AT_CUBEMAP_PASS ? 2 : 5;
	float up = EYEDIR.y;

	// ── Base gradient ──────────────────────────────────────────────────────
	float h = max(up, 0.0);
	vec3 col = mix(horizon_color, mid_color, smoothstep(0.0, band_low, h));
	col = mix(col, zenith_color, smoothstep(band_low, band_high, h));
	// A tight band of extra light hugging the skyline. Real dusk is brightest in
	// the last few degrees above the ground, and it gives the road something to
	// vanish into.
	float skirt = pow(1.0 - min(abs(up) * 4.2, 1.0), 3.0);
	col += horizon_color * skirt * horizon_glow;
	col = mix(col, ground_color, smoothstep(0.0, -0.06, up));

	// ── Clouds ─────────────────────────────────────────────────────────────
	float cloud_alpha = 0.0;
	float cloud_thickness = 0.0;
	float cloud_shadow = 0.0;
	vec3 cloud_col = cloud_lit;
	vec3 bank_col = cloud_lit;
	vec2 uv = cloud_uv(EYEDIR);
	if (cloud_opacity > 0.001 && up > -0.02) {
		vec2 drift = vec2(sky_phase * cloud_speed, sky_phase * cloud_speed * 0.35);
		float density = fbm(uv + drift, octaves);
		// Second, larger and slower layer: without it the deck reads as one
		// repeating texture instead of weather.
		density = mix(density, fbm(uv * 0.42 - drift * 0.6, max(octaves - 1, 1)), 0.45);
		float edge = mix(0.02, 0.5, cloud_sharpness);
		float base = 1.0 - cloud_cover;
		cloud_alpha = smoothstep(base, base + edge, density);
		// How far past the cover threshold this pixel is — the deck's "depth".
		cloud_thickness = clamp((density - base) / max(edge, 1e-3), 0.0, 1.0);
		// Cheap self-shadowing: resample the deck one step toward the light. Where
		// there is more cloud between here and the sun, this pixel sits in shade.
		// It is what turns a flat stencil into something with a lit top and a
		// heavy underside.
		if (!AT_CUBEMAP_PASS && LIGHT0_ENABLED) {
			vec2 toward_sun = normalize(LIGHT0_DIRECTION.xz + vec2(1e-4)) * 0.55;
			float above = fbm(uv + toward_sun + drift, max(octaves - 2, 1));
			cloud_shadow = clamp((above - base) / max(edge, 1e-3), 0.0, 1.0);
		}
		// Thin the deck toward the horizon so it settles into haze. It used to stop
		// at 0.22 — around thirteen degrees — which is above the top of the frame
		// when you are looking down a road, so the deck was invisible while riding
		// and only showed up if you looked at the sky on purpose.
		cloud_alpha *= smoothstep(0.005, 0.11, up) * cloud_opacity;
	}

	// ── Distant cloud bank ─────────────────────────────────────────────────
	float bank_alpha = 0.0;
	float bank_thickness = 0.0;
	if (bank_opacity > 0.001 && up > 0.0 && up < bank_height * 1.2) {
		// A far smaller divisor than the main deck: features collapse into the
		// last couple of degrees above the skyline, which is what makes them read
		// as distance rather than as low cloud directly overhead.
		vec2 buv = EYEDIR.xz / (up + 0.030) * 2.4;
		// Squashed across the sky, so the bank piles up vertically the way a line
		// of cumulus on a horizon does instead of drifting as round blobs.
		buv.y *= 0.55;
		float density = fbm(buv + vec2(sky_phase * cloud_speed * 0.6, 0.0), AT_CUBEMAP_PASS ? 2 : 3);
		float base = 1.0 - bank_cover;
		bank_alpha = smoothstep(base, base + 0.20, density);
		bank_thickness = clamp((density - base) / 0.20, 0.0, 1.0);
		// Lift it off the skyline itself and fade the top out, so it is a band and
		// not a wall.
		bank_alpha *= smoothstep(0.0, 0.018, up);
		bank_alpha *= 1.0 - smoothstep(bank_height * 0.45, bank_height, up);
		bank_alpha *= bank_opacity;
	}

	// ── Sun / moon ─────────────────────────────────────────────────────────
	if (LIGHT0_ENABLED) {
		vec3 to_light = normalize(LIGHT0_DIRECTION);
		float ang = acos(clamp(dot(EYEDIR, to_light), -1.0, 1.0));
		float disc = (1.0 - smoothstep(sun_radius * 0.92, sun_radius * 1.06, ang)) * sun_disc;
		float halo = exp(-ang * sun_halo_falloff) * sun_halo;

		// Moon detail: limb darkening plus three maria, placed in a tangent frame
		// so they stay put as the camera turns.
		if (moon_face > 0.001 && disc > 0.0) {
			vec3 tx = normalize(cross(to_light, vec3(0.0, 1.0, 0.0)));
			vec3 ty = cross(tx, to_light);
			vec2 face = vec2(dot(EYEDIR, tx), dot(EYEDIR, ty)) / max(sun_radius, 1e-4);
			float r2 = clamp(dot(face, face), 0.0, 1.0);
			// Limb darkening, then broad maria. Wide and soft-edged: small hard
			// dots read as dirt on the lens, big smudges read as a moon.
			float shade = 0.80 + 0.20 * sqrt(1.0 - r2);
			shade -= 0.26 * (1.0 - smoothstep(0.10, 0.52, length(face - vec2(-0.26, 0.20))));
			shade -= 0.22 * (1.0 - smoothstep(0.08, 0.40, length(face - vec2(0.30, 0.34))));
			shade -= 0.20 * (1.0 - smoothstep(0.06, 0.34, length(face - vec2(0.16, -0.34))));
			shade -= 0.14 * (1.0 - smoothstep(0.05, 0.26, length(face - vec2(-0.40, -0.30))));
			// Craters: a sparse speckle that only shows up close to the limb.
			shade -= 0.10 * vnoise(face * 6.0) * smoothstep(0.2, 0.9, r2);
			disc *= mix(1.0, clamp(shade, 0.0, 1.0), moon_face);
		}

		// Sunward side of the deck catches the light; the self-shadow term darkens
		// whatever has cloud stacked between it and the sun.
		float facing = pow(max(dot(EYEDIR, to_light) * 0.5 + 0.5, 0.0), 3.0);
		float shade = clamp(1.0 - cloud_shadow * 0.85 - cloud_thickness * 0.35, 0.0, 1.0);
		cloud_col = mix(cloud_dark, cloud_lit, clamp(facing * 0.55 + shade * 0.65, 0.0, 1.0));
		// Rim: thin cloud edges near the sun go incandescent. This is the single
		// detail that makes a sunset deck look lit rather than painted.
		float rim = (1.0 - cloud_thickness) * facing;
		cloud_col += sun_color * (rim * 0.75 + halo * facing * 0.4);
		// The bank is lit the same way but far weaker, then washed toward the
		// horizon colour by the air in front of it.
		bank_col = mix(cloud_dark, cloud_lit, clamp(facing * 0.4 + (1.0 - bank_thickness * 0.5) * 0.7, 0.0, 1.0));
		bank_col += sun_color * (1.0 - bank_thickness) * facing * 0.4;
		bank_col = mix(bank_col, horizon_color, bank_haze);
		// 1.9, not 6: past roughly 2x the disc saturates every channel through ACES
		// and the sun turns into a white hole. Kept here it stays orange, and the
		// glow pass supplies the brightness instead.
		col += sun_color * (disc * 1.9 + halo) * (1.0 - cloud_alpha * 0.85) * (1.0 - bank_alpha * 0.7);
	} else {
		bank_col = mix(cloud_dark, horizon_color, bank_haze);
	}

	// ── Stars and galactic band ────────────────────────────────────────────
	if (star_intensity > 0.001 && !AT_CUBEMAP_PASS && up > 0.0) {
		float sky_open = smoothstep(0.02, 0.30, up) * (1.0 - cloud_alpha) * (1.0 - bank_alpha);
		// Cool airglow lifts the first few degrees above the dark horizon. It gives
		// the mountain silhouette a readable edge without making the ground bright.
		float airglow = smoothstep(0.0, 0.035, up) * (1.0 - smoothstep(0.06, 0.32, up));
		col += vec3(0.025, 0.11, 0.17) * airglow * min(star_intensity * 0.32, 0.65);

		// Dust band across the sky. Projected into the plane of the great circle
		// rather than into lat/long, so there is no seam to catch the eye.
		vec3 axis = normalize(galaxy_axis);
		vec3 gt = normalize(cross(axis, vec3(0.0, 1.0, 0.0)));
		vec2 guv = vec2(dot(EYEDIR, gt), dot(EYEDIR, cross(gt, axis))) * 3.2;
		float band = smoothstep(0.30, 0.0, abs(dot(EYEDIR, axis)));
		float dust = fbm(guv, 4);
		float milky = smoothstep(0.28, 0.78, dust);
		// Broad silver body, violet nebular knots, then a narrow dark dust lane.
		// All reuse the same noise sample, keeping the richer night essentially free.
		col += galaxy_color * band * milky * 0.38 * star_intensity * sky_open;
		col += vec3(0.34, 0.16, 0.42) * band * smoothstep(0.66, 0.91, dust) * 0.19 * star_intensity * sky_open;
		float dust_lane = smoothstep(0.075, 0.0, abs(dot(EYEDIR, axis))) * (1.0 - milky * 0.55);
		col *= 1.0 - dust_lane * 0.24 * sky_open;

		// Two star layers: a few coloured bright stars with a visible flare and a
		// finer field behind them. A third per-pixel hash layer cost real GPU time
		// while mostly turning into sub-pixel shimmer at riding resolution.
		for (int layer = 0; layer < 2; layer++) {
			float density = layer == 0 ? 110.0 : 300.0;
			float cut = layer == 0 ? 0.9835 : 0.9915;
			vec3 cell = EYEDIR * density;
			vec3 id3 = floor(cell);
			float id = hash13(id3);
			// The galactic band is crowded; everywhere else is not.
			if (id > cut - band * 0.006) {
				// Jitter within the cell, so the field is not on a visible lattice.
				vec3 offset = vec3(hash13(id3 + 11.0), hash13(id3 + 23.0), hash13(id3 + 37.0)) - 0.5;
				float d = length(fract(cell) - 0.5 - offset * 0.6);
				float twinkle = 0.72 + 0.28 * sin(id * 311.0);
				float mag = 0.35 + 0.65 * fract(id * 71.3);
				// Blue-white through to warm amber, weighted toward white.
				vec3 tint = mix(vec3(0.70, 0.80, 1.0), vec3(1.0, 0.84, 0.62), fract(id * 133.7));
				float size = layer == 0 ? 0.20 : 0.105;
				float star = smoothstep(size, 0.01, d);
				// Brightest layer gets a soft bloom halo, so a few stars read as
				// genuinely bright rather than merely present.
				if (layer == 0) {
					star += smoothstep(size * 2.8, 0.0, d) * 0.36;
				}
				col += tint * star * twinkle * mag * star_intensity * sky_open;
			}
		}

		// Meteor. One streak per period, entering from a direction that changes
		// each time, so it is a rare event rather than an effect on a loop.
		float cycle = floor(sky_phase / meteor_period);
		float t = 2.0; // moving streaks would reintroduce per-frame sky invalidation
		if (t < 0.16) {
			float ha = hash13(vec3(cycle, 3.0, 7.0));
			float hb = hash13(vec3(cycle, 11.0, 5.0));
			vec3 origin = normalize(vec3(ha * 2.0 - 1.0, 0.35 + hb * 0.55, hash13(vec3(cycle, 2.0, 9.0)) * 2.0 - 1.0));
			vec3 travel = normalize(cross(origin, vec3(0.0, 1.0, 0.0)) + vec3(0.0, -0.55, 0.0));
			float head = t / 0.16;
			// Sample a short arc behind the head for the tail.
			float glow = 0.0;
			for (int i = 0; i < 4; i++) {
				float u = head - float(i) * 0.022;
				if (u < 0.0) {
					continue;
				}
				vec3 p = normalize(origin + travel * u * 0.9);
				glow = max(glow, smoothstep(0.016, 0.0, distance(EYEDIR, p)) * (1.0 - float(i) * 0.25));
			}
			// Fade in and out so it never pops on or off mid-sky.
			col += vec3(0.95, 0.93, 1.0) * glow * sin(head * PI) * star_intensity * sky_open;
		}
	}

	// Bank first: it is the furthest thing in the sky, and the overhead deck has
	// to be able to pass in front of it.
	col = mix(col, bank_col, bank_alpha);
	col = mix(col, cloud_col, cloud_alpha);
	COLOR = col * energy;
}
