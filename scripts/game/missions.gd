class_name MissionManager
extends Node
## Delivery missions. Every `spawn_interval_min`..`spawn_interval_max` seconds (the first one after
## `first_offer_delay`) an offer appears at a random roadside spot of the road network (not the highway or its
## ramps), at least `min_offer_distance` from the car, up to `max_offers` at once; each expires after
## `offer_lifetime` seconds. Offers are lime MissionMarkers in the world, parcels on the minimap and world map.
## Stopping (below `pickup_speed_kmh`) inside an offer's ring in free roam opens a menu (EchoUi look, through the
## EchoManager): cargo, where to, distance by road, reward, Accept / Decline. Declining keeps the offer until it
## expires but it only asks again once the car has left and come back. An accepted offer becomes the one active
## delivery: its drop-off, a random roadside spot `min_route`..`max_route` metres away by road, gets a lime light
## beam and pin and the GPS route; driving there (free roam) pays route km × `pay_per_km` × a random factor,
## through the Wallet. The free-roam Y menu can re-route the GPS to the drop-off or abandon the delivery.
## Missions are not saved: offers and the active delivery are lost on restart (the wallet is kept).

const COLOR := Color(0.62, 1.0, 0.22)  ## Lime: offers, drop-off beam and pins (distinct from echo cyan, GPS gold).
const CARGO: Array[String] = [
	"A crate of apples", "Spare tractor parts", "A wedding cake", "Two sacks of flour", "A box of vinyl records",
	"Fresh cheese wheels", "A boxed wind-turbine bolt kit", "Medical supplies", "A parcel of seeds",
	"A barrel of cider", "A crate of eggs (fragile)", "Office printer toner", "A forgotten birthday present",
]
const COMPASS: Array[String] = ["north", "north-east", "east", "south-east", "south", "south-west", "west",
	"north-west"]

@export var auto_spawn := true            ## Off in debug runs (the mission test spawns its own offer).
@export var first_offer_delay := 15.0     ## Seconds after start before the first offer.
@export var spawn_interval_min := 45.0    ## Seconds between offers (random in [min, max]).
@export var spawn_interval_max := 120.0
@export var max_offers := 3               ## Open offers at once.
@export var offer_lifetime := 240.0       ## Seconds before an untaken offer disappears.
@export var min_offer_distance := 300.0   ## New offers spawn at least this far from the car (crow flies, m).
@export var offer_spacing := 250.0        ## ...and from the other offers and the active drop-off.
@export var pickup_radius := 12.0         ## Offer trigger radius (m, horizontal; the visible ring).
@export var pickup_speed_kmh := 35.0      ## The offer menu opens only below this speed.
@export var delivery_radius := 25.0       ## Drop-off reached within this horizontal distance (m).
@export var min_route := 600.0            ## Drop-off distance by road from the offer (m)...
@export var max_route := 3000.0           ## ...at most this.
@export var pay_per_km := 160.0           ## Reward per km of route (≈ R250 for a 1.6 km delivery)...
@export var pay_random_min := 0.85        ## ...times a random factor in [min, max]...
@export var pay_random_max := 1.2
@export var pay_step := 5                 ## ...rounded to this.
@export var beam_height := 160.0          ## Light beam over the active drop-off.


class Offer:
	var pickup := Vector3.ZERO
	var pickup_dir := Vector3.FORWARD
	var target := Vector3.ZERO
	var route_length := 0.0
	var reward := 0
	var cargo := ""
	var time_left := 0.0
	var declined := false       ## Declined while the car is still in the ring: no new prompt until it leaves.
	var hinted := false         ## "Slow down" hint shown for this visit.
	var marker: MissionMarker


var offers: Array[Offer] = []
var active: Offer                 ## The accepted delivery (null = none).

var _world: WorldGenerator
var _car: CarController
var _echo: EchoManager
var _gps: Gps
var _wallet: Wallet
var _minimap: Minimap
var _rng := RandomNumberGenerator.new()
var _spawn_timer := 0.0
var _roads: Array[RoadPath] = []
var _road_total := 0.0
var _target_marker: MissionMarker
var _banner_time := 0.0
var _markers_shown := true


func setup(world: WorldGenerator, car: CarController, echo: EchoManager, gps: Gps, wallet: Wallet,
		minimap: Minimap) -> void:
	_world = world
	_car = car
	_echo = echo
	_gps = gps
	_wallet = wallet
	_minimap = minimap
	_rng.randomize()
	_spawn_timer = first_offer_delay
	for r in world.roads:
		if not r.is_highway and not String(r.name).begins_with("ramp_") and r.length > 100.0:
			_roads.append(r)
			_road_total += r.length
	echo.free_menu_items = _menu_items


