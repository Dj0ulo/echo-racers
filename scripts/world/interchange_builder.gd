class_name InterchangeBuilder
extends RefCounted
## Concrete structures of the diamond interchanges (see WorldGenerator): the bridge carrying each link road
## over the highway — deck slab, parapets, a pier in the median, abutments with wing walls — and their
## colliders. The road surfaces themselves (link, ramps) are ordinary RoadPaths built by RoadBuilder.

const CONCRETE := Color(0.74, 0.73, 0.70)
const DECK_DEPTH := 1.2       ## Deck slab thickness below the road surface.
const DECK_OVERHANG := 0.6    ## Slab width past the asphalt edge.
const PARAPET_HEIGHT := 0.95
const PARAPET_WIDTH := 0.35
const PARAPET_EXTRA := 10.0   ## Parapets run this far past the bridge ends, onto the approach embankments.
const WING_LENGTH := 16.0     ## Wing walls along the highway, either side of each abutment.


static func build(parent: Node3D, terrain: TerrainData, highway: RoadPath, interchanges: Array[Dictionary]) -> void:
	if interchanges.is_empty():
		return
	var root := Node3D.new()
	root.name = "Interchanges"
	root.set_meta(&"surface", &"road")
	parent.add_child(root)
	var mb := MeshBuilder.new()
	var colliders := ColliderBatch.new(400.0)
	for ix in interchanges:
		_build_bridge(mb, colliders, terrain, highway, ix)
	var mesh := MeshInstance3D.new()
	mesh.name = "Bridges"
	mesh.mesh = mb.commit(Palette.vertex_material(0.9))
	root.add_child(mesh)
	colliders.commit(root)


static func _build_bridge(mb: MeshBuilder, colliders: ColliderBatch, terrain: TerrainData, highway: RoadPath,
		ix: Dictionary) -> void:
	var link: RoadPath = ix.link
	var c: Vector3 = ix.center
	var along: Vector3 = ix.along
	var inward: Vector3 = ix.inward
	var deck: float = ix.deck
	var d_cross: float = ix.d_cross
	var hw := link.half_width
	var n := link.sample_count()

	# Deck slab: sides and underside, following the link's samples over the span.
	var half := WorldGenerator.BRIDGE_HALF
	var i0 := clampi(int((d_cross - half - 1.0) / link.step), 0, n - 2)
	var i1 := clampi(int(ceilf((d_cross + half + 1.0) / link.step)), 1, n - 1)
	var down := Vector3.DOWN * DECK_DEPTH
	for i in range(i0, i1):
		var p0 := link.points[i]
		var p1 := link.points[i + 1]
		var r0 := link.right_at(i) * (hw + DECK_OVERHANG)
		var r1 := link.right_at(i + 1) * (hw + DECK_OVERHANG)
		mb.add_quad_facing(p0 + r0, p1 + r1, p1 + r1 + down, p0 + r0 + down, r0, CONCRETE)
		mb.add_quad_facing(p0 - r0, p1 - r1, p1 - r1 + down, p0 - r0 + down, -r0, CONCRETE)
		mb.add_quad_facing(p0 - r0 + down, p1 - r1 + down, p1 + r1 + down, p0 + r0 + down, Vector3.DOWN,
				CONCRETE.darkened(0.25))
	# Bridge ends (the slab's end faces show against the abutment).
	for i: int in [i0, i1]:
		var p := link.points[i]
		var r := link.right_at(i) * (hw + DECK_OVERHANG)
		var facing := -link.tangents[i] if i == i0 else link.tangents[i]
		mb.add_quad_facing(p - r, p + r, p + r + down, p - r + down, facing, CONCRETE.darkened(0.1))

	# Parapets along both sides, over the span and a little onto the approaches.
	var j0 := clampi(int((d_cross - half - PARAPET_EXTRA) / link.step), 0, n - 1)
	var j1 := clampi(int((d_cross + half + PARAPET_EXTRA) / link.step), 0, n - 1)
	for side: float in [-1.0, 1.0]:
		for i in range(j0, j1, 2):
			var e := mini(i + 2, j1)
			var off := hw + DECK_OVERHANG - PARAPET_WIDTH * 0.5
			var a := link.points[i] + link.right_at(i) * side * off
			var b := link.points[e] + link.right_at(e) * side * off
			var span := b - a
			var basis := Basis.looking_at(span, Vector3.UP)
			var center := (a + b) * 0.5 + Vector3.UP * (PARAPET_HEIGHT * 0.5 - 0.15)
			var size := Vector3(PARAPET_WIDTH, PARAPET_HEIGHT + 0.3, span.length() + 0.04)
			mb.add_box(center, size, CONCRETE.lightened(0.05), basis)
			colliders.add_box(center, basis, size)

	# Pier in the median, square under the deck.
	var pier_basis := Basis.looking_at(along, Vector3.UP)
	var pier_top := deck - DECK_DEPTH
	var pier_bottom := c.y - 0.6
	var pier_center := Vector3(c.x, (pier_top + pier_bottom) * 0.5, c.z)
	var pier_size := Vector3(1.2, pier_top - pier_bottom, hw * 2.0 - 1.0)
	mb.add_box(pier_center, pier_size, CONCRETE.darkened(0.05), pier_basis)
	colliders.add_box(pier_center, pier_basis, pier_size)
	# Pier cap, a little wider than the pier.
	var cap_center := Vector3(c.x, pier_top - 0.3, c.z)
	mb.add_box(cap_center, Vector3(2.0, 0.6, hw * 2.0 + 1.0), CONCRETE, pier_basis)

	# Abutments at both ends of the span, with wing walls retaining the embankment along the highway verge.
	for end: float in [-1.0, 1.0]:
		var face := c + inward * end * half
		var ground := c.y - 2.0
		var top := deck - 0.15
		var abut_center := face + inward * end * 1.5
		abut_center.y = (top + ground) * 0.5
		var abut_size := Vector3(3.0, top - ground, hw * 2.0 + 2.0 * DECK_OVERHANG + 1.0)
		mb.add_box(abut_center, abut_size, CONCRETE.darkened(0.08), pier_basis)
		colliders.add_box(abut_center, pier_basis, abut_size)
		for side: float in [-1.0, 1.0]:
			var start := face + inward * end * 0.4 + along * side * (abut_size.z * 0.5)
			var steps := 4
			for k in steps:
				var t0 := float(k) / steps
				var t1 := float(k + 1) / steps
				var a := start + along * side * WING_LENGTH * t0
				var b := start + along * side * WING_LENGTH * t1
				# The wall top follows the embankment down from deck height.
				# Sampled just behind the wall: the embankment ends in a vertical cut along the abutment line.
				var ba := a + inward * end * 1.5
				var bb := b + inward * end * 1.5
				var h0 := lerpf(top, maxf(terrain.get_height(ba.x, ba.z) + 0.6, c.y + 0.8), t0)
				var h1 := lerpf(top, maxf(terrain.get_height(bb.x, bb.z) + 0.6, c.y + 0.8), t1)
				var h := maxf(h0, h1)
				var center := (a + b) * 0.5
				center.y = (h + ground) * 0.5
				var size := Vector3(0.8, h - ground, WING_LENGTH / steps + 0.02)
				mb.add_box(center, size, CONCRETE.darkened(0.08), pier_basis)
				colliders.add_box(center, pier_basis, size)

