class_name WorldGenerator
extends Node3D
## Generates the countryside at startup: terrain, road, vegetation and props.
## Everything is procedural and deterministic for a given seed.

## Road loop control points (x, z) in metres. The spline passes through each of them.
const ROAD_CONTROL_POINTS := [
	Vector2(0, -205), Vector2(110, -218), Vector2(200, -165), Vector2(232, -60),
	Vector2(170, 10), Vector2(212, 112), Vector2(150, 212), Vector2(40, 192),
	Vector2(-25, 118), Vector2(-118, 200), Vector2(-210, 152), Vector2(-232, 40),
	Vector2(-150, -18), Vector2(-212, -122), Vector2(-128, -205),
]

@export var world_seed := 1337
@export var road_half_width := 4.5
@export var rotor_speed := 0.9  ## Wind turbine rotor speed, rad/s.

var terrain: TerrainData
var road: RoadPath
var _rotors: Array[Node3D] = []


func _ready() -> void:
	generate()


func generate() -> void:
	var start := Time.get_ticks_msec()
	terrain = TerrainData.new(world_seed)
	road = RoadPath.new()
	road.half_width = road_half_width
	road.build(PackedVector2Array(ROAD_CONTROL_POINTS), terrain.natural_height)
	terrain.build(road)

	TerrainBuilder.build(self, terrain)
	RoadBuilder.build(self, road)
	var clear_zones: Array[Vector3] = []
	_rotors = PropsBuilder.build(self, terrain, road, clear_zones, world_seed)
	VegetationBuilder.build(self, terrain, road, clear_zones, world_seed)
	print("World generated in %d ms (road length %.0f m)" % [Time.get_ticks_msec() - start, road.length])


func _physics_process(delta: float) -> void:
	for rotor in _rotors:
		rotor.rotate_object_local(Vector3.BACK, rotor_speed * delta)


func get_spawn_transform() -> Transform3D:
	return road.transform_at(0, 0.9)


## Transform on the road closest to `pos`, used to recover a stuck or flipped car.
func get_reset_transform(pos: Vector3) -> Transform3D:
	return road.transform_at(road.nearest_index(pos), 0.9)
