extends Node3D
## A friend on the shared road. Not a physics body and not in the "traffic"
## group, so it never collides — poses arrive as road coordinates and are
## reconstructed through the same world seed, so the rider sits exactly on the
## tarmac every client sees.
##
## The Visual child runs motorcycle_visual.gd, which reads `speed` and `lean`
## off this node for wheel spin and bar steer — same as it does for Player.

const MotorcycleVisualGD := preload("res://scripts/motorcycle_visual.gd")
const VISUAL_LEAN := 0.72 ## mirrors motorcycle.gd — only drawn lean is damped
const WHEELIE_PITCH := deg_to_rad(32.0) ## mirrors motorcycle.gd wheelie_pitch_deg
const EDGE_MARGIN := 0.8 ## mirrors motorcycle.gd half_width + road_edge_margin
const TAG_FADE_M := 350.0

var rider_name := "rider"
var bike := 0

# read by the Visual child (motorcycle_visual.gd)
var speed: float = 0.0
var lean: float = 0.0

var _tz := 0.0
var _lat := 0.0
var _hdg := 0.0
var _ln := 0.0
var _wl := 0.0
var _sp := 0.0
var _wheelie := 0.0
var _path: Node
var _visual: Node3D
var _tag: Label3D


func setup(p_name: String, p_bike: int) -> void:
	rider_name = p_name
	bike = p_bike


func _ready() -> void:
	# ALWAYS so remote riders keep rolling to the start line while the local
	# tree is paused on the countdown lights.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_path = get_node_or_null("/root/RoadPath")
	_visual = Node3D.new()
	_visual.name = "Visual"
	_visual.set_script(MotorcycleVisualGD)
	add_child(_visual)
	_visual.call("set_bike_style", bike)

	_tag = Label3D.new()
	_tag.text = rider_name
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.fixed_size = true
	_tag.font_size = 72
	_tag.pixel_size = 0.006
	_tag.outline_size = 10
	_tag.modulate = Color("f4efe4")
	_tag.outline_modulate = Color(0, 0, 0, 0.7)
	_tag.position = Vector3(0.0, 1.55, 0.0)
	add_child(_tag)


var _target := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]


func apply_pose(d: Array) -> void:
	## [track_z, lateral, heading, lean, wheelie, speed, alive, distance]
	for i in 6:
		_target[i] = float(d[i])
	if _tz == 0.0 and _target[0] > 400.0 or _target[0] < _tz - 200.0:
		# first sighting deep in the route, or a crash reset back to km zero —
		# snap instead of sweeping across the map
		_tz = _target[0]
		_lat = _target[1]
		_hdg = _target[2]


func _process(delta: float) -> void:
	var k := 1.0 - exp(-12.0 * delta)
	_lat = lerpf(_lat, _target[1], k)
	_tz = lerpf(_tz, _target[0], k)
	_hdg = lerp_angle(_hdg, _target[2], k)
	_ln = lerpf(_ln, _target[3], k)
	_wl = lerpf(_wl, _target[4], k)
	_sp = lerpf(_sp, _target[5], k)
	speed = _sp
	lean = _ln
	_wheelie = _wl

	if _path == null:
		return
	var placed: Transform3D = _path.call("road_transform_at", _tz, _lat, EDGE_MARGIN, false)
	placed.basis = placed.basis.rotated(placed.basis.y, _hdg)
	global_transform = placed
	# lean rolls around the road-forward axis; wheelie lifts the nose
	_visual.rotation.z = _ln * VISUAL_LEAN
	_visual.rotation.x = -_wl * WHEELIE_PITCH

	var cam := get_viewport().get_camera_3d()
	if cam:
		var dist := global_position.distance_to(cam.global_position)
		_tag.modulate.a = clampf(1.0 - dist / TAG_FADE_M, 0.0, 1.0)
