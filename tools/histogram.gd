extends SceneTree
## Dev tool: what is actually in a captured frame, in numbers.
##
##   godot --headless --path . --script res://tools/histogram.gd -- shot.png [more.png]
##
## Judging a lighting change by looking at screenshots is how a scene ends up
## with no dark values in it: the eye adapts to whatever is on screen and calls
## it correct. This prints the luminance distribution and the mean channel mix,
## which do not adapt.
##
## Useful reference points for a sunlit exterior with real form in it: the 5th
## percentile should be under ~0.18 (something in frame is genuinely in shade),
## the median somewhere around 0.35-0.55, and the 95th over ~0.85 (something is
## genuinely bright). A median over 0.6 with a 5th percentile over 0.3 is a
## washed-out frame however pretty it looks.


func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		_report(path)
	quit()


func _report(path: String) -> void:
	var img := Image.load_from_file(path)
	if img == null:
		print("could not read ", path)
		return
	var lum := PackedFloat32Array()
	var sum := Vector3.ZERO
	# Skip the HUD strips top and bottom: white text on a dark plate is not part
	# of the scene and drags both tails.
	var y0: int = int(float(img.get_height()) * 0.14)
	var y1: int = int(float(img.get_height()) * 0.92)
	for y in range(y0, y1, 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			sum += Vector3(c.r, c.g, c.b)
			lum.append(0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
	lum.sort()
	var n := lum.size()
	var mean: Vector3 = sum / float(n)
	print(
		(
			"%s  p05 %.3f  p25 %.3f  median %.3f  p75 %.3f  p95 %.3f  |  mean rgb %.3f %.3f %.3f  sat %.3f"
			% [
				path.get_file(),
				lum[int(n * 0.05)],
				lum[int(n * 0.25)],
				lum[n / 2],
				lum[int(n * 0.75)],
				lum[int(n * 0.95)],
				mean.x,
				mean.y,
				mean.z,
				_spread(mean),
			]
		)
	)
	_probe(img)


func _probe(img: Image) -> void:
	## Named surfaces, sampled at fixed points in the frame. The distribution says
	## whether an image has darks in it; this says which surface is responsible.
	var line := "   "
	for name in PROBES:
		var uv: Vector2 = PROBES[name]
		var c := img.get_pixel(int(uv.x * float(img.get_width() - 1)), int(uv.y * float(img.get_height() - 1)))
		line += "%s %.2f/%.2f/%.2f  " % [name, c.r, c.g, c.b]
	print(line)


func _spread(mean: Vector3) -> float:
	## How far apart the channels sit on average — a rough stand-in for how much
	## colour, as opposed to grey, the frame carries.
	var hi: float = maxf(mean.x, maxf(mean.y, mean.z))
	var lo: float = minf(mean.x, minf(mean.y, mean.z))
	return 0.0 if hi <= 0.0 else (hi - lo) / hi


## Named sample points, as fractions of the frame. Printed for every image so a
## before/after pair can be compared surface by surface rather than by eye.
const PROBES := {
	"sky": Vector2(0.25, 0.08),
	"cloud": Vector2(0.50, 0.12),
	"far ridge": Vector2(0.90, 0.30),
	"road near": Vector2(0.74, 0.93),
	"road mid": Vector2(0.66, 0.62),
	"verge": Vector2(0.20, 0.72),
	"ground": Vector2(0.10, 0.55),
}
