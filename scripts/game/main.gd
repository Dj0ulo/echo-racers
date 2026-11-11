extends Node3D
## Game entry point: spawns the car on the road, handles pause/quit and vehicle resets.

const AUTODRIVE_SCRIPT := "res://scripts/debug/autodrive.gd"

@onready var world: WorldGenerator = $World
@onready var car: CarController = $Car
@onready var chase_camera: ChaseCamera = $ChaseCamera
@onready var hud: Hud = $HUD


func _ready() -> void:
	car.reset_to(world.get_spawn_transform())
	chase_camera.snap()
	car.flipped.connect(reset_car)
	hud.car = car
	# Debug: `godot -- --autodrive` drives a scripted test lap and prints telemetry.
	if "--autodrive" in OS.get_cmdline_user_args():
		var autodrive: Node = load(AUTODRIVE_SCRIPT).new()
		autodrive.name = "Autodrive"
		add_child(autodrive)


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
	car.reset_to(world.get_reset_transform(car.global_position, -car.global_basis.z))
	chase_camera.snap()


func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	hud.set_paused(paused)
