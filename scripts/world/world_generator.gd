class_name WorldGenerator
extends Node3D
## Generates the countryside at startup: terrain, roads, vegetation and props.
## Everything is procedural and deterministic for a given seed.
##
## Road network (all coordinates in metres, x/z):
##  - "country": the original winding loop in the middle of the map.
##  - "highway": a wide 2x2-lane loop with a median, long straights and sweeping bends near the map edge.
##  - "link_*": winding country roads from the loop out to the highway, which they cross on a bridge at a
##    diamond interchange, ending just past it where an outer road carries on.
##  - "ramp_<link>_<off|on><1|2>": the four one-way slip roads of each interchange (side 1 = right of the
##    highway's direction of increasing distance, side 2 = left).
##  - "mountain_road": continues link_north through the outer countryside, along the north-east mountain
##    foothills, and back to the interchange of link_east.
##  - "west_road": continues link_southwest around the west of the map and joins the mountain road.

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

## Link roads: attach near `from` on the country loop, wind through `via` and cross the highway square-on
## at the point nearest to `cross` (on a straight), on a bridge.
const LINK_ROADS := [
	{"name": &"link_north", "from": Vector2(110, -218),
		"via": [Vector2(95, -330), Vector2(185, -450), Vector2(120, -590), Vector2(175, -700)],
		"cross": Vector2(150, -905)},
	{"name": &"link_east", "from": Vector2(232, -60),
		"via": [Vector2(350, -40), Vector2(470, 50), Vector2(600, -20), Vector2(700, 40)],
		"cross": Vector2(940, 30)},
	{"name": &"link_southwest", "from": Vector2(-210, 152),
		"via": [Vector2(-320, 250), Vector2(-360, 400), Vector2(-470, 500), Vector2(-400, 640)],
		"cross": Vector2(-330, 905)},
]

## Roads outside the highway ring: from the far end of link `from_link` through `via` to the far end of link
## `to_link`, or to a T-junction on road `to_road` near `to`.
const OUTER_ROADS := [
	{"name": &"mountain_road", "from_link": &"link_north",
		"via": [Vector2(110, -1230), Vector2(260, -1420), Vector2(540, -1560),
			Vector2(850, -1700), Vector2(1150, -1760), Vector2(1450, -1660), Vector2(1700, -1430),
			Vector2(1820, -1110), Vector2(1760, -800), Vector2(1560, -600), Vector2(1350, -430),
			Vector2(1220, -220), Vector2(1130, -40)],
		"to_link": &"link_east"},
	{"name": &"west_road", "from_link": &"link_southwest",
		"via": [Vector2(-390, 1170), Vector2(-700, 1300), Vector2(-1050, 1230), Vector2(-1330, 980),
			Vector2(-1450, 600), Vector2(-1400, 200), Vector2(-1470, -200), Vector2(-1400, -620),
			Vector2(-1180, -1000), Vector2(-880, -1220), Vector2(-540, -1330), Vector2(-220, -1320)],
		"to_road": &"mountain_road", "to": Vector2(110, -1230)},
]

## Diamond interchange geometry (metres).
const BRIDGE_CLEARANCE := 6.8     ## Link road surface above the highway at the crossing.
const CROSS_STRAIGHT_IN := 90.0   ## The link is straight and square to the highway from here (inside)...
const CROSS_STRAIGHT_OUT := 80.0  ## ...to its end on the outside, where the outer road takes over.
const CROSS_FLAT := 85.0          ## The link is level (at deck height) within this distance of the crossing...
const CROSS_BLEND := 170.0        ## ...and blends back to the terrain-following profile over this distance.
const BRIDGE_HALF := 20.0         ## Half length of the bridge span (abutment faces), from the crossing.
const RAMP_LENGTH := 360.0        ## Along the highway, from the ramp's merge/diverge point to the link road.
const RAMP_TERMINAL := 60.0       ## Distance of the ramp terminals from the highway centreline.
const RAMP_START_OFFSET := 7.5    ## Lateral offset of a ramp's centreline where it leaves the highway.
const RAMP_HALF_WIDTH := 3.6
const RAMP_LANE_HALF := 2.0       ## Edge lines at +-this from a ramp's centreline.

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
var junctions: Array[Vector3] = []  ## Where roads end on another road's edge: (x, z, clearance radius).
## One entry per interchange: {"link": RoadPath, "center": Vector3 (crossing on the highway centreline),
## "along": Vector3 (highway tangent), "across": Vector3 (highway right), "deck": float (link height there),
## "ramps": Array[RoadPath]}.
var interchanges: Array[Dictionary] = []
var _rotors: Array[Node3D] = []


