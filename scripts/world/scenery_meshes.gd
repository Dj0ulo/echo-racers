class_name SceneryMeshes
extends RefCounted
## Procedural low-poly meshes for vegetation and props. Origins sit at ground level.

const GRASS_SHADER := preload("res://shaders/grass.gdshader")

static var _grass_material: ShaderMaterial


static func cylinder(bottom_radius: float, top_radius: float, height: float, sides: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.bottom_radius = bottom_radius
	m.top_radius = top_radius
	m.height = height
	m.radial_segments = sides
	m.rings = 0
	m.cap_top = top_radius > 0.0
	return m


static func sphere(radius: float, height: float, sides: int, rings: int) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = height
	m.radial_segments = sides
	m.rings = rings
	return m


static func pine_tree() -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_primitive(cylinder(0.26, 0.18, 1.6, 6), Transform3D(Basis(), Vector3(0, 0.8, 0)), Palette.TRUNK)
	var y := 1.2
	for k in 3:
		var radius := 2.0 - k * 0.5
		var height := 2.5 - k * 0.35
		var basis := Basis(Vector3.UP, k * 0.7)
		mb.add_primitive(cylinder(radius, 0.0, height, 7), Transform3D(basis, Vector3(0, y + height * 0.5, 0)),
				Palette.PINE.lerp(Palette.PINE_LIGHT, k * 0.4), 0.1, 0.06)
		y += height * 0.55
	return mb.commit(Palette.vertex_material(0.95))


static func broadleaf_tree(leaf_color: Color) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_primitive(cylinder(0.26, 0.16, 2.8, 6), Transform3D(Basis(), Vector3(0, 1.4, 0)), Palette.TRUNK)
	mb.add_primitive(cylinder(0.08, 0.04, 1.2, 4), Transform3D(Basis(Vector3.FORWARD, -0.7), Vector3(0.4, 2.6, 0)), Palette.TRUNK)
	mb.add_primitive(sphere(1.9, 3.3, 7, 4), Transform3D(Basis(), Vector3(0, 3.9, 0)), leaf_color, 0.22, 0.06)
	mb.add_primitive(sphere(1.25, 2.1, 6, 3), Transform3D(Basis(Vector3.UP, 1.0), Vector3(1.1, 3.4, 0.5)),
			leaf_color.lightened(0.06), 0.18, 0.06)
	return mb.commit(Palette.vertex_material(0.95))


static func rock() -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_primitive(sphere(1.0, 1.4, 6, 3), Transform3D(), Palette.ROCK, 0.28, 0.08)
	return mb.commit(Palette.vertex_material(0.9))


static func grass_material() -> ShaderMaterial:
	if _grass_material == null:
		_grass_material = ShaderMaterial.new()
		_grass_material.shader = GRASS_SHADER
	return _grass_material


## A tuft of a few leaning blades. Normals point up so tufts shade like the ground under them.
static func grass_tuft(flower_color := Color(0, 0, 0, 0)) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var blades := 5
	for k in blades:
		var angle := k * TAU / blades + 0.4 * sin(k * 7.0)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var side := Vector3(-dir.z, 0.0, dir.x)
		var base := dir * 0.06
		var height := 0.45 + 0.15 * sin(k * 3.1)
		var tip := base + dir * 0.22 + Vector3.UP * height
		var root_col := Palette.GRASS_DARK.darkened(0.15)
		var tip_col := Palette.GRASS_LIGHT.lightened(0.08)
		mb.add_triangle_shaded(base - side * 0.06, base + side * 0.06, tip, root_col, root_col, tip_col, Vector3.UP)
	if flower_color.a > 0.0:
		for k in 3:
			var angle := k * TAU / 3.0
			var c := Vector3(cos(angle) * 0.12, 0.5 + 0.06 * k, sin(angle) * 0.12)
			var s := 0.07
			mb.add_triangle_shaded(c + Vector3(-s, 0, 0), c + Vector3(0, 0.02, s), c + Vector3(s, 0, 0),
					flower_color, flower_color, flower_color, Vector3.UP)
			mb.add_triangle_shaded(c + Vector3(-s, 0, 0), c + Vector3(s, 0, 0), c + Vector3(0, 0.02, -s),
					flower_color, flower_color, flower_color, Vector3.UP)
	return mb.commit(grass_material())


static func marker_post() -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_box(Vector3(0, 0.5, 0), Vector3(0.12, 1.0, 0.12), Palette.WHITE)
	mb.add_box(Vector3(0, 0.86, 0), Vector3(0.13, 0.2, 0.13), Palette.BLACK)
	mb.add_box(Vector3(0, 0.74, 0), Vector3(0.14, 0.08, 0.14), Palette.REFLECTOR)
	return mb.commit(Palette.vertex_material(0.6))


## Fence section spanning 1 m along -Z (scaled along Z by the instance transform).
static func fence_section() -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_box(Vector3(0, 0.6, 0), Vector3(0.14, 1.2, 0.14), Palette.WOOD.darkened(0.1))
	mb.add_box(Vector3(0, 0.95, -0.5), Vector3(0.06, 0.12, 1.0), Palette.WOOD)
	mb.add_box(Vector3(0, 0.55, -0.5), Vector3(0.06, 0.12, 1.0), Palette.WOOD)
	return mb.commit(Palette.vertex_material(0.95))


static func hay_bale() -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_primitive(cylinder(0.75, 0.75, 1.3, 10), Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0, 0.75, 0)),
			Palette.HAY, 0.0, 0.05)
	return mb.commit(Palette.vertex_material(1.0))


