class_name MissionManager
extends Node
## Delivery missions. Every `spawn_interval_min`..`spawn_interval_max` seconds (the first one after
## `first_offer_delay`) an offer appears at a random spot by the road network (not the highway or its ramps):
## on the roadside or, `offroad_chance` of the time, out in a field `offroad_min_distance`..`offroad_max_distance`
## off the road (gentle, clear ground reachable straight from the road), at least `min_offer_distance` from the
## car, up to `max_offers` at once; each expires after `offer_lifetime` seconds. Offers are lime MissionMarkers
## in the world, parcels on the minimap and world map. Stopping (below `pickup_speed_kmh`) inside an offer's ring
## in free roam opens a menu (EchoUi look, through the EchoManager): cargo, where to, distance by road, reward,
## Accept / Decline. Declining keeps the offer until it expires but it only asks again once the car has left and
## come back. An accepted offer becomes the one active delivery: its drop-off, a random spot (roadside or field,
## likewise) `min_route`..`max_route` metres away by road, gets a lime light beam and pin and the GPS route;
## driving there (free roam) pays route km (field legs included) × `pay_per_km` × a random factor, through the
## Wallet. It must be delivered within the offer's time limit (`time_base` + route at `time_avg_speed_kmh`, rounded
## up to `time_step`), counted down on the EchoUi race HUD in free roam (red and beeping at the end, paused with
## the tree); when it runs out the delivery is cancelled without pay ("TIME'S UP"). Arriving with at least
## `tip_min_early` of the limit left may earn a random tip (see `tip_for`), paid separately.
## The free-roam Y menu can re-route the GPS to the drop-off or abandon the delivery.
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
@export var time_base := 10.0             ## Delivery time limit: this many seconds...
@export var time_avg_speed_kmh := 120.0   ## ...plus the route driven at this average speed...
@export var time_step := 5.0              ## ...rounded up to this (s).
@export var time_warning := 20.0          ## The countdown turns red in the last seconds...
@export var time_beep := 10.0             ## ...and beeps every second in the last ones.
@export_range(0.0, 1.0) var tip_min_early := 0.3    ## A tip is possible only with this share of the time limit left...
@export_range(0.0, 1.0) var tip_full_early := 0.75   ## ...chance and size peak at this share left.
@export_range(0.0, 1.0) var tip_chance_min := 0.3    ## Chance of a tip at `tip_min_early`...
@export_range(0.0, 1.0) var tip_chance_max := 0.8    ## ...rising to this at `tip_full_early`.
@export_range(0.0, 1.0) var tip_percent_min := 0.05  ## Tip as a share of the reward, from this (just early enough)...
@export_range(0.0, 1.0) var tip_percent_max := 0.2   ## ...to this (very early)...
@export_range(0.0, 1.0) var tip_percent_jitter := 0.04  ## ...± a random spread (kept within min..max).
@export_range(0.0, 1.0) var tip_generous_chance := 0.08  ## Sometimes the customer is generous instead...
@export_range(0.0, 1.0) var tip_generous_min := 0.25 ## ...and tips this share of the reward...
@export_range(0.0, 1.0) var tip_generous_max := 0.3  ## ...up to this.
@export var tip_step := 5                 ## Tips are rounded to this...
@export var tip_min := 5                  ## ...and are at least this.
@export var beam_height := 160.0          ## Light beam over the active drop-off.
@export_range(0.0, 1.0) var offroad_chance := 0.4  ## Share of offers / drop-offs placed off the road, in a field.
@export var offroad_min_distance := 20.0  ## Off-road spots lie this far from the road edge...
@export var offroad_max_distance := 60.0  ## ...at most this (and at least `offroad_min_distance` from any road).
@export var offroad_max_slope := 14.0     ## Steepest ground (degrees) at the spot and along the way from the road.
@export var offroad_clearance := 6.0      ## No tree, fence or building within this radius of the spot (m).


class Offer:
	var pickup := Vector3.ZERO
	var pickup_dir := Vector3.FORWARD
	var target := Vector3.ZERO
	var route_length := 0.0     ## Road route plus the straight off-road legs at both ends (m).
	var pickup_offroad := false
	var target_offroad := false
	var reward := 0
	var cargo := ""
	var time_left := 0.0        ## Until the untaken offer expires (s).
	var time_limit := 0.0       ## Delivery time allowed once accepted (s).
	var delivery_left := 0.0    ## Delivery time remaining while active (s).
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
var last_tip := 0  ## Tip paid on the last completed delivery (0: none); read by the mission test.
var _markers_shown := true
var _timer_shown := false         ## The delivery countdown owns the EchoUi race HUD (free roam only).
var _last_beep := 0


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
	if active:
		# Physics process stops while the tree is paused (pause menu, world map, menus): so does the clock.
		active.delivery_left -= delta
		if free and _flat(pos, active.target) < delivery_radius:
			_complete()
		elif active.delivery_left <= 0.0:
			_expire()


