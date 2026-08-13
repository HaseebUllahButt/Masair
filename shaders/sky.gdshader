shader_type sky;
render_mode use_debanding;

// Masair sky.
//
// Analytic: a smooth atmosphere (not a striped three-stop ramp), one celestial
// body, domain-warped cloud, a distant bank, and a real starfield at night.
// TIME drives drift, twinkle and the rare meteor; the radiance cubemap runs a
// cheaper path of the same code so the ground stays the same colour as the sky.

group_uniforms gradient;
uniform vec3 zenith_color : source_color = vec3(0.10, 0.09, 0.28);
uniform vec3 mid_color : source_color = vec3(0.78, 0.42, 0.55);
uniform vec3 horizon_color : source_color = vec3(1.00, 0.52, 0.34);
uniform vec3 ground_color : source_color = vec3(0.11, 0.10, 0.17);
uniform float band_low : hint_range(0.01, 0.6) = 0.12;
uniform float band_high : hint_range(0.05, 1.5) = 0.62;
uniform float horizon_glow : hint_range(0.0, 3.0) = 0.55;
uniform float energy : hint_range(0.0, 3.0) = 1.0;

group_uniforms celestial;
uniform vec3 sun_color : source_color = vec3(1.0, 0.72, 0.42);
uniform float sun_radius : hint_range(0.0, 0.3) = 0.035;
uniform float sun_halo : hint_range(0.0, 4.0) = 0.9;
uniform float sun_disc : hint_range(0.0, 1.0) = 1.0;
uniform float sun_halo_falloff : hint_range(1.0, 60.0) = 9.0;
uniform float moon_face : hint_range(0.0, 1.0) = 0.0;

group_uniforms clouds;
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.83, 0.75);
uniform vec3 cloud_dark : source_color = vec3(0.35, 0.28, 0.44);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_sharpness : hint_range(0.05, 1.0) = 0.34;
uniform float cloud_scale : hint_range(0.2, 8.0) = 1.7;
uniform float cloud_speed = 0.004;
uniform float cloud_opacity : hint_range(0.0, 1.0) = 1.0;
// Seed offset. Motion comes from TIME; this just keeps two worlds from sharing
// the same cloud photograph.
uniform float sky_phase = 37.0;

group_uniforms cloud_bank;
uniform float bank_cover : hint_range(0.0, 1.0) = 0.5;
uniform float bank_opacity : hint_range(0.0, 1.0) = 0.0;
uniform float bank_height : hint_range(0.02, 0.5) = 0.14;
uniform float bank_haze : hint_range(0.0, 1.0) = 0.55;

group_uniforms stars;
uniform float star_intensity : hint_range(0.0, 6.0) = 0.0;
uniform vec3 galaxy_color : source_color = vec3(0.42, 0.46, 0.72);
uniform float meteor_period = 26.0;
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
	// Quintic: value and slope stay continuous across cell edges, so the deck
	// does not break into the square shards a cubic blend produced.
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
	return sum / max(norm, 1e-4);
}


vec2 cloud_uv(vec3 dir) {
	return dir.xz / (max(dir.y, 0.0) + 0.16) * cloud_scale;
}


float star_layer(vec3 dir, float density, float cut, float radius, float halo, float time) {
	vec3 cell = dir * density;
	vec3 id3 = floor(cell);
	float id = hash13(id3);
	if (id < cut) {
		return 0.0;
	}
	vec3 offset = vec3(hash13(id3 + 11.0), hash13(id3 + 23.0), hash13(id3 + 37.0)) - 0.5;
	// Keep the disc inside the cell so stars do not clip into squares as the
	// camera turns across a boundary.
	float d = length(fract(cell) - 0.5 - offset * 0.20);
	float mag = pow((id - cut) / max(1.0 - cut, 1e-3), 0.70);
	float twinkle = 0.80 + 0.20 * sin(time * (1.1 + id * 2.4) + id * 17.0);
	float core = smoothstep(radius, 0.0, d);
	return (core + smoothstep(radius * 1.7, 0.0, d) * halo) * mag * twinkle;
}


