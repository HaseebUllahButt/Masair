extends Node
## Sparse ride audio: only the crash accent lives outside the motorcycle.
##
## Continuous wind, tyre, rain and per-car drone layers were fatiguing and made
## the mix sound like broadband noise. The engine now owns the ride sound again.

const AudioGD := preload("res://scripts/audio.gd")
var _impact: AudioStreamPlayer


func _ready() -> void:
	_impact = _oneshot(AudioGD.impact(), -3.0)
	var game := get_node_or_null("/root/GameManager")
	if game:
		game.crashed.connect(_on_crashed)


func _oneshot(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	add_child(p)
	return p


func _on_crashed() -> void:
	_impact.play()
