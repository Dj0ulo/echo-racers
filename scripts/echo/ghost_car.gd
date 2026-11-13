class_name GhostCar
extends Node3D
## Translucent neon hologram of a car replaying an EchoRun, without collision. Built from copies of the
## player car's meshes so the echo looks like the car that drove it.

var run: EchoRun

var _material: ShaderMaterial


func build_from(source: Node3D) -> void:
	_material = Neon.hologram_material(Neon.CYAN)
	var inv := source.global_transform.affine_inverse()
	for node in source.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var copy := MeshInstance3D.new()
		copy.mesh = mi.mesh
		copy.transform = inv * mi.global_transform
		copy.material_override = _material
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(copy)


func show_at(t: float) -> void:
	if run:
		global_transform = run.transform_at(t)


## Draw over other transparent overlays (the editor's path ribbon).
func set_render_priority(priority: int) -> void:
	_material.render_priority = priority


func set_energy(e: float) -> void:
	_material.set_shader_parameter(&"energy", e)
