class_name EchoPoint
extends Node3D
## Neon blue beacon at the start of a saved echo course: a tall light beam, glowing ground rings with rising
## sparks, an arrow along the start direction and a floating name / best-time sign. Driving into it lets the
## Y menu race its echoes.

const RADIUS := 12.0
const BEAM_HEIGHT := 160.0

var track: EchoTrack

var _label: Label3D
var _ring: ShaderMaterial
var _time := 0.0


func setup(p_track: EchoTrack, ground: Transform3D) -> void:
	track = p_track
	global_transform = ground
	var beam := CylinderMesh.new()
	beam.top_radius = 2.4
	beam.bottom_radius = 2.4
	beam.height = BEAM_HEIGHT
	beam.cap_top = false
	beam.cap_bottom = false
	beam.radial_segments = 24
	beam.rings = 1
	_add(beam, Vector3(0, BEAM_HEIGHT * 0.5, 0), Neon.beam_material(Neon.CYAN, BEAM_HEIGHT, 1.6, 14.0))
	var core := CylinderMesh.new()
	core.top_radius = 0.5
	core.bottom_radius = 0.5
	core.height = 40.0
	core.cap_top = false
	core.cap_bottom = false
	core.radial_segments = 12
	core.rings = 1
	_add(core, Vector3(0, 20.0, 0), Neon.beam_material(Neon.BLUE, 40.0, 2.5, 4.0))

	_ring = Neon.glow_material(Neon.CYAN, 2.4)
	for r: float in [RADIUS, RADIUS * 0.55]:
		var torus := TorusMesh.new()
		torus.inner_radius = r - 0.2
		torus.outer_radius = r + 0.2
		torus.rings = 64
		torus.ring_segments = 6
		_add(torus, Vector3(0, 0.25, 0), _ring)

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

	var sparks := Neon.sparks(Neon.CYAN, Vector3.ZERO, 40, RADIUS)
	sparks.position.y = 0.3
	add_child(sparks)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 64
	_label.pixel_size = 0.05
	_label.outline_size = 14
	_label.outline_modulate = Color(0.0, 0.03, 0.08, 0.85)
	_label.modulate = Neon.CYAN.lightened(0.4)
	_label.position = Vector3(0, 10.0, 0)
	_label.visibility_range_end = 450.0
	add_child(_label)
	refresh()


func refresh() -> void:
	_label.text = "%s\nbest %s · %d echo%s" % [track.name, EchoRun.format_time(track.best_time()), track.runs.size(),
		"" if track.runs.size() == 1 else "es"]


func _process(delta: float) -> void:
	_time += delta
	_ring.set_shader_parameter(&"energy", 2.0 + 0.8 * sin(_time * 3.0))


func _add(mesh: Mesh, pos: Vector3, mat: ShaderMaterial) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