func _physics_process(delta: float) -> void:
	var free := _echo.state == EchoManager.State.FREE
	if auto_spawn:
		_spawn_timer -= delta
		if _spawn_timer <= 0.0:
			_spawn_timer = _rng.randf_range(spawn_interval_min, spawn_interval_max)
			if offers.size() < max_offers and spawn_offer() == null:
				_spawn_timer = 5.0  # No valid spot this time: try again soon.
	var pos := _car.global_position
	for o: Offer in offers.duplicate():
		var inside := _flat(pos, o.pickup) < pickup_radius and absf(pos.y - o.pickup.y) < 8.0
		if not inside:
			o.declined = false
			o.hinted = false
			o.time_left -= delta
			if o.time_left <= 0.0:
				_remove_offer(o)
			continue
		if not free or o.declined or _echo.ui.is_menu_open() or get_tree().paused:
			continue
		if _car.linear_velocity.length() * 3.6 > pickup_speed_kmh:
			if not o.hinted:
				o.hinted = true
				_echo.ui.toast("Delivery offer: slow down to see it")
			continue
		_open_offer_menu(o)
		break
	if active and free and _flat(pos, active.target) < delivery_radius:
		_complete()


func _process(delta: float) -> void:
	var free := _echo.state == EchoManager.State.FREE
	if free != _markers_shown:
		_markers_shown = free
		for o in offers:
			o.marker.visible = free
		if _target_marker:
			_target_marker.visible = free
	if _banner_time > 0.0:
		_banner_time -= delta
		if _banner_time <= 0.0 and free:
			_echo.ui.hide_banner()


# --- Offers --------------------------------------------------------------------------------------

## Spawns an offer at a random roadside spot (far enough from the car and the other markers). Returns null when
## no spot / drop-off was found this time.
func spawn_offer() -> Offer:
	for attempt in 12:
		var road := _random_road()
		var i := _rng.randi_range(0, road.points.size() - 1)
		var p := road.points[i]
		if road.is_bridge(i) or _flat(p, _car.global_position) < min_offer_distance or not _clear_of_markers(p):
			continue
		var o := spawn_offer_at(road, i)
		if o:
			return o
	return null


## Spawns an offer on the roadside of `road` at sample `i` (the mission test uses it directly).
func spawn_offer_at(road: RoadPath, i: int) -> Offer:
	var o := Offer.new()
	o.pickup = _roadside(road, i)
	o.pickup_dir = road.tangents[i]
	if not _pick_destination(o):
		return null
	o.reward = maxi(roundi(o.route_length / 1000.0 * pay_per_km * _rng.randf_range(pay_random_min, pay_random_max)
		/ pay_step) * pay_step, pay_step)
	o.cargo = CARGO[_rng.randi_range(0, CARGO.size() - 1)]
	o.time_left = offer_lifetime
	o.marker = MissionMarker.new()
	o.marker.name = "DeliveryOffer"
	add_child(o.marker)
	o.marker.setup(o.pickup, pickup_radius, "DELIVERY\n%s · %.1f km" % [Wallet.format(o.reward),
		o.route_length / 1000.0])
	o.marker.visible = _markers_shown
	offers.append(o)
	_sync_minimap()
	return o


## Picks a roadside drop-off between `min_route` and `max_route` metres away by road. False if none found.
func _pick_destination(o: Offer) -> bool:
	var graph := _gps.road_graph()
	for attempt in 16:
		var road := _random_road()
		var i := _rng.randi_range(0, road.points.size() - 1)
		var crow := _flat(road.points[i], o.pickup)
		if road.is_bridge(i) or crow < min_route * 0.5 or crow > max_route or not _clear_of_markers(road.points[i]):
			continue
		var target := _roadside(road, i)
		# Either way along the road at the pickup: the player may turn round.
		var length := minf(_route_length(graph, o.pickup, o.pickup_dir, target),
			_route_length(graph, o.pickup, -o.pickup_dir, target))
		if length < min_route or length > max_route or length > crow * 4.0:
			continue
		o.target = target
		o.route_length = length
		return true
	return false


## Metres by road from `from` (leaving along `heading`) to `to`, INF when there is no route.
func _route_length(graph: RoadGraph, from: Vector3, heading: Vector3, to: Vector3) -> float:
	var path := graph.find_route(from, heading, to)
	if path.size() < 2:
		return INF
	var length := from.distance_to(path[0]) + path[path.size() - 1].distance_to(to)
	for k in range(1, path.size()):
		length += path[k - 1].distance_to(path[k])
	return length


