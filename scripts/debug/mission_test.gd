extends Node
## Debug: `godot -- --autodrive --missiontest [--quiet] [--shots=/abs/dir]` runs a delivery mission end to end
## (scratch wallet, see main.gd): spawns an offer 8 m ahead of the car on its road, checks that stopping in its
## ring opens the offer menu (shot `mission_offer.png`), accepts it through the real ui_accept action, checks
## the GPS route to the drop-off, spawns a random offer (world map shot `mission_map.png`), teleports the car
## onto the drop-off and checks the wallet was paid the offer's reward. Prints "Mission test: PASS" or "FAIL: ...". Real gamepad buttons are
## ignored during the test.

var _main: Node
var _phase := 0
var _wait := 4.0
var _shots := ""
var _offer: MissionManager.Offer
var _balance := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_main = get_parent()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots = arg.trim_prefix("--shots=")


func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	var missions: MissionManager = _main.get(&"missions")
	var echo: EchoManager = _main.get(&"echo")
	var gps: Gps = _main.get(&"gps")
	var wallet: Wallet = _main.get(&"wallet")
	var world: WorldGenerator = _main.get(&"world")
	var car: CarController = _main.get(&"car")
	match _phase:
		0:
			var road := world.road
			var i := road.wrap_index(road.nearest_index(car.global_position) + 30)
			_offer = missions.spawn_offer_at(road, i)
			if _offer == null:
				_fail("no drop-off found for an offer on %s" % road.name)
				return
			print("Mission test: offer '%s', %.0f m by road (straight %.0f m), reward %d" % [_offer.cargo,
				_offer.route_length, Vector2(_offer.target.x - _offer.pickup.x, _offer.target.z - _offer.pickup.z).length(),
				_offer.reward])
			car.reset_to(road.transform_at(i - 4, 0.6))
			(_main.get(&"chase_camera") as ChaseCamera).snap()
			_balance = wallet.balance
			_next(0.6)
		1:
			if not echo.ui.is_menu_open():
				_fail("the offer menu did not open (offers %d)" % missions.offers.size())
				return
			print("Mission test: offer menu open, paused = %s" % get_tree().paused)
			_shot("mission_offer.png")
			var ev := InputEventAction.new()
			ev.action = &"ui_accept"
			ev.pressed = true
			Input.parse_input_event(ev)
			_next(2.0)
		2:
			if missions.active != _offer or not gps.has_destination or echo.ui.is_menu_open():
				_fail("not accepted (active %s, gps %s)" % [missions.active != null, gps.has_destination])
				return
			print("Mission test: accepted, GPS route %.0f m, %d offer(s) left" % [gps.route_length, missions.offers.size()])
			var extra := missions.spawn_offer()
			print("Mission test: random offer %s" % ("none found" if extra == null else "%.0f m from the car, %.0f m by road, reward %d" % [
				car.global_position.distance_to(extra.pickup), extra.route_length, extra.reward]))
			var map: WorldMap = _main.get(&"world_map")
			map.open()
			_next(0.5)
		3:
			_shot("mission_map.png")
			(_main.get(&"world_map") as WorldMap).close()
			var dir := Vector3(_offer.target.x - car.global_position.x, 0.0, _offer.target.z - car.global_position.z)
			car.reset_to(Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), _offer.target + Vector3.UP * 1.0))
			(_main.get(&"chase_camera") as ChaseCamera).snap()
			_next(0.6)
		4:
			var paid := wallet.balance - _balance
			if missions.active != null or paid != _offer.reward or gps.has_destination:
				_fail("delivery not completed (active %s, paid %d of %d, gps %s)" % [missions.active != null, paid,
					_offer.reward, gps.has_destination])
				return
			print("Mission test: delivered, paid %s -> balance %d" % [paid, wallet.balance])
			print("Mission test: PASS")
			_phase = 99
			get_tree().quit()


func _fail(why: String) -> void:
	print("Mission test: FAIL: ", why)
	_phase = 99
	get_tree().quit(1)


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
