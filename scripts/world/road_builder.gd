class_name RoadBuilder
extends RefCounted
## Builds the asphalt ribbon (markings drawn by shader), its bevelled edges and its collider.

const ROAD_SHADER := preload("res://shaders/road.gdshader")
const EDGE_OUT := 0.45
const EDGE_DOWN := 0.7


static func build(parent: Node3D, road: RoadPath) -> void:
	var top := MeshBuilder.new()
	top.use_uvs = true
	var edges := MeshBuilder.new()
	var faces := PackedVector3Array()
	var hw := road.half_width
	var n := road.sample_count()
	var segments := n if road.closed else n - 1

	for s in segments:
		var e := (s + 1) % n
		var p0 := road.points[s]
		var p1 := road.points[e]
		var r0 := road.right_at(s)
		var r1 := road.right_at(e)
		var l0 := p0 - r0 * hw
		var l1 := p1 - r1 * hw
		var rr0 := p0 + r0 * hw
		var rr1 := p1 + r1 * hw
		var v0 := road.distances[s]
		var v1 := v0 + p0.distance_to(p1)

		top.add_triangle_facing(l0, rr0, rr1, Vector3.UP, Palette.WHITE, Vector2(0, v0), Vector2(1, v0), Vector2(1, v1))
		top.add_triangle_facing(l0, rr1, l1, Vector3.UP, Palette.WHITE, Vector2(0, v0), Vector2(1, v1), Vector2(0, v1))
		faces.append_array([l0, rr0, rr1, l0, rr1, l1])

		var down := Vector3.DOWN * EDGE_DOWN
		edges.add_quad_facing(l0, l1, l1 - r1 * EDGE_OUT + down, l0 - r0 * EDGE_OUT + down, -r0, Palette.CURB)
		edges.add_quad_facing(rr0, rr1, rr1 + r1 * EDGE_OUT + down, rr0 + r0 * EDGE_OUT + down, r0, Palette.CURB)

	var material := ShaderMaterial.new()
	material.shader = ROAD_SHADER
	material.set_shader_parameter(&"road_width", hw * 2.0)
	material.set_shader_parameter(&"lanes_per_side", road.lanes_per_side)
	material.set_shader_parameter(&"lane_width", road.lane_width)
	material.set_shader_parameter(&"median_width", road.median_width)
	material.set_shader_parameter(&"dash_length", road.dash_length)
	material.set_shader_parameter(&"dash_gap", road.dash_gap)
	material.set_shader_parameter(&"one_way", road.one_way)
	material.set_shader_parameter(&"edge_dash_count", mini(road.edge_dashes.size(), 16))
	if not road.edge_dashes.is_empty():
		material.set_shader_parameter(&"edge_dashes", road.edge_dashes.slice(0, 16))

	var road_mesh := MeshInstance3D.new()
	road_mesh.name = "Road_%s" % road.name
	road_mesh.mesh = top.commit(material)
	road_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(road_mesh)

	var edge_mesh := MeshInstance3D.new()
	edge_mesh.name = "RoadEdges_%s" % road.name
	edge_mesh.mesh = edges.commit(Palette.vertex_material(0.9))
	edge_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(edge_mesh)

	var body := StaticBody3D.new()
	body.name = "RoadBody_%s" % road.name
	body.set_meta(&"surface", &"road")
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