func _open_offer_menu(o: Offer) -> void:
	var dir := o.target - o.pickup
	var heading := fposmod(atan2(dir.x, -dir.z), TAU)  # 0 = north (-z), clockwise.
	var compass := COMPASS[roundi(heading / (TAU / 8.0)) % 8]
	var mins := int(o.time_left) / 60
	var accept := {"text": "Accept   (%s on delivery)" % Wallet.format(o.reward), "action": accept_offer.bind(o)}
	var note := ""
	if active:
		accept = {"text": "Accept   (finish your current delivery first)", "action": accept_offer.bind(o),
			"enabled": false}
		note = "\nYou already have a delivery to make."
	_echo.open_menu("DELIVERY", "%s for a customer %.1f km %s of here: %.1f km by road. Pays %s. The offer stays open %d:%02d.%s" % [
		o.cargo, _flat(o.pickup, o.target) / 1000.0, compass, o.route_length / 1000.0, Wallet.format(o.reward),
		mins, int(o.time_left) % 60, note], [
		accept,
		{"text": "Decline", "action": _decline.bind(o)},
	], _decline.bind(o))


func _decline(o: Offer) -> void:
	o.declined = true
	_echo.close_menu()


## Makes `o` the active delivery: drop-off beam, minimap pin, GPS route.
func accept_offer(o: Offer) -> void:
	_echo.close_menu()
	if active or not offers.has(o):
		return
	_remove_offer(o)
	active = o
	_target_marker = MissionMarker.new()
	_target_marker.name = "DeliveryDropOff"
	add_child(_target_marker)
	_target_marker.setup(o.target, delivery_radius * 0.5, "DROP-OFF\n%s" % Wallet.format(o.reward), beam_height)
	_target_marker.visible = _markers_shown
	_gps.set_destination(o.target)
	_sync_minimap()
	_echo.ui.toast("Delivery accepted: follow the GPS to the lime beam (%.1f km)" % (o.route_length / 1000.0))


## Drops the active delivery without pay.
func abandon() -> void:
	if active == null:
		return
	_clear_active()
	_echo.ui.toast("Delivery abandoned")


func _complete() -> void:
	var o := active
	_clear_active()
	_wallet.earn(o.reward, "Delivery")
	_wallet.set_stat("deliveries", int(_wallet.get_stat("deliveries", 0)) + 1)
	_echo.ui.show_banner("DELIVERED", "%s  ·  %.1f km" % [Wallet.format(o.reward, true), o.route_length / 1000.0],
		COLOR)
	_banner_time = 3.0
	print("Delivery completed: %s, %.0f m, paid %d" % [o.cargo, o.route_length, o.reward])


func _clear_active() -> void:
	if _gps.has_destination and _flat(_gps.destination, active.target) < 1.0:
		_gps.clear_destination()
	active = null
	if _target_marker:
		_target_marker.queue_free()
		_target_marker = null
	_sync_minimap()


func _remove_offer(o: Offer) -> void:
	offers.erase(o)
	if is_instance_valid(o.marker):
		o.marker.queue_free()
	_sync_minimap()


## Free-roam Y menu entries while a delivery is active.
func _menu_items() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	if active == null:
		return items
	if not (_gps.has_destination and _flat(_gps.destination, active.target) < 1.0):
		items.append({"text": "GPS to the delivery drop-off", "action": func() -> void:
			_gps.set_destination(active.target)
			_echo.close_menu()})
	items.append({"text": "Abandon the delivery   (%s)" % Wallet.format(active.reward), "action": func() -> void:
		abandon()
		_echo.close_menu()})
	return items


# --- Helpers -------------------------------------------------------------------------------------

func _random_road() -> RoadPath:
	var s := _rng.randf() * _road_total
	for r in _roads:
		s -= r.length
		if s <= 0.0:
			return r
	return _roads[_roads.size() - 1]


## Just off the right-hand edge of `road` at sample `i`, dropped onto the ground.
func _roadside(road: RoadPath, i: int) -> Vector3:
	var p := road.points[i] + road.right_at(i) * (road.half_width + 2.5)
	var space := _car.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 30.0, p + Vector3.DOWN * 40.0, 1))
	if not hit.is_empty():
		p.y = (hit.position as Vector3).y
	return p


func _clear_of_markers(p: Vector3) -> bool:
	for o in offers:
		if _flat(p, o.pickup) < offer_spacing or _flat(p, o.target) < offer_spacing:
			return false
	return active == null or _flat(p, active.target) >= offer_spacing


func _sync_minimap() -> void:
	var pts := PackedVector3Array()
	for o in offers:
		pts.append(o.pickup)
	_minimap.mission_offers = pts
	_minimap.mission_target_active = active != null
	if active:
		_minimap.mission_target = active.target


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