func _process(delta: float) -> void:
	var free := _echo.state == EchoManager.State.FREE
	if free != _markers_shown:
		_markers_shown = free
		for o in offers:
			o.marker.visible = free
		if _target_marker:
			_target_marker.visible = free
	_update_timer(free)
	if _banner_time > 0.0:
		_banner_time -= delta
		if _banner_time <= 0.0 and free:
			_echo.ui.hide_banner()


# --- Offers --------------------------------------------------------------------------------------

## Spawns an offer at a random spot by the roads (far enough from the car and the other markers). Returns null when
## no spot / drop-off was found this time.
func spawn_offer() -> Offer:
	for attempt in 12:
		var road := _random_road()
		var i := _rng.randi_range(0, road.points.size() - 1)
		var p := road.points[i]
		if road.is_bridge(i) or _flat(p, _car.global_position) < min_offer_distance or not _clear_of_markers(p):
			continue
		var o := spawn_offer_at(road, i, true)
		if o:
			return o
	return null


## Spawns an offer near `road` at sample `i`: on the roadside, or with `allow_offroad` (random offers) an
## `offroad_chance` of being out in a field. The mission test calls it directly (roadside pickup).
func spawn_offer_at(road: RoadPath, i: int, allow_offroad := false) -> Offer:
	var o := Offer.new()
	o.pickup = _spot_near(road, i, allow_offroad)
	o.pickup_offroad = _flat(o.pickup, road.points[i]) > road.half_width + 5.0
	o.pickup_dir = road.tangents[i]
	if not _pick_destination(o):
		return null
	o.reward = maxi(roundi(o.route_length / 1000.0 * pay_per_km * _rng.randf_range(pay_random_min, pay_random_max)
		/ pay_step) * pay_step, pay_step)
	o.cargo = CARGO[_rng.randi_range(0, CARGO.size() - 1)]
	o.time_left = offer_lifetime
	o.time_limit = time_limit_for(o.route_length)
	o.marker = MissionMarker.new()
	o.marker.name = "DeliveryOffer"
	add_child(o.marker)
	o.marker.setup(o.pickup, pickup_radius, "DELIVERY\n%s · %.1f km" % [Wallet.format(o.reward),
		o.route_length / 1000.0])
	o.marker.visible = _markers_shown
	offers.append(o)
	_sync_minimap()
	return o


## Picks a drop-off (roadside or, `offroad_chance` of the time, in a field) between `min_route` and `max_route` metres away by road. False if none found.
func _pick_destination(o: Offer) -> bool:
	var graph := _gps.road_graph()
	for attempt in 16:
		var road := _random_road()
		var i := _rng.randi_range(0, road.points.size() - 1)
		var crow := _flat(road.points[i], o.pickup)
		if road.is_bridge(i) or crow < min_route * 0.5 or crow > max_route or not _clear_of_markers(road.points[i]):
			continue
		var target := _spot_near(road, i, true)
		# Either way along the road at the pickup: the player may turn round.
		var length := minf(_route_length(graph, o.pickup, o.pickup_dir, target),
			_route_length(graph, o.pickup, -o.pickup_dir, target))
		if length < min_route or length > max_route or length > crow * 4.0:
			continue
		o.target = target
		o.target_offroad = _flat(target, road.points[i]) > road.half_width + 5.0
		o.route_length = length
		return true
	return false


## Delivery time allowed for a route of `route_length` metres: `time_base` + the route at `time_avg_speed_kmh`,
## rounded up to `time_step`.
func time_limit_for(route_length: float) -> float:
	var t := time_base + route_length / 1000.0 / maxf(time_avg_speed_kmh, 1.0) * 3600.0
	return ceilf(t / maxf(time_step, 0.1)) * maxf(time_step, 0.1)


## m:ss, rounded up (a countdown shows 0:00 only once it has run out).
static func format_clock(t: float) -> String:
	var s := maxi(ceili(t), 0)
	return "%d:%02d" % [s / 60, s % 60]


