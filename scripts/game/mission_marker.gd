class_name MissionMarker
extends Node3D
## Lime neon marker of a delivery (MissionManager): an offer is a glowing post with a spinning parcel on top, a
## pulsing ground ring of the trigger radius and a sign (reward, distance); the active delivery's drop-off adds
## a tall light beam so it can be seen from afar.

const POST_HEIGHT := 4.0

var _label: Label3D
var _ring: ShaderMaterial
var _parcel: Node3D
var _time := 0.0


## `ground`: marker position on the road. `radius`: trigger ring. `beam_height` > 0 adds a light beam.
func setup(ground: Vector3, radius: float, text: String, beam_height := 0.0) -> void:
	position = ground
	var col := MissionManager.COLOR
	var post := CylinderMesh.new()
	post.top_radius = 0.14
	post.bottom_radius = 0.14
	post.height = POST_HEIGHT
	post.cap_top = false
	post.cap_bottom = false
	post.radial_segments = 8
	post.rings = 1
	_add(post, Vector3(0, POST_HEIGHT * 0.5, 0), Neon.beam_material(col, POST_HEIGHT, 1.3, 2.0), self)

	_ring = Neon.glow_material(col, 1.3)
	for r: float in [radius, radius * 0.45]:
		var torus := TorusMesh.new()
		torus.inner_radius = r - 0.12
		torus.outer_radius = r + 0.12
		torus.rings = 64
		torus.ring_segments = 4
		_add(torus, Vector3(0, 0.25, 0), _ring, self)

	# The parcel: a box with a strap, hovering and turning above the post.
	_parcel = Node3D.new()
	_parcel.position.y = POST_HEIGHT + 0.9
	add_child(_parcel)
	var box := BoxMesh.new()
	box.size = Vector3(1.3, 0.9, 1.0)
	_add(box, Vector3.ZERO, Neon.hologram_material(col, 1.2), _parcel)
	var strap := BoxMesh.new()
	strap.size = Vector3(0.22, 0.95, 1.05)
	_add(strap, Vector3.ZERO, Neon.glow_material(col.lightened(0.5), 2.2), _parcel)

	if beam_height > 0.0:
		var beam := CylinderMesh.new()
		beam.top_radius = 2.2
		beam.bottom_radius = 2.2
		beam.height = beam_height
		beam.cap_top = false
		beam.cap_bottom = false
		beam.radial_segments = 20
		beam.rings = 1
		_add(beam, Vector3(0, beam_height * 0.5, 0), Neon.beam_material(col, beam_height, 1.6, 10.0), self)

	var sparks := Neon.sparks(col, Vector3.ZERO, 10, radius * 0.45)
	sparks.position.y = 0.3
	add_child(sparks)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 44
	_label.pixel_size = 0.02
	_label.outline_size = 14
	_label.outline_modulate = Color(0.03, 0.06, 0.0, 0.85)
	_label.modulate = col.lightened(0.45)
	_label.position = Vector3(0, POST_HEIGHT + 2.6, 0)
	_label.visibility_range_end = 260.0
	_label.text = text
	add_child(_label)


func _process(delta: float) -> void:
	_time += delta
	_ring.set_shader_parameter(&"energy", 1.2 + 0.5 * sin(_time * 3.2))
	_parcel.rotation.y = _time * 1.2
	_parcel.position.y = POST_HEIGHT + 0.9 + 0.25 * sin(_time * 2.0)


func _add(mesh: Mesh, pos: Vector3, mat: ShaderMaterial, parent: Node3D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