void sky() {
	int octaves = AT_CUBEMAP_PASS ? 2 : 5;
	float up = EYEDIR.y;
	float h = max(up, 0.0);
	float t = TIME + sky_phase;

	// ── Atmosphere ─────────────────────────────────────────────────────────
	// Wide smoothsteps, not two hard altitude gates, so dusk is a wash of
	// colour instead of three painted stripes. Horizon glow stays a skirt.
	float zenith_w = smoothstep(band_low * 0.45, band_high, h);
	float mid_w = smoothstep(0.0, max(band_low * 2.6, 0.05), h);
	vec3 col = mix(horizon_color, mid_color, mid_w);
	col = mix(col, zenith_color, zenith_w);
	float skirt = pow(1.0 - min(abs(up) * 3.4, 1.0), 2.2);
	col += horizon_color * skirt * horizon_glow;
	col = mix(col, ground_color, smoothstep(0.0, -0.08, up));

	// ── Clouds ─────────────────────────────────────────────────────────────
	float cloud_alpha = 0.0;
	float cloud_thickness = 0.0;
	float cloud_shadow = 0.0;
	vec3 cloud_col = cloud_lit;
	vec3 bank_col = cloud_lit;
	vec2 uv = cloud_uv(EYEDIR);
	vec2 drift = vec2(t * cloud_speed, t * cloud_speed * 0.37);
	if (cloud_opacity > 0.001 && up > -0.02) {
		int warp_oct = AT_CUBEMAP_PASS ? 1 : 3;
		vec2 warp = vec2(
			fbm(uv * 0.72 + drift, warp_oct),
			fbm(uv * 0.72 + drift + vec2(5.2, 1.7), warp_oct)
		);
		float density = fbm(uv + drift + warp * 1.05, octaves);
		density = mix(density, fbm(uv * 0.38 - drift * 0.55, max(octaves - 1, 1)), 0.28);
		float edge = mix(0.40, 0.11, clamp(cloud_sharpness, 0.0, 1.0));
		float base = 1.0 - cloud_cover;
		cloud_alpha = smoothstep(base, base + edge, density);
		cloud_thickness = clamp((density - base) / max(edge, 1e-3), 0.0, 1.0);
		if (!AT_CUBEMAP_PASS && LIGHT0_ENABLED) {
			vec2 toward_sun = normalize(LIGHT0_DIRECTION.xz + vec2(1e-4)) * 0.50;
			float above = fbm(uv + toward_sun + drift + warp * 1.05, max(octaves - 2, 1));
			cloud_shadow = clamp((above - base) / max(edge, 1e-3), 0.0, 1.0);
		}
		cloud_alpha *= smoothstep(0.0, 0.09, up) * cloud_opacity;

		// High wisps. Cheap depth: they sit above the weather deck and stay
		// thin enough that they never read as a second storm.
		if (!AT_CUBEMAP_PASS) {
			vec2 cirrus_uv = EYEDIR.xz / (h + 0.22) * 0.55 + drift * 1.7;
			cirrus_uv.x *= 2.4;
			float cirrus = fbm(cirrus_uv, 3);
			cirrus = smoothstep(0.52, 0.78, cirrus) * smoothstep(0.12, 0.42, h);
			cirrus *= (1.0 - cloud_alpha) * cloud_opacity * 0.16;
			col = mix(col, mix(cloud_lit, vec3(1.0), 0.22), cirrus);
		}
	}

	// ── Distant cloud bank ─────────────────────────────────────────────────
	float bank_alpha = 0.0;
	float bank_thickness = 0.0;
	if (bank_opacity > 0.001 && up > 0.0 && up < bank_height * 1.35) {
		vec2 buv = EYEDIR.xz / (up + 0.038) * 1.85;
		buv.y *= 0.48;
		float density = fbm(buv + vec2(t * cloud_speed * 0.45, 0.0), AT_CUBEMAP_PASS ? 2 : 4);
		float base = 1.0 - bank_cover;
		bank_alpha = smoothstep(base, base + 0.32, density);
		bank_thickness = clamp((density - base) / 0.32, 0.0, 1.0);
		bank_alpha *= smoothstep(0.0, 0.022, up);
		bank_alpha *= 1.0 - smoothstep(bank_height * 0.40, bank_height, up);
		bank_alpha *= bank_opacity;
	}

	float facing = 0.0;
	float halo = 0.0;
	float ang = 10.0;
	if (LIGHT0_ENABLED) {
		vec3 to_light = normalize(LIGHT0_DIRECTION);
		ang = acos(clamp(dot(EYEDIR, to_light), -1.0, 1.0));
		float disc = (1.0 - smoothstep(sun_radius * 0.90, sun_radius * 1.08, ang)) * sun_disc;
		halo = exp(-ang * sun_halo_falloff) * sun_halo;
		// Day gets a wide Mie bloom; the moon must stay a disc, not a floodlight.
		float mie = pow(max(dot(EYEDIR, to_light), 0.0), mix(8.0, 28.0, moon_face)) * sun_halo * mix(0.32, 0.08, moon_face);

		if (moon_face > 0.001 && disc > 0.0) {
			vec3 tx = normalize(cross(to_light, vec3(0.0, 1.0, 0.0)));
			vec3 ty = cross(tx, to_light);
			vec2 face = vec2(dot(EYEDIR, tx), dot(EYEDIR, ty)) / max(sun_radius, 1e-4);
			float r2 = clamp(dot(face, face), 0.0, 1.0);
			float shade = 0.80 + 0.20 * sqrt(1.0 - r2);
			shade -= 0.26 * (1.0 - smoothstep(0.10, 0.52, length(face - vec2(-0.26, 0.20))));
			shade -= 0.22 * (1.0 - smoothstep(0.08, 0.40, length(face - vec2(0.30, 0.34))));
			shade -= 0.20 * (1.0 - smoothstep(0.06, 0.34, length(face - vec2(0.16, -0.34))));
			shade -= 0.14 * (1.0 - smoothstep(0.05, 0.26, length(face - vec2(-0.40, -0.30))));
			shade -= 0.10 * vnoise(face * 6.0) * smoothstep(0.2, 0.9, r2);
			disc *= mix(1.0, clamp(shade, 0.0, 1.0), moon_face);
		}

		facing = pow(max(dot(EYEDIR, to_light) * 0.5 + 0.5, 0.0), 3.0);
		float shade = clamp(1.0 - cloud_shadow * 0.85 - cloud_thickness * 0.35, 0.0, 1.0);
		cloud_col = mix(cloud_dark, cloud_lit, clamp(facing * 0.55 + shade * 0.65, 0.0, 1.0));
		float rim = (1.0 - cloud_thickness) * facing;
		cloud_col += sun_color * (rim * 0.75 + halo * facing * 0.4);
		bank_col = mix(cloud_dark, cloud_lit, clamp(facing * 0.4 + (1.0 - bank_thickness * 0.5) * 0.7, 0.0, 1.0));
		bank_col += sun_color * (1.0 - bank_thickness) * facing * 0.4;
		bank_col = mix(bank_col, horizon_color, bank_haze);
		col += sun_color * (disc * 1.9 + halo + mie) * (1.0 - cloud_alpha * 0.85) * (1.0 - bank_alpha * 0.7);
	} else {
		bank_col = mix(cloud_dark, horizon_color, bank_haze);
	}

	// ── Stars and galactic band ────────────────────────────────────────────
	if (star_intensity > 0.001 && !AT_CUBEMAP_PASS && up > -0.02) {
		float sky_open = smoothstep(-0.01, 0.08, up);
		sky_open *= 1.0 - cloud_alpha;
		sky_open *= 1.0 - bank_alpha * 0.45;
		sky_open *= 1.0 - (1.0 - smoothstep(sun_radius * 1.4, sun_radius * 5.0, ang)) * sun_disc;

		float airglow = smoothstep(0.0, 0.04, up) * (1.0 - smoothstep(0.07, 0.36, up));
		col += vec3(0.04, 0.14, 0.22) * airglow * min(star_intensity * 0.28, 0.7);

		vec3 axis = normalize(galaxy_axis);
		vec3 gt = normalize(cross(axis, vec3(0.0, 1.0, 0.0)));
		vec2 guv = vec2(dot(EYEDIR, gt), dot(EYEDIR, cross(gt, axis))) * 2.8;
		float band = pow(1.0 - abs(dot(EYEDIR, axis)), 3.4);
		float dust = fbm(guv + vec2(0.15, -0.08), 4);
		float milky = smoothstep(0.24, 0.76, dust);
		col += galaxy_color * band * milky * 0.26 * star_intensity * sky_open;
		col += vec3(0.46, 0.28, 0.62) * band * smoothstep(0.64, 0.92, dust) * 0.10 * star_intensity * sky_open;
		float dust_lane = smoothstep(0.08, 0.0, abs(dot(EYEDIR, axis))) * (1.0 - milky * 0.5);
		col *= 1.0 - dust_lane * 0.16 * sky_open;

		// Pinpoints, not bloom orbs. A few warmer bright stars, a field, then dust.
		// Visible at riding resolution: a few named stars, a field, then dust.
		// Smaller than this and they vanish into 720p; much larger and they
		// bloom into orbs.
		float bright = star_layer(EYEDIR, 54.0, 0.986, 0.16, 0.14, t);
		float mid = star_layer(EYEDIR, 118.0, 0.950, 0.11, 0.05, t);
		float fine = star_layer(EYEDIR, 230.0, 0.900, 0.08, 0.0, t);
		vec3 bright_tint = mix(vec3(0.78, 0.88, 1.0), vec3(1.0, 0.86, 0.68), hash13(floor(EYEDIR * 54.0) + 9.0));
		col += bright_tint * bright * star_intensity * 1.90 * sky_open;
		col += vec3(0.88, 0.92, 1.0) * mid * star_intensity * 1.15 * sky_open;
		col += vec3(0.80, 0.86, 1.0) * fine * star_intensity * 0.62 * sky_open;

		float cycle = floor(t / meteor_period);
		float head = fract(t / meteor_period) * meteor_period;
		if (head < 0.38) {
			float ha = hash13(vec3(cycle, 3.0, 7.0));
			float hb = hash13(vec3(cycle, 11.0, 5.0));
			vec3 origin = normalize(vec3(ha * 2.0 - 1.0, 0.35 + hb * 0.55, hash13(vec3(cycle, 2.0, 9.0)) * 2.0 - 1.0));
			vec3 travel = normalize(cross(origin, vec3(0.0, 1.0, 0.0)) + vec3(0.0, -0.55, 0.0));
			float u_head = head / 0.38;
			float glow = 0.0;
			for (int i = 0; i < 5; i++) {
				float u = u_head - float(i) * 0.028;
				if (u < 0.0) {
					continue;
				}
				vec3 p = normalize(origin + travel * u * 0.95);
				glow = max(glow, smoothstep(0.014, 0.0, distance(EYEDIR, p)) * (1.0 - float(i) * 0.18));
			}
			col += vec3(0.95, 0.93, 1.0) * glow * sin(u_head * PI) * star_intensity * sky_open;
		}
	}

	col = mix(col, bank_col, bank_alpha);
	col = mix(col, cloud_col, cloud_alpha);
	COLOR = col * energy;
}