## Metres by road from `from` (leaving along `heading`) to `to`, INF when there is no route. Includes the
## straight legs between the end points and the road network (so off-road spots pay their field crossing).
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
	var accept := {"text": "Accept   (%s on delivery)" % Wallet.format(o.reward), "action": accept_offer.bind(o)}
	var note := ""
	if active:
		accept = {"text": "Accept   (finish your current delivery first)", "action": accept_offer.bind(o),
			"enabled": false}
		note = "\nYou already have a delivery to make."
	_echo.open_menu("DELIVERY", "%s for a customer %.1f km %s of here: %.1f km by road. Pays %s if delivered within %s. The offer stays open %s.%s" % [
		o.cargo, _flat(o.pickup, o.target) / 1000.0, compass, o.route_length / 1000.0, Wallet.format(o.reward),
		format_clock(o.time_limit), format_clock(o.time_left), note + _offroad_note(o)], [
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
	o.delivery_left = o.time_limit
	_last_beep = 0
	_target_marker = MissionMarker.new()
	_target_marker.name = "DeliveryDropOff"
	add_child(_target_marker)
	_target_marker.setup(o.target, delivery_radius * 0.5, "DROP-OFF\n%s" % Wallet.format(o.reward), beam_height)
	_target_marker.visible = _markers_shown
	_gps.set_destination(o.target)
	_sync_minimap()
	_echo.ui.toast("Delivery accepted: follow the GPS to the lime beam (%.1f km in %s)" % [o.route_length / 1000.0,
		format_clock(o.time_limit)])


## Drops the active delivery without pay.
func abandon() -> void:
	if active == null:
		return
	_clear_active()
	_echo.ui.toast("Delivery abandoned")


func _complete() -> void:
	var o := active
	var time_left := maxf(o.delivery_left, 0.0)
	_clear_active()
	_wallet.earn(o.reward, "Delivery")
	_wallet.set_stat("deliveries", int(_wallet.get_stat("deliveries", 0)) + 1)
	last_tip = tip_for(o.reward, time_left / o.time_limit if o.time_limit > 0.0 else 0.0)
	var pay := Wallet.format(o.reward, true)
	if last_tip > 0:
		_wallet.earn(last_tip, "Delivery tip")
		_wallet.set_stat("tips", int(_wallet.get_stat("tips", 0)) + last_tip)
		_wallet.set_stat("tips_count", int(_wallet.get_stat("tips_count", 0)) + 1)
		pay += "  + %s tip" % Wallet.format(last_tip)
	_echo.ui.show_banner("DELIVERED", "%s  ·  %.1f km" % [pay, o.route_length / 1000.0], COLOR)
	_banner_time = 3.0 if last_tip == 0 else 4.0
	print("Delivery completed: %s, %.0f m, paid %d, tip %d, %.0f s left of %.0f" % [o.cargo, o.route_length,
		o.reward, last_tip, time_left, o.time_limit])


## Random tip for a delivery of `reward` arrived with the share `early` (0..1) of its time limit left; 0 for none.
## None below `tip_min_early`; above it the chance rises from `tip_chance_min` to `tip_chance_max` and the size
## from `tip_percent_min` to `tip_percent_max` of the reward (± `tip_percent_jitter`) at `tip_full_early`;
## `tip_generous_chance` of the tips are `tip_generous_min..max` instead. Rounded to `tip_step`, at least `tip_min`.
func tip_for(reward: int, early: float) -> int:
	if early < tip_min_early or reward <= 0:
		return 0
	var t := clampf(inverse_lerp(tip_min_early, maxf(tip_full_early, tip_min_early + 0.001), early), 0.0, 1.0)
	if _rng.randf() >= lerpf(tip_chance_min, tip_chance_max, t):
		return 0
	var share: float
	if _rng.randf() < tip_generous_chance:
		share = _rng.randf_range(tip_generous_min, tip_generous_max)
	else:
		share = clampf(lerpf(tip_percent_min, tip_percent_max, t) + _rng.randf_range(-tip_percent_jitter,
			tip_percent_jitter), tip_percent_min, tip_percent_max)
	var step := maxi(tip_step, 1)
	return maxi(roundi(reward * share / step) * step, tip_min)


## The delivery clock ran out: the mission is cancelled without pay.
func _expire() -> void:
	var o := active
	_clear_active()
	_wallet.set_stat("deliveries_failed", int(_wallet.get_stat("deliveries_failed", 0)) + 1)
	if _echo.state == EchoManager.State.FREE:
		_echo.ui.show_banner("TIME'S UP", "Delivery failed: %s, not delivered in time" % o.cargo.to_lower(),
			EchoUi.BAD)
		_banner_time = 3.0
	else:
		_echo.ui.toast("Time's up: delivery failed")
	_echo.ui.beep(true)
	print("Delivery failed: %s, time limit %.0f s ran out" % [o.cargo, o.time_limit])


## Delivery countdown on the EchoUi race HUD (free roam only: echo races own it otherwise).
func _update_timer(free: bool) -> void:
	if active and free:
		var left := maxf(active.delivery_left, 0.0)
		var ui := _echo.ui
		ui.show_race_hud(true)
		ui.set_timer(format_clock(left), EchoUi.BAD if left <= time_warning else COLOR)
		ui.set_info("DELIVERY   ·   %s   ·   %s" % [active.cargo, Wallet.format(active.reward)])
		_timer_shown = true
		var whole := ceili(left)
		if left <= time_beep and whole > 0 and whole != _last_beep and not get_tree().paused:
			_last_beep = whole
			ui.beep()
	elif _timer_shown:
		_timer_shown = false
		if free:
			_echo.ui.show_race_hud(false)


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


## A drop-on-the-ground spot by `road` at sample `i`: the roadside, or (when `allow_offroad`, with
## `offroad_chance`) a field spot from `_offroad_spot`, falling back to the roadside.
func _spot_near(road: RoadPath, i: int, allow_offroad: bool) -> Vector3:
	if allow_offroad and _rng.randf() < offroad_chance:
		var p := _offroad_spot(road, i)
		if p.is_finite():
			return p
	return _roadside(road, i)


## A random spot `offroad_min_distance`..`offroad_max_distance` off either edge of `road` at sample `i`, at terrain
## height: gentle ground (`offroad_max_slope`) there and along the straight way from the road, away from every
## road, with no collider (tree trunk, fence, guard rail, farm, turbine) on the way or within `offroad_clearance`.
## Vector3.INF when no such spot was found.
func _offroad_spot(road: RoadPath, i: int) -> Vector3:
	var terrain := _world.terrain
	var min_up := cos(deg_to_rad(offroad_max_slope))
	var space := _car.get_world_3d().direct_space_state
	for attempt in 10:
		var side := 1.0 if _rng.randf() < 0.5 else -1.0
		var right := road.right_at(i) * side
		var start := road.points[i] + right * (road.half_width + 1.0)
		var d := _rng.randf_range(offroad_min_distance, offroad_max_distance)
		var p := start + right * d + road.tangents[i] * _rng.randf_range(-0.4, 0.4) * d
		if not terrain.is_inside(p.x, p.z) or terrain.get_road_distance(p.x, p.z) < offroad_min_distance:
			continue
		p.y = terrain.get_height(p.x, p.z)
		if terrain.get_normal(p.x, p.z, 3.0).y < min_up or not _area_clear(space, p, offroad_clearance):
			continue
		if _way_clear(space, start, p, min_up):
			return p
	return Vector3.INF


## True when nothing but the terrain lies within `radius` of ground point `p` (sphere resting just above it).
func _area_clear(space: PhysicsDirectSpaceState3D, p: Vector3, radius: float) -> bool:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), p + Vector3.UP * (radius + 0.6))
	q.exclude = [_car.get_rid()]
	for hit in space.intersect_shape(q, 8):
		var body := hit.collider as Node
		if body == null or body.name != &"TerrainBody":
			return false
	return true


