class_name WorldGenerator
extends Node3D
## Generates the countryside at startup: terrain, roads, vegetation and props.
## Everything is procedural and deterministic for a given seed.
##
## Road network (all coordinates in metres, x/z):
##  - "country": the original winding loop in the middle of the map.
##  - "highway": a wide 2x2-lane loop with a median, long straights and sweeping bends near the map edge.
##  - "link_*": winding country roads joining the loop to the highway with at-grade T-junctions.
##  - "mountain_road": leaves the highway's outer edge opposite link_north, crosses the outer countryside,
##    climbs along the north-east mountain foothills and comes back down to the highway opposite link_east.

## Country loop control points (x, z). The spline passes through each of them.
const ROAD_CONTROL_POINTS := [
	Vector2(0, -205), Vector2(110, -218), Vector2(200, -165), Vector2(232, -60),
	Vector2(170, 10), Vector2(212, 112), Vector2(150, 212), Vector2(40, 192),
	Vector2(-25, 118), Vector2(-118, 200), Vector2(-210, 152), Vector2(-232, 40),
	Vector2(-150, -18), Vector2(-212, -122), Vector2(-128, -205),
]

## Highway loop: a rounded rectangle (straights + 520 m radius bends) whose straights get a gentle S-bend.
const HIGHWAY_HALF_EXTENTS := Vector2(950.0, 905.0)
const HIGHWAY_BEND_RADIUS := 520.0
const HIGHWAY_STRAIGHT_SWAY := [40.0, -35.0, 35.0, -45.0]  ## Sideways sway (m) of each straight.

## Link roads: attach near `from` on the country loop, wind through `via`, end near `to` on the highway.
const LINK_ROADS := [
	{"name": &"link_north", "from": Vector2(110, -218),
		"via": [Vector2(95, -330), Vector2(185, -450), Vector2(120, -590), Vector2(210, -720), Vector2(150, -820)],
		"to": Vector2(150, -905)},
	{"name": &"link_east", "from": Vector2(232, -60),
		"via": [Vector2(350, -40), Vector2(470, 50), Vector2(600, -20), Vector2(730, 60), Vector2(850, 30)],
		"to": Vector2(940, 30)},
	{"name": &"link_southwest", "from": Vector2(-210, 152),
		"via": [Vector2(-320, 250), Vector2(-360, 400), Vector2(-500, 470), Vector2(-560, 620), Vector2(-500, 780)],
		"to": Vector2(-500, 900)},
]

## Roads outside the highway ring. Same format as LINK_ROADS, but both ends join the highway's outer edge.
const OUTER_ROADS := [
	{"name": &"mountain_road", "from": Vector2(150, -905),
		"via": [Vector2(165, -1060), Vector2(110, -1230), Vector2(260, -1420), Vector2(540, -1560),
			Vector2(850, -1700), Vector2(1150, -1760), Vector2(1450, -1660), Vector2(1700, -1430),
			Vector2(1820, -1110), Vector2(1760, -800), Vector2(1560, -600), Vector2(1350, -430),
			Vector2(1220, -220), Vector2(1110, -60), Vector2(1060, 30)],
		"to": Vector2(940, 30)},
]

@export var world_seed := 1337
@export var road_half_width := 4.5
@export var highway_lane_width := 3.75
@export var highway_median := 3.0
@export var highway_shoulder := 2.5
@export var rotor_speed := 0.9  ## Wind turbine rotor speed, rad/s.

var terrain: TerrainData
var road: RoadPath            ## The country loop (spawn road, used by the autodrive).
var highway: RoadPath
var roads: Array[RoadPath] = []
var junctions: Array[Vector3] = []  ## Where link roads meet another road's edge: (x, z, clearance radius).
var _rotors: Array[Node3D] = []


func _ready() -> void:
	generate()


func generate() -> void:
	var start := Time.get_ticks_msec()
	terrain = TerrainData.new(world_seed)
	roads.clear()
	junctions.clear()

	road = _make_country_road(&"country")
	road.build(PackedVector2Array(ROAD_CONTROL_POINTS), terrain.natural_height)
	roads.append(road)

	highway = RoadPath.new()
	highway.name = &"highway"
	highway.is_highway = true
	highway.lanes_per_side = 2
	highway.lane_width = highway_lane_width
	highway.median_width = highway_median
	highway.half_width = highway_median * 0.5 + 2.0 * highway_lane_width + highway_shoulder
	highway.dash_length = 6.0
	highway.dash_gap = 12.0
	highway.terrain_blend = 20.0
	highway.terrain_reach = 45.0
	# Long smoothing window: gentle grades, the terrain is cut and filled around it instead.
	highway.build(_highway_control_points(), terrain.natural_height, 70, 3)
	roads.append(highway)

	for def: Dictionary in LINK_ROADS:
		roads.append(_build_link(def, road, highway))
	for def: Dictionary in OUTER_ROADS:
		roads.append(_build_link(def, highway, highway, 90, 40.0))

	var t_roads := Time.get_ticks_msec()
	terrain.build(roads)
	var t_terrain := Time.get_ticks_msec()
	var steps := [0, 0, 0, 0, 0]
	for st in terrain.chunk_step:
		steps[st] += 1
	print("  terrain chunks: %d detailed, %d at 1/2 and %d at 1/4 resolution" % [steps[1], steps[2], steps[4]])

	TerrainBuilder.build(self, terrain)
	var t_mesh := Time.get_ticks_msec()
	for r in roads:
		RoadBuilder.build(self, r)
	var clear_zones: Array[Vector3] = []
	_rotors = PropsBuilder.build(self, terrain, roads, junctions, clear_zones, world_seed)
	var t_props := Time.get_ticks_msec()
	VegetationBuilder.build(self, terrain, clear_zones, world_seed)
	var t_end := Time.get_ticks_msec()
	print("World generated in %d ms (roads %d, terrain grid %d, terrain mesh %d, roads+props %d, vegetation %d)" % [
		t_end - start, t_roads - start, t_terrain - t_roads, t_mesh - t_terrain, t_props - t_mesh, t_end - t_props])
	for r in roads:
		var st := r.stats()
		print("  road %-15s %5.0f m, min radius %4.0f m, max grade %.1f %%" % [r.name, r.length, st.x, st.y])


