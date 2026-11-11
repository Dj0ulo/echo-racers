class_name Palette
extends RefCounted
## Shared colour palette and materials so every procedural object reads as one cohesive style.

const GRASS_LIGHT := Color(0.52, 0.71, 0.31)
const GRASS_DARK := Color(0.31, 0.52, 0.23)
const GRASS_DRY := Color(0.70, 0.70, 0.38)
const DIRT := Color(0.58, 0.47, 0.33)
const GRAVEL := Color(0.64, 0.60, 0.52)
const ROCK := Color(0.52, 0.51, 0.49)
const ROCK_DARK := Color(0.40, 0.39, 0.39)
const SNOW := Color(0.94, 0.96, 0.99)
const MOUNTAIN_GREEN := Color(0.33, 0.48, 0.30)

const TRUNK := Color(0.43, 0.30, 0.20)
const PINE := Color(0.16, 0.38, 0.25)
const PINE_LIGHT := Color(0.24, 0.48, 0.29)
const LEAF := Color(0.36, 0.58, 0.22)
const LEAF_LIGHT := Color(0.55, 0.70, 0.25)
const LEAF_AUTUMN := Color(0.92, 0.56, 0.20)

const CURB := Color(0.33, 0.33, 0.34)
const WHITE := Color(0.94, 0.93, 0.89)
const BLACK := Color(0.10, 0.10, 0.11)
const REFLECTOR := Color(0.95, 0.45, 0.10)
const BARN_RED := Color(0.68, 0.21, 0.17)
const ROOF := Color(0.32, 0.30, 0.33)
const WOOD := Color(0.56, 0.41, 0.27)
const HAY := Color(0.88, 0.74, 0.40)
const SILO := Color(0.78, 0.78, 0.76)
const CLOUD := Color(1.0, 1.0, 1.0)

const FLOWER_YELLOW := Color(0.98, 0.84, 0.25)
const FLOWER_WHITE := Color(0.97, 0.96, 0.92)
const FLOWER_PURPLE := Color(0.66, 0.45, 0.85)

static var _materials := {}


## Lit material that takes its albedo from (sRGB) vertex colours. Cached per parameter set.
static func vertex_material(roughness := 0.9, double_sided := false) -> StandardMaterial3D:
	var key := "%.2f_%s" % [roughness, double_sided]
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = roughness
	mat.metallic_specular = 0.25
	if double_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials[key] = mat
	return mat
