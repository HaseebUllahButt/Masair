extends Node3D
## A friend on the shared road. Lives in the "traffic" group with a bike-sized
## footprint, so the local rider can clip them (mutual crash — both clients see
## the same overlap and kill their own rider), nearly clip them (near-miss
## bonus), and traffic cars brake and change lanes around them. Horn does
## nothing: a remote rider cannot react to it.
##
## Poses arrive as road coordinates and are reconstructed through the same
## world seed, so the rider sits exactly on the tarmac every client sees.
## The Visual child runs motorcycle_visual.gd, which reads `speed` and `lean`
## off this node for wheel spin and bar steer — same as it does for Player.

const MotorcycleVisualGD := preload("res://scripts/motorcycle_visual.gd")
const VISUAL_LEAN := 0.72 ## mirrors motorcycle.gd — only drawn lean is damped
const WHEELIE_PITCH := deg_to_rad(32.0) ## mirrors motorcycle.gd wheelie_pitch_deg
const EDGE_MARGIN := 0.8 ## mirrors motorcycle.gd half_width + road_edge_margin
const TAG_FADE_M := 350.0

var rider_name := "rider"
var bike := 0

# read by the Visual child (motorcycle_visual.gd) and by traffic cars
var speed: float = 0.0
var lean: float = 0.0
var track_z: float = 0.0
var lateral: float = 0.0
var lane: int = -1
# traffic_car.gd probes these via .get() — a remote rider never lane-changes,
# but the fields must exist or int(null) throws inside the lane-clear check
var _pending_lane := -1
var _lane_change_active := false

var _tz := 0.0
var _lat := 0.0
var _hdg := 0.0
var _ln := 0.0
var _wl := 0.0
var _sp := 0.0
var _fall := 0.0
var _alive := true
var _seen := false
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
	add_to_group("traffic")
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


var _target := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]


func apply_pose(d: Array) -> void:
	## [track_z, lateral, heading, lean, wheelie, speed, alive, distance]
	for i in 7:
		_target[i] = float(d[i])
	if not _seen or _target[0] < _tz - 200.0:
		# first sighting, or a crash reset back to km zero — snap instead of
		# sweeping across the map
		_seen = true
		_tz = _target[0]
		_lat = _target[1]
		_hdg = _target[2]
		_ln = _target[3]
		_wl = _target[4]
		_sp = _target[5]


# ---- the "traffic" contract ------------------------------------------------
# Same surface traffic_car.gd exposes, just enough for cars to read us as a
# slow bike and for motorcycle.gd._check_traffic() to hit us.


func get_half_width() -> float:
	return 0.42


func get_half_length() -> float:
	return 1.05


func register_near_miss() -> void:
	## The local rider just threaded past a friend — pays out exactly like
	## clipping a car does.
	var game := get_node_or_null("/root/GameManager")
	if game:
		game.call("register_near_miss")


func can_hear_horn(_rider_z: float, _rider_lateral: float) -> bool:
	return false


func hear_horn(_rider_z: float, _rider_lateral: float) -> bool:
	return false


func _process(delta: float) -> void:
	var k := 1.0 - exp(-12.0 * delta)
	_lat = lerpf(_lat, _target[1], k)
	_tz = lerpf(_tz, _target[0], k)
	_hdg = lerp_angle(_hdg, _target[2], k)
	_ln = lerpf(_ln, _target[3], k)
	_wl = lerpf(_wl, _target[4], k)
	_sp = lerpf(_sp, _target[5], k)
	_alive = _target[6] > 0.5
	# a downed friend lies over on their side instead of standing upright
	_fall = lerpf(_fall, 0.0 if _alive else 0.9, 1.0 - exp(-4.0 * delta))
	speed = _sp
	lean = _ln
	track_z = _tz
	lateral = _lat

	if _path == null:
		return
	var placed: Transform3D = _path.call("road_transform_at", _tz, _lat, EDGE_MARGIN, false)
	placed.basis = placed.basis.rotated(placed.basis.y, _hdg)
	global_transform = placed
	# lean rolls around the road-forward axis; wheelie lifts the nose
	_visual.rotation.z = _ln * VISUAL_LEAN + _fall
	_visual.rotation.x = -_wl * WHEELIE_PITCH

	var cam := get_viewport().get_camera_3d()
	if cam:
		var dist := global_position.distance_to(cam.global_position)
		_tag.modulate.a = clampf(1.0 - dist / TAG_FADE_M, 0.0, 1.0)
