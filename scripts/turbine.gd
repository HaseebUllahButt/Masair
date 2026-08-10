extends Node3D
## Spins a wind-turbine rotor about its own axis.
##
## The rotor is the only moving landmark in the world, which is exactly why it
## earns a script: a still turbine reads as a prop, a turning one reads as
## weather. Cost is one float per turbine per frame.

## Radians per second. Set per turbine so a row of them never beats in unison.
var speed: float = 0.6


func _process(delta: float) -> void:
	rotation.z += speed * delta
