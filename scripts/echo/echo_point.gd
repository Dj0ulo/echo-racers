class_name EchoPoint
extends Node3D
## Discreet neon blue marker at the start of a saved echo course: a short glowing post, a thin ground ring with
## a few sparks, chevrons along the start direction and a small name / best-time sign. Driving into it lets the
## Y menu race its echoes.

const RADIUS := 12.0       ## Trigger radius (Y menu available inside).
const RING_RADIUS := 4.0   ## Visible ground ring.
const POST_HEIGHT := 3.5

var track: EchoTrack

var _label: Label3D
var _ring: ShaderMaterial
var _time := 0.0


func setup(p_track: EchoTrack, ground: Transform3D) -> void:
	track = p_track
	global_transform = ground
	# A short, thin marker post: findable up close without dominating the skyline.
	var post := CylinderMesh.new()
	post.top_radius = 0.12
	post.bottom_radius = 0.12
	post.height = POST_HEIGHT
	post.cap_top = false
	post.cap_bottom = false
	post.radial_segments = 8
	post.rings = 1
	_add(post, Vector3(0, POST_HEIGHT * 0.5, 0), Neon.beam_material(Neon.CYAN, POST_HEIGHT, 1.2, 2.0))

	_ring = Neon.glow_material(Neon.CYAN, 1.2)
	var torus := TorusMesh.new()
	torus.inner_radius = RING_RADIUS - 0.08
	torus.outer_radius = RING_RADIUS + 0.08
	torus.rings = 48
	torus.ring_segments = 4
	_add(torus, Vector3(0, 0.12, 0), _ring)

	# Chevrons on the ground pointing the way the course starts (-Z).
	var arrow := ArrayMesh.new()
	var verts := PackedVector3Array()
	for k in 3:
		var z := -2.0 - k * 2.2
		verts.append_array([Vector3(-1.6, 0, z + 1.2), Vector3(0, 0, z), Vector3(0, 0, z + 0.7),
			Vector3(-1.6, 0, z + 1.2), Vector3(0, 0, z + 0.7), Vector3(-1.6, 0, z + 1.9),
			Vector3(1.6, 0, z + 1.2), Vector3(0, 0, z + 0.7), Vector3(0, 0, z),
			Vector3(1.6, 0, z + 1.2), Vector3(1.6, 0, z + 1.9), Vector3(0, 0, z + 0.7)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrow.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_add(arrow, Vector3(0, 0.2, 0), _ring)

	var sparks := Neon.sparks(Neon.CYAN, Vector3.ZERO, 10, RING_RADIUS)
	sparks.position.y = 0.2
	add_child(sparks)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 48
	_label.pixel_size = 0.025
	_label.outline_size = 14
	_label.outline_modulate = Color(0.0, 0.03, 0.08, 0.85)
	_label.modulate = Neon.CYAN.lightened(0.4)
	_label.position = Vector3(0, POST_HEIGHT + 1.2, 0)
	_label.visibility_range_end = 180.0
	add_child(_label)
	refresh()


func refresh() -> void:
	_label.text = "%s\nbest %s · %d echo%s" % [track.name, EchoRun.format_time(track.best_time()), track.runs.size(),
		"" if track.runs.size() == 1 else "es"]


func _process(delta: float) -> void:
	_time += delta
	_ring.set_shader_parameter(&"energy", 1.1 + 0.4 * sin(_time * 3.0))


func _add(mesh: Mesh, pos: Vector3, mat: ShaderMaterial) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
