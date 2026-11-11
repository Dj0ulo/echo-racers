class_name VehicleInput
extends Node
## Converts player input actions into normalized driving commands.
## Kept separate from the physics so an AI or replay can drive the same car later.

var throttle := 0.0  ## 0..1
var brake := 0.0     ## 0..1 (also reverse when slow)
var steer := 0.0     ## -1 (left) .. 1 (right)
var handbrake := false
var boost := false   ## Nitro held (the controller decides whether the gauge allows it).
## When false the values are left untouched, so other code (AI, tests) can set them directly.
var player_controlled := true


func update_input() -> void:
	if not player_controlled:
		return
	throttle = Input.get_action_strength(&"accelerate")
	brake = Input.get_action_strength(&"brake")
	steer = Input.get_axis(&"steer_left", &"steer_right")
	handbrake = Input.is_action_pressed(&"handbrake")
	boost = Input.is_action_pressed(&"boost")


func clear() -> void:
	throttle = 0.0
	brake = 0.0
	steer = 0.0
	handbrake = false
	boost = false