## Barn: walls `width` x `depth`, wall height `wall_height`, gable roof along Z, door facing -Z.
static func barn(width: float, depth: float, wall_height: float) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var hw := width * 0.5
	var hd := depth * 0.5
	mb.add_box(Vector3(0, wall_height * 0.5, 0), Vector3(width, wall_height, depth), Palette.BARN_RED)
	# Gables
	var ridge := wall_height + width * 0.38
	for zs in [-hd, hd]:
		mb.add_triangle_facing(Vector3(-hw, wall_height, zs), Vector3(hw, wall_height, zs), Vector3(0, ridge, zs),
				Vector3(0, 0, signf(zs)), Palette.BARN_RED)
	# Roof slopes with overhang
	var o := 0.5
	for xs in [-1.0, 1.0]:
		var eave_x: float = xs * (hw + o)
		var eave_y := wall_height - o * 0.76
		var a := Vector3(eave_x, eave_y, -hd - o)
		var b := Vector3(eave_x, eave_y, hd + o)
		var c := Vector3(0, ridge + 0.05, hd + o)
		var d := Vector3(0, ridge + 0.05, -hd - o)
		mb.add_quad_facing(a, b, c, d, Vector3(xs, 1.2, 0), Palette.ROOF)
		mb.add_quad_facing(a, b, c, d, Vector3(-xs, -1.2, 0), Palette.ROOF.darkened(0.3))
	# Door with white trim
	var door_w := width * 0.45
	var door_h := wall_height * 0.75
	var front := -hd - 0.03
	mb.add_box(Vector3(0, door_h * 0.5, front), Vector3(door_w, door_h, 0.06), Palette.BARN_RED.darkened(0.25))
	mb.add_box(Vector3(0, door_h, front - 0.02), Vector3(door_w + 0.3, 0.18, 0.08), Palette.WHITE)
	for xs in [-1.0, 1.0]:
		mb.add_box(Vector3(xs * door_w * 0.5, door_h * 0.5, front - 0.02), Vector3(0.18, door_h, 0.08), Palette.WHITE)
	var diag := Vector2(door_w, door_h).length()
	var angle := atan2(door_h, door_w)
	for sgn in [-1.0, 1.0]:
		mb.add_box(Vector3(0, door_h * 0.5, front - 0.04), Vector3(diag, 0.14, 0.06), Palette.WHITE,
				Basis(Vector3.BACK, sgn * angle))
	# Corner trim
	for xs in [-1.0, 1.0]:
		for zs in [-1.0, 1.0]:
			mb.add_box(Vector3(xs * hw, wall_height * 0.5, zs * hd), Vector3(0.22, wall_height, 0.22), Palette.WHITE)
	return mb.commit(Palette.vertex_material(0.9))


static func silo(radius: float, height: float) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_primitive(cylinder(radius, radius, height, 12), Transform3D(Basis(), Vector3(0, height * 0.5, 0)), Palette.SILO, 0.0, 0.03)
	var dome := sphere(radius * 1.05, radius * 1.4, 12, 3)
	dome.is_hemisphere = true
	mb.add_primitive(dome, Transform3D(Basis(), Vector3(0, height, 0)), Palette.ROOF.lightened(0.2))
	for k in 3:
		mb.add_primitive(cylinder(radius * 1.02, radius * 1.02, 0.15, 12),
				Transform3D(Basis(), Vector3(0, height * (0.25 + 0.25 * k), 0)), Palette.SILO.darkened(0.2))
	return mb.commit(Palette.vertex_material(0.7))


static func turbine_tower(height: float) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_primitive(cylinder(1.5, 0.8, height, 10), Transform3D(Basis(), Vector3(0, height * 0.5, 0)), Palette.WHITE)
	mb.add_box(Vector3(0, height + 0.9, 0.8), Vector3(2.0, 2.0, 5.0), Palette.WHITE)
	return mb.commit(Palette.vertex_material(0.5))


## Rotor in the XY plane, spinning around Z.
static func turbine_rotor(blade_length: float) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.add_primitive(sphere(0.9, 1.6, 8, 4), Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO), Palette.WHITE)
	for k in 3:
		var basis := Basis(Vector3.BACK, k * TAU / 3.0)
		var blade_basis := basis * Basis.from_scale(Vector3(1.0, 1.0, 0.3))
		mb.add_primitive(cylinder(0.85, 0.15, blade_length, 6),
				Transform3D(blade_basis, basis * Vector3(0, blade_length * 0.5 + 0.5, 0)), Palette.WHITE)
	return mb.commit(Palette.vertex_material(0.5))


static func cloud(rng: RandomNumberGenerator, offset: Vector3, mb: MeshBuilder) -> void:
	var puffs := rng.randi_range(4, 7)
	var length := rng.randf_range(40.0, 90.0)
	for k in puffs:
		var t := float(k) / (puffs - 1) - 0.5
		var r := rng.randf_range(12.0, 20.0) * (1.0 - absf(t) * 0.8)
		var pos := offset + Vector3(t * length, rng.randf_range(-2.0, 5.0), rng.randf_range(-8.0, 8.0))
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(1.3, 0.55, 1.0))
		mb.add_primitive(sphere(r, r * 2.0, 7, 4), Transform3D(basis, pos), Palette.CLOUD, 0.1, 0.03)
