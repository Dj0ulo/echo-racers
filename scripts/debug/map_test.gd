extends Node
## Debug: `godot -- --autodrive --maptest [--quiet] [--shots=/abs/dir]` checks the world map and GPS while the
## autodrive drives: opens the map through the real input action (shot `map.png`), sets a destination
## 450 m ahead on the current road and prints the route, closes the map (shot `filament.png` a few seconds
## later), then routes to a far point on every other road and prints route length vs straight distance
## (a route of 0 m or much shorter than the straight line means the road graph is broken).
## Real gamepad buttons are ignored during the test.

var _main: Node
var _phase := 0
var _wait := 6.0
var _shots := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_main = get_parent()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots = arg.trim_prefix("--shots=")


## Swallows real gamepad buttons (Godot reads joypads even when unfocused): this node is the last child of
## main, so it gets input events first.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	var map: WorldMap = _main.get(&"world_map")
	var gps: Gps = _main.get(&"gps")
	var world: WorldGenerator = _main.get(&"world")
	var car: CarController = _main.get(&"car")
	match _phase:
		0:
			var ev := InputEventAction.new()
			ev.action = &"world_map"
			ev.pressed = true
			Input.parse_input_event(ev)
			_next(0.4)
		1:
			print("Map test: map open = %s, paused = %s" % [map.is_open(), get_tree().paused])
			var road := _nearest_road(world, car.global_position)
			var i := road.nearest_index(car.global_position)
			var fwd := road.tangents[i].dot(-car.global_basis.z) >= 0.0
			var s := road.distances[i] + (450.0 if fwd else -450.0)
			var p: Vector3 = road.sample_at(s)[0]
			gps.set_destination(p)
			print("Map test: destination on %s, route %.0f m (%d points), straight %.0f m" % [road.name,
				gps.route_length, gps.route.size(), car.global_position.distance_to(p)])
			_next(0.5)
		2:
			_shot("map.png")
			map.close()
			print("Map test: map open = %s, paused = %s" % [map.is_open(), get_tree().paused])
			_next(1.5)
		3:
			_shot("filament.png")
			var fil := gps.get_child(0) as MeshInstance3D
			print("Map test: filament visible = %s, %d surface(s)" % [fil.is_visible_in_tree(), fil.mesh.get_surface_count()])
			for r in world.roads:
				var p := r.points[r.points.size() / 2]
				gps.set_destination(p)
				print("Map test: to %-18s route %6.0f m, straight %6.0f m" % [r.name, gps.route_length,
					car.global_position.distance_to(p)])
			gps.clear_destination()
			print("Map test: done")
			_phase = 99
			get_tree().quit()


func _nearest_road(world: WorldGenerator, pos: Vector3) -> RoadPath:
	var best: RoadPath
	var best_d := INF
	for r in world.roads:
		var d := r.points[r.nearest_index(pos)].distance_to(pos)
		if d < best_d:
			best_d = d
			best = r
	return best


func _next(wait: float) -> void:
	_phase += 1
	_wait = wait


func _shot(file: String) -> void:
	if _shots.is_empty():
		return
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	if image.get_width() > 960:
		image.resize(960, roundi(image.get_height() * 960.0 / image.get_width()), Image.INTERPOLATE_LANCZOS)
	image.save_png(_shots + "/" + file)
	print("Saved ", _shots, "/", file)