func _ready() -> void:
	generate()


func generate() -> void:
	var start := Time.get_ticks_msec()
	terrain = TerrainData.new(world_seed)
	roads.clear()
	junctions.clear()
	interchanges.clear()

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

	var links := {}
	for def: Dictionary in LINK_ROADS:
		var link := _build_link(def)
		links[link.name] = link
		roads.append(link)
	for def: Dictionary in OUTER_ROADS:
		roads.append(_build_outer_road(def, links))
	for ix in interchanges:
		for ramp: RoadPath in ix.ramps:
			roads.append(ramp)

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
	InterchangeBuilder.build(self, terrain, highway, interchanges)
	var clear_zones: Array[Vector3] = []
	# The terrain's road mask has a hole under each bridge deck: keep rocks and trees off the span and the
	# abutment embankments.
	for ix in interchanges:
		var link: RoadPath = ix.link
		for k in 11:
			var p: Vector3 = link.sample_at(ix.d_cross + (k - 5) * 10.0)[0]
			clear_zones.append(Vector3(p.x, p.z, 13.0))
	_rotors = PropsBuilder.build(self, terrain, roads, clear_zones, world_seed)
	var t_props := Time.get_ticks_msec()
	VegetationBuilder.build(self, terrain, clear_zones, world_seed)
	var t_end := Time.get_ticks_msec()
	print("World generated in %d ms (roads %d, terrain grid %d, terrain mesh %d, roads+props %d, vegetation %d)" % [
		t_end - start, t_roads - start, t_terrain - t_roads, t_mesh - t_terrain, t_props - t_mesh, t_end - t_props])
	for r in roads:
		var st := r.stats()
		print("  road %-22s %5.0f m, min radius %4.0f m, max grade %.1f %%" % [r.name, r.length, st.x, st.y])


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


## Link road from the edge of the country loop to just past the highway, which it crosses square-on on a
## bridge (level at deck height around the crossing). Also builds the interchange's ramps.
func _build_link(def: Dictionary) -> RoadPath:
	var via: Array = def.via
	var a := _junction_point(road, def.from, via[0])
	# Crossing frame: centre on the highway, highway tangent / right, and the side the link comes from.
	var ci := highway.nearest_index(Vector3(def.cross.x, 0.0, def.cross.y))
	var c := highway.points[ci]
	var along := highway.tangents[ci]
	var across := highway.right_at(ci)
	var c2 := Vector2(c.x, c.z)
	var inward := Vector2(across.x, across.z)
	if inward.dot(via[via.size() - 1] - c2) < 0.0:
		inward = -inward
	var controls := PackedVector2Array([a[0], a[0] + a[1] * 14.0])
	for v: Vector2 in via:
		controls.append(v)
	for l: float in [CROSS_STRAIGHT_IN + 40.0, CROSS_STRAIGHT_IN, CROSS_STRAIGHT_IN * 0.5, 0.0,
			-CROSS_STRAIGHT_OUT * 0.5, -CROSS_STRAIGHT_OUT]:
		controls.append(c2 + inward * l)
	var link := _make_country_road(def.name)
	link.closed = false
	link.build(controls, terrain.natural_height, 30, 3, {"start": a[2]})
	# Level at deck height around the crossing, blending into the terrain-following profile.
	var deck := c.y + BRIDGE_CLEARANCE
	var d_cross := link.length - CROSS_STRAIGHT_OUT
	link.flatten(d_cross, CROSS_FLAT, CROSS_BLEND, deck)
	link.bridges.append(Vector2(d_cross - BRIDGE_HALF, d_cross + BRIDGE_HALF))
	link.points[0].y -= 0.04  # Tucks under the loop so the two surfaces don't z-fight.
	junctions.append(Vector3(a[0].x, a[0].y, link.half_width + 4.0))

	var ix := {"link": link, "center": c, "along": along, "across": across, "deck": deck,
		"inward": Vector3(inward.x, 0.0, inward.y), "d_cross": d_cross, "ramps": [] as Array[RoadPath]}
	for side: float in [1.0, -1.0]:
		var tag := "1" if side > 0.0 else "2"
		ix.ramps.append(_build_ramp(StringName("ramp_%s_off%s" % [String(def.name).trim_prefix("link_"), tag]),
				ci, side, false, deck))
		ix.ramps.append(_build_ramp(StringName("ramp_%s_on%s" % [String(def.name).trim_prefix("link_"), tag]),
				ci, side, true, deck))
	interchanges.append(ix)
	return link


