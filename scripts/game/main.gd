extends Node3D
## Game entry point: spawns the car on the road, handles pause/quit and vehicle resets.

const AUTODRIVE_SCRIPT := "res://scripts/debug/autodrive.gd"
const ECHO_TEST_SCRIPT := "res://scripts/debug/echo_test.gd"
const MAP_TEST_SCRIPT := "res://scripts/debug/map_test.gd"

@onready var world: WorldGenerator = $World
@onready var car: CarController = $Car
@onready var chase_camera: ChaseCamera = $ChaseCamera
@onready var hud: Hud = $HUD

var echo: EchoManager
var gps: Gps
var world_map: WorldMap


func _ready() -> void:
	car.reset_to(world.get_spawn_transform())
	chase_camera.snap()
	car.flipped.connect(reset_car)
	hud.car = car
	var echo_test := "--echotest" in OS.get_cmdline_user_args()
	if echo_test:
		EchoTrack.directory = "user://echoes_test"  # Never touch the player's saved echoes.
	echo = EchoManager.new()
	echo.name = "Echo"
	add_child(echo)
	var env := ($WorldEnvironment as WorldEnvironment).environment
	echo.setup(world, car, chase_camera, hud, env)
	gps = Gps.new()
	gps.name = "Gps"
	add_child(gps)
	gps.setup(world, car, hud.get_minimap(), echo)
	world_map = WorldMap.new()
	world_map.name = "WorldMap"
	add_child(world_map)
	world_map.setup(world, car, hud, env, gps, echo)
	# Debug: `godot -- --autodrive` drives a scripted test lap and prints telemetry.
	if "--autodrive" in OS.get_cmdline_user_args():
		var autodrive: Node = load(AUTODRIVE_SCRIPT).new()
		autodrive.name = "Autodrive"
		add_child(autodrive)
		if echo_test:
			var test: Node = load(ECHO_TEST_SCRIPT).new()
			test.name = "EchoTest"
			add_child(test)
		if "--maptest" in OS.get_cmdline_user_args():
			var map_test: Node = load(MAP_TEST_SCRIPT).new()
			map_test.name = "MapTest"
			add_child(map_test)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		_set_paused(not get_tree().paused)
	elif get_tree().paused:
		if event is InputEventKey and event.pressed and (event as InputEventKey).physical_keycode == KEY_Q:
			get_tree().quit()
	elif event.is_action_pressed(&"reset_vehicle"):
		reset_car()


func _physics_process(_delta: float) -> void:
	if car.global_position.y < -80.0:
		reset_car()


func reset_car() -> void:
	if echo and echo.handle_reset():
		return
	car.reset_to(world.get_reset_transform(car.global_position, -car.global_basis.z))
	chase_camera.snap()


func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	hud.set_paused(paused)
