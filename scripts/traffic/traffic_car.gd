class_name TrafficCar
extends AnimatableBody3D
## One AI traffic car. Moved kinematically along its lane by TrafficManager; physics pushes the player's
## car out of the way on contact (the traffic car itself never deflects).
## Collision layer 3 ("traffic", value 4) with mask 2 (vehicle): the player's suspension rays and chase
## camera only query layer 1, so they ignore traffic cars, but the car body still collides with them.

const TRAFFIC_LAYER := 5
const VEHICLE_MASK := 2

var kind := 0
var length := 4.5
var width := 1.8
var s := 0.0          ## Distance along the road centreline.
var speed := 0.0      ## m/s, always >= 0 (cars only drive forwards along their lane).
var cruise := 20.0    ## Preferred speed on a straight, m/s.
var accel := 0.0
var _tail_material: StandardMaterial3D
var _braking := false


func setup(car_kind: int, paint: Color) -> void:
	kind = car_kind
	length = TrafficCarMesh.length_of(kind)
	width = TrafficCarMesh.width_of(kind)
	collision_layer = TRAFFIC_LAYER
	collision_mask = VEHICLE_MASK
	sync_to_physics = true
	var meshes := TrafficCarMesh.build(kind, paint)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = meshes[0]
	body.visibility_range_end = 1100.0
	add_child(body)
	_tail_material = TrafficCarMesh.tail_material()
	var tail := MeshInstance3D.new()
	tail.name = "TailLights"
	tail.mesh = meshes[1]
	tail.material_override = _tail_material
	tail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tail.visibility_range_end = 600.0
	add_child(tail)

	var height := TrafficCarMesh.height_of(kind)
	var box := BoxShape3D.new()
	box.size = Vector3(width, height - 0.25, length)
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(0.0, 0.25 + (height - 0.25) * 0.5, 0.0)
	add_child(shape)


func set_braking(braking: bool) -> void:
	if braking != _braking:
		_braking = braking
		_tail_material.emission_energy_multiplier = 4.0 if braking else 0.6