## One-way slip road of a diamond interchange on side `side` (+1 = right of the highway tangent at sample
## `ci`, whose traffic drives along increasing distance; -1 = left). In ramp coordinates (a = along the
## direction of travel from the crossing, l = outwards from the centreline), an off-ramp leaves the highway
## at a = -RAMP_LENGTH, l = RAMP_START_OFFSET (hidden under the outer lane), tapers out and swings in a
## gentle S up to the link road, which it meets square-on at l = RAMP_TERMINAL. An on-ramp is its mirror
## image (a -> -a) driven the other way.
func _build_ramp(ramp_name: StringName, ci: int, side: float, on_ramp: bool, deck: float) -> RoadPath:
	var s_c := highway.distances[ci]
	var c := highway.points[ci]
	var along := highway.tangents[ci]
	var across := highway.right_at(ci)
	var edge := road_half_width - 0.6  # Where the ramp ends, from the link's centreline.
	var span := RAMP_LENGTH - 24.0
	var pts: Array[Vector2] = []
	# S-curve, following the highway's own frame (it may bend a little over the ramp's length).
	var steps := int(span / 20.0)
	for k in steps + 1:
		var a := -RAMP_LENGTH + span * k / steps
		var l := RAMP_START_OFFSET + (RAMP_TERMINAL - RAMP_START_OFFSET) * smoothstep(0.0, 1.0, (a + RAMP_LENGTH) / span)
		var h: Array = highway.sample_at(s_c + side * (-a if on_ramp else a))
		var p: Vector3 = h[0]
		var t: Vector3 = h[1]
		var q := p + Vector3(-t.z, 0.0, t.x) * side * l
		pts.append(Vector2(q.x, q.z))
	# Last metres straight and square to the (straight) link road, in the crossing frame.
	for a: float in [-(edge + 14.0), -edge]:
		var q := c + (along * (-a if on_ramp else a) + across * RAMP_TERMINAL) * side
		pts.append(Vector2(q.x, q.z))
	if on_ramp:
		pts.reverse()
	var ramp := RoadPath.new()
	ramp.name = ramp_name
	ramp.closed = false
	ramp.one_way = true
	ramp.half_width = RAMP_HALF_WIDTH
	ramp.lane_width = RAMP_LANE_HALF
	ramp.terrain_reach = 30.0
	ramp.build(PackedVector2Array(pts), terrain.natural_height, 10, 1)
	# Heights: just under the highway surface while alongside it, then a smooth climb to the deck.
	var n := ramp.sample_count()
	var taper := 75.0
	for i in n:
		var d := ramp.distances[i] if not on_ramp else ramp.length - ramp.distances[i]
		var a := -RAMP_LENGTH + d
		var base: float = (highway.sample_at(s_c + side * (-a if on_ramp else a))[0] as Vector3).y - 0.03
		ramp.points[i].y = lerpf(base, deck - 0.04, smoothstep(taper, ramp.length - 12.0, d))
	# Dashed highway edge line where the ramp leaves / joins it.
	var dash_from := s_c + side * (RAMP_LENGTH if on_ramp else -RAMP_LENGTH)
	var dash_to := s_c + side * ((RAMP_LENGTH - taper - 10.0) if on_ramp else (-RAMP_LENGTH + taper + 10.0))
	_add_edge_dash(highway, minf(dash_from, dash_to), maxf(dash_from, dash_to), side)
	var end := ramp.points[n - 1] if not on_ramp else ramp.points[0]
	junctions.append(Vector3(end.x, end.z, ramp.half_width + 3.0))
	return ramp