## True when the straight way from the road edge `from` to `to` is drivable: gentle slopes, no other road
## crossed, no collider in the way about a metre above the ground.
func _way_clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, min_up: float) -> bool:
	var terrain := _world.terrain
	var steps := maxi(ceili(_flat(from, to) / 5.0), 1)
	var prev := Vector3(from.x, terrain.get_height(from.x, from.z) + 1.0, from.z)
	for k in range(1, steps + 1):
		var q := from.lerp(to, float(k) / steps)
		q.y = terrain.get_height(q.x, q.z) + 1.0
		# The embankment or cut right by the road may be steeper (cars drive down 2:1 slopes fine).
		var up := cos(deg_to_rad(minf(offroad_max_slope * 2.0, 30.0))) if k * 5.0 < 15.0 else min_up * 0.97
		if terrain.get_normal(q.x, q.z, 2.0).y < up:
			return false
		if k * 5.0 > 6.0 and terrain.get_road_distance(q.x, q.z) < 3.0:
			return false
		var ray := PhysicsRayQueryParameters3D.create(prev, q)
		ray.exclude = [_car.get_rid()]
		var hit := space.intersect_ray(ray)
		if not hit.is_empty() and (hit.collider == null or (hit.collider as Node).name != &"TerrainBody"):
			return false
		prev = q
	return true


func _offroad_note(o: Offer) -> String:
	if o.pickup_offroad and o.target_offroad:
		return "\nOff-road at both ends: cross the fields."
	if o.target_offroad:
		return "\nThe drop-off is off the road, across a field."
	return ""


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