## Samples the highway outline every ~60 m; the spline through these points reproduces it closely.
static func _highway_control_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	var ext: Vector2 = HIGHWAY_HALF_EXTENTS
	var r := HIGHWAY_BEND_RADIUS
	# Corners (centre, start angle), counter-clockwise in screen space starting at the +x/+z corner.
	var corners := [Vector2(ext.x - r, ext.y - r), Vector2(-(ext.x - r), ext.y - r),
		Vector2(-(ext.x - r), -(ext.y - r)), Vector2(ext.x - r, -(ext.y - r))]
	for k in 4:
		var c: Vector2 = corners[k]
		var a0 := k * PI * 0.5
		var arc_steps := 13
		for s in arc_steps:
			var ang := a0 + PI * 0.5 * s / arc_steps
			out.append(c + Vector2(cos(ang), sin(ang)) * r)
		# Straight from this corner's end to the next corner's start, with a sine sway.
		var a1 := a0 + PI * 0.5
		var from := c + Vector2(cos(a1), sin(a1)) * r
		var next: Vector2 = corners[(k + 1) % 4]
		var to := next + Vector2(cos(a1), sin(a1)) * r
		var outward := Vector2(cos(a1), sin(a1))
		var steps := maxi(int(from.distance_to(to) / 60.0), 2)
		for s in steps:
			var t := float(s) / steps
			out.append(from.lerp(to, t) + outward * pow(sin(t * PI), 2.0) * float(HIGHWAY_STRAIGHT_SWAY[k]))
	return out


func _make_country_road(road_name: StringName) -> RoadPath:
	var r := RoadPath.new()
	r.name = road_name
	r.half_width = road_half_width
	r.lane_width = road_half_width - 0.45
	return r


## Open country road from the edge of `from_road` to the edge of `to_road`, leaving and arriving square-on,
## with its end heights pinned to the roads it joins.
func _build_link(def: Dictionary, from_road: RoadPath, to_road: RoadPath, smoothing := 30,
		reach := 22.0) -> RoadPath:
	var via: Array = def.via
	var a := _junction_point(from_road, def.from, via[0])
	var b := _junction_point(to_road, def.to, via[via.size() - 1])
	var controls := PackedVector2Array([a[0], a[0] + a[1] * 14.0])
	for v: Vector2 in via:
		controls.append(v)
	controls.append(b[0] + b[1] * 14.0)
	controls.append(b[0])
	var link := _make_country_road(def.name)
	link.closed = false
	link.terrain_reach = reach
	link.build(controls, terrain.natural_height, smoothing, 3, {"start": a[2], "end": b[2]})
	# The ends tuck just under the road they join so the two surfaces don't z-fight.
	var last := link.sample_count() - 1
	link.points[0].y -= 0.04
	link.points[last].y -= 0.04
	for p in [a, b]:
		junctions.append(Vector3(p[0].x, p[0].y, link.half_width + 4.0))
	return link


## Returns [edge point (Vector2), outward direction (Vector2), road height] on `target`
## nearest to `hint`, on the side facing `toward`.
func _junction_point(target: RoadPath, hint: Vector2, toward: Vector2) -> Array:
	var i := target.nearest_index(Vector3(hint.x, 0.0, hint.y))
	var p := target.points[i]
	var right := target.right_at(i)
	var dir := Vector2(right.x, right.z)
	if dir.dot(toward - Vector2(p.x, p.z)) < 0.0:
		dir = -dir
	var edge := Vector2(p.x, p.z) + dir * (target.half_width - 0.6)
	return [edge, dir, p.y]


func _physics_process(delta: float) -> void:
	for rotor in _rotors:
		rotor.rotate_object_local(Vector3.BACK, rotor_speed * delta)


func get_spawn_transform() -> Transform3D:
	return road.transform_at(0, 0.9)


## Transform on the road closest to `pos`, used to recover a stuck or flipped car. On multi-lane roads the
## car is put in the nearest lane that runs the way it was facing.
func get_reset_transform(pos: Vector3, forward := Vector3.ZERO) -> Transform3D:
	var best: RoadPath = road
	var best_i := 0
	var best_d := INF
	for r in roads:
		var i := r.nearest_index(pos)
		var d := Vector2(r.points[i].x - pos.x, r.points[i].z - pos.z).length() - r.half_width
		if d < best_d:
			best_d = d
			best = r
			best_i = i
	if best.median_width <= 0.0:
		return best.transform_at(best_i, 0.9)
	var right := best.right_at(best_i)
	var lateral := (pos - best.points[best_i]).dot(right)
	var reverse := forward.dot(best.tangents[best_i]) < 0.0 if forward != Vector3.ZERO else lateral < 0.0
	var lane_offset := 0.0
	var best_gap := INF
	for offset in best.lane_offsets():
		if (offset < 0.0) != reverse:
			continue
		if absf(offset - lateral) < best_gap:
			best_gap = absf(offset - lateral)
			lane_offset = offset
	return best.transform_at(best_i, 0.9, lane_offset, reverse)