static func _add_edge_dash(r: RoadPath, from: float, to: float, side: float) -> void:
	from = fposmod(from, r.length)
	to = fposmod(to, r.length)
	if to >= from:
		r.edge_dashes.append(Vector3(from, to, side))
	else:  # Wraps around the loop's start.
		r.edge_dashes.append(Vector3(from, r.length, side))
		r.edge_dashes.append(Vector3(0.0, to, side))


## Outer road from the far end of a link road (continuing it seamlessly, level at deck height at first) to
## the far end of another link or a T-junction on another road.
func _build_outer_road(def: Dictionary, links: Dictionary) -> RoadPath:
	var from_link: RoadPath = links[def.from_link]
	var from_ix := _interchange_of(from_link)
	var p0 := from_link.points[from_link.sample_count() - 1]
	var out0: Vector3 = -from_ix.inward
	var controls := PackedVector2Array([Vector2(p0.x, p0.z), Vector2(p0.x + out0.x * 30.0, p0.z + out0.z * 30.0)])
	for v: Vector2 in def.via:
		controls.append(v)
	var outer := _make_country_road(def.name)
	outer.closed = false
	outer.terrain_reach = 40.0
	var to_ix := {}
	var t_end := []
	if def.has("to_link"):
		var to_link: RoadPath = links[def.to_link]
		to_ix = _interchange_of(to_link)
		var p1 := to_link.points[to_link.sample_count() - 1]
		var out1: Vector3 = -to_ix.inward
		controls.append(Vector2(p1.x + out1.x * 30.0, p1.z + out1.z * 30.0))
		controls.append(Vector2(p1.x, p1.z))
	else:
		var target: RoadPath = null
		for r in roads:
			if r.name == def.to_road:
				target = r
		t_end = _junction_point(target, def.to, def.via[def.via.size() - 1])
		controls.append(t_end[0] + t_end[1] * 14.0)
		controls.append(t_end[0])
	var pins := {"end": t_end[2]} if not t_end.is_empty() else {}
	outer.build(controls, terrain.natural_height, 90, 3, pins)
	outer.flatten(-CROSS_STRAIGHT_OUT, CROSS_FLAT, CROSS_BLEND, from_ix.deck)
	if not to_ix.is_empty():
		outer.flatten(outer.length + CROSS_STRAIGHT_OUT, CROSS_FLAT, CROSS_BLEND, to_ix.deck)
	else:
		var last := outer.sample_count() - 1
		outer.points[last].y -= 0.04
		junctions.append(Vector3(t_end[0].x, t_end[0].y, outer.half_width + 4.0))
	return outer


func _interchange_of(link: RoadPath) -> Dictionary:
	for ix in interchanges:
		if ix.link == link:
			return ix
	return {}


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
		# Prefer the road at the car's level (the highway under a bridge, not the bridge itself).
		d += maxf(absf(r.points[i].y - pos.y) - 2.0, 0.0) * 4.0
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
