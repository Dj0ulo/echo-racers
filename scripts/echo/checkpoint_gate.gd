class_name CheckpointGate
extends Node3D
## One neon checkpoint of an echo course. RINGS: a glowing circle on the ground with a translucent light
## cylinder rising from it. GATES: two neon light pillars either side of the racing line, with a few sparks.
## The origin sits on the ground, -Z along the direction of travel; the car passes it by crossing the plane
## through its centre within `radius` (see `crossing`).

enum Kind { CHECKPOINT, START, FINISH }
enum State { UPCOMING, NEXT, PASSED, PREVIEW }

const HEIGHT := 7.0
const AIR_REACH := 12.0  ## Hitbox top above the gate's ground point (car centre), a few metres over the light wall.
const GROUND_REACH := 3.0  ## Hitbox bottom below the ground point (slopes, dips under the gate).

var radius := 9.0
var kind := Kind.CHECKPOINT

var _state := State.PREVIEW
var _glow: Array[ShaderMaterial] = []
var _beams: Array[ShaderMaterial] = []
var _particles: Array[GPUParticles3D] = []
var _label: Label3D
var _time := 0.0


## `marker`: editor mode, the label stays readable from far above (fixed size, drawn on top).
func setup(style: int, p_kind: Kind, number: int, p_radius: float, marker := false) -> void:
	radius = p_radius
	kind = p_kind
	if style == EchoTrack.Style.RINGS:
		_build_ring()
	else:
		_build_gate()
	_label = Label3D.new()
	_label.text = "START" if kind == Kind.START else ("FINISH" if kind == Kind.FINISH else str(number))
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 72
	_label.outline_size = 14
	_label.outline_modulate = Color(0.0, 0.03, 0.08, 0.85)
	_label.position = Vector3(0, HEIGHT + 1.6, 0)
	if marker:
		_label.fixed_size = true
		_label.pixel_size = 0.0004
		_label.no_depth_test = true
		_label.render_priority = 10
		_label.outline_render_priority = 9
	else:
		_label.pixel_size = 0.03
	add_child(_label)
	set_state(State.PREVIEW)


func set_state(s: State) -> void:
	_state = s
	visible = s != State.PASSED
	for p in _particles:
		p.emitting = s == State.NEXT or s == State.PREVIEW
	_label.visible = s != State.UPCOMING
	set_process(s == State.NEXT)
	_apply(1.0)


func _process(delta: float) -> void:
	_time += delta
	_apply(0.85 + 0.3 * sin(_time * 6.0))


func _apply(pulse: float) -> void:
	var col := _color()
	var e := 0.2
	match _state:
		State.NEXT:
			e = pulse
		State.PREVIEW:
			e = 0.8
	for m in _glow:
		m.set_shader_parameter(&"color", col)
		m.set_shader_parameter(&"energy", 2.4 * e)
	for m in _beams:
		m.set_shader_parameter(&"color", col)
		m.set_shader_parameter(&"energy", 1.1 * e)
	_label.modulate = col.lightened(0.35)


func _color() -> Color:
	match kind:
		Kind.START:
			return Neon.START
		Kind.FINISH:
			return Neon.FINISH
	return Neon.CYAN if _state != State.UPCOMING else Neon.BLUE


func _build_ring() -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.22
	torus.outer_radius = radius + 0.22
	torus.rings = 72
	torus.ring_segments = 6
	_glow.append(_add_mesh(torus, Vector3(0, 0.2, 0), Neon.glow_material(Neon.CYAN)))
	var wall := CylinderMesh.new()
	wall.top_radius = radius
	wall.bottom_radius = radius
	wall.height = HEIGHT
	wall.cap_top = false
	wall.cap_bottom = false
	wall.radial_segments = 64
	wall.rings = 1
	_beams.append(_add_mesh(wall, Vector3(0, HEIGHT * 0.5, 0), Neon.beam_material(Neon.CYAN, HEIGHT)))
	var sparks := Neon.sparks(Neon.CYAN, Vector3.ZERO, 24, radius)
	sparks.position.y = 0.2
	add_child(sparks)
	_particles.append(sparks)


func _build_gate() -> void:
	for side: float in [-1.0, 1.0]:
		var x := side * radius
		var pillar := CylinderMesh.new()
		pillar.top_radius = 0.16
		pillar.bottom_radius = 0.2
		pillar.height = HEIGHT
		pillar.radial_segments = 8
		pillar.rings = 1
		_glow.append(_add_mesh(pillar, Vector3(x, HEIGHT * 0.5, 0), Neon.glow_material(Neon.CYAN)))
		var halo := CylinderMesh.new()
		halo.top_radius = 0.8
		halo.bottom_radius = 0.8
		halo.height = HEIGHT
		halo.cap_top = false
		halo.cap_bottom = false
		halo.radial_segments = 16
		halo.rings = 1
		_beams.append(_add_mesh(halo, Vector3(x, HEIGHT * 0.5, 0), Neon.beam_material(Neon.CYAN, HEIGHT, 1.0, 3.0)))
		var foot := TorusMesh.new()
		foot.inner_radius = 0.5
		foot.outer_radius = 0.66
		foot.rings = 16
		foot.ring_segments = 4
		_glow.append(_add_mesh(foot, Vector3(x, 0.1, 0), Neon.glow_material(Neon.CYAN)))
		var sparks := Neon.sparks(Neon.CYAN, Vector3(0.35, 0.4, 0.35), 10)
		sparks.position = Vector3(x, 0.6, 0)
		add_child(sparks)
		_particles.append(sparks)


func _add_mesh(mesh: Mesh, pos: Vector3, mat: ShaderMaterial) -> ShaderMaterial:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mat


## Fraction (0..1) along the segment a -> b where it crosses the checkpoint whose ground point is `ground`, going
## along `dir` within `r` of the centre, or -1 if it does not. The hitbox is a cylinder from a little below the
## ground up to `AIR_REACH` metres above it, so a car flying over the gate still counts.
static func crossing(ground: Vector3, dir: Vector3, r: float, a: Vector3, b: Vector3) -> float:
	var n := Vector3(dir.x, 0.0, dir.z)
	if n.length_squared() < 1e-6:
		return -1.0
	n = n.normalized()
	var sa := (a - ground).dot(n)
	var sb := (b - ground).dot(n)
	if not (sa < 0.0 and sb >= 0.0):
		return -1.0
	var u := sa / (sa - sb)
	var q := a.lerp(b, u)
	var h := q.y - ground.y
	if Vector2(q.x - ground.x, q.z - ground.z).length() > r or h < -GROUND_REACH or h > AIR_REACH:
		return -1.0
	return u


## Ground pose under a car-centre position `pos` facing `dir` (ray down onto the world layer).
static func ground_xform(space: PhysicsDirectSpaceState3D, pos: Vector3, dir: Vector3) -> Transform3D:
	var y := pos.y - 0.7
	if space:
		var query := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 1.0, pos + Vector3.DOWN * 40.0, 1)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			y = (hit.position as Vector3).y
	var f := Vector3(dir.x, 0.0, dir.z)
	if f.length_squared() < 1e-6:
		f = Vector3.FORWARD
	return Transform3D(Basis.looking_at(f.normalized(), Vector3.UP), Vector3(pos.x, y, pos.z))
