extends Node3D
## Game entry point: spawns the car on the road (or where the save left it), handles the pause menu
## (resume / save / quit), the save game and vehicle resets.

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
var day_night: DayNight
var pause_menu: PauseMenu

@export var trigger_reset_hold := 2.0      ## Seconds LT + RT must be held together to reset the car.
@export var trigger_reset_threshold := 0.8 ## How far both triggers must be pulled to count as held.
@export var save_path := "user://savegame.cfg" ## Pause menu "Save": car transform + time of day.
var _trigger_hold := 0.0


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
	day_night = DayNight.new()
	day_night.name = "DayNight"
	add_child(day_night)
	day_night.setup(env, $Sun as DirectionalLight3D, world, car, chase_camera)
	world_map = WorldMap.new()
	world_map.name = "WorldMap"
	add_child(world_map)
	world_map.setup(world, car, hud, env, gps, echo)
	pause_menu = PauseMenu.new()
	pause_menu.name = "PauseMenu"
	add_child(pause_menu)
	pause_menu.resume_requested.connect(_set_paused.bind(false))
	pause_menu.save_requested.connect(_on_save_requested)
	pause_menu.quit_requested.connect(get_tree().quit)
	# Debug runs always start from the default spawn so they stay reproducible.
	if not "--autodrive" in OS.get_cmdline_user_args():
		load_game()
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
	# The open pause menu handles its own input (Start / Esc resumes). The tree is also paused by the echo menu,
	# its editor and the world map: those own the pause button then, so never stack the pause menu on them.
	if get_tree().paused or (echo and echo.state == EchoManager.State.EDITING):
		return
	if event.is_action_pressed(&"pause"):
		get_viewport().set_input_as_handled()
		_set_paused(true)
	elif event.is_action_pressed(&"reset_vehicle"):
		reset_car()


func _physics_process(delta: float) -> void:
	if car.global_position.y < -80.0:
		reset_car()
	_update_trigger_reset(delta)


## Gamepad reset: hold LT and RT together for `trigger_reset_hold` seconds (only while driving, so the
## triggers keep zooming in the world map and the echo editor).
func _update_trigger_reset(delta: float) -> void:
	var driving := not get_tree().paused and car.input != null and car.input.player_controlled \
			and not (echo and echo.state == EchoManager.State.EDITING)
	var held := VehicleInput.joy_axis(JOY_AXIS_TRIGGER_LEFT) > trigger_reset_threshold \
			and VehicleInput.joy_axis(JOY_AXIS_TRIGGER_RIGHT) > trigger_reset_threshold
	if not (driving and held):
		_trigger_hold = 0.0
		return
	_trigger_hold += delta
	if _trigger_hold >= trigger_reset_hold:
		_trigger_hold = -INF  # Fire once; release the triggers to arm it again.
		reset_car()


func reset_car() -> void:
	if echo and echo.handle_reset():
		return
	car.reset_to(world.get_reset_transform(car.global_position, -car.global_basis.z))
	chase_camera.snap()


func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	if paused:
		pause_menu.open()
	else:
		pause_menu.close()


func _on_save_requested() -> void:
	var err := save_game()
	pause_menu.show_feedback("Saved" if err == OK else "Save failed (%s)" % error_string(err), err == OK)


## Writes the car's transform and the time of day to `save_path`.
func save_game() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("car", "transform", car.global_transform)
	cfg.set_value("world", "hour", day_night.hour)
	return cfg.save(save_path)


## Restores a save written by `save_game` (car at rest at the saved transform, time of day). Returns false when
## there is no readable save, leaving the default road spawn.
func load_game() -> bool:
	var cfg := ConfigFile.new()
	if not FileAccess.file_exists(save_path) or cfg.load(save_path) != OK:
		return false
	var xform: Variant = cfg.get_value("car", "transform")
	if xform is Transform3D:
		car.reset_to((xform as Transform3D).orthonormalized())
		chase_camera.snap()
	var hour: Variant = cfg.get_value("world", "hour")
	if hour is float or hour is int:
		day_night.set_hour(float(hour))
	return true
