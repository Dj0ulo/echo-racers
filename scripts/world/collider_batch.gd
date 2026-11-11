class_name ColliderBatch
extends RefCounted
## Thousands of static colliders (tree trunks, rocks, guard rails) added straight to the PhysicsServer,
## without a CollisionShape3D node each. Shapes are grouped into one static body per spatial cell.
## Ray hits report `owner` as the collider, so its "surface" meta works like on a StaticBody3D.

var _cell := 200.0
var _cells := {}  ## Vector2i -> Array of [Shape3D, Transform3D]
var _shapes: Array[Shape3D] = []
var _bodies: Array[RID] = []
var count := 0


func _init(cell_size := 200.0) -> void:
	_cell = cell_size


func add(shape: Shape3D, xform: Transform3D) -> void:
	var key := Vector2i(floori(xform.origin.x / _cell), floori(xform.origin.z / _cell))
	if not _cells.has(key):
		_cells[key] = []
	_cells[key].append([shape, xform])
	count += 1


func add_box(center: Vector3, basis: Basis, size: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	add(box, Transform3D(basis, center))


## Creates the bodies in `owner`'s physics space, on collision layer 1 ("world").
func commit(owner: Node3D) -> void:
	var space := owner.get_world_3d().space
	for key: Vector2i in _cells:
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_set_collision_layer(body, 1)
		PhysicsServer3D.body_set_collision_mask(body, 1)
		PhysicsServer3D.body_attach_object_instance_id(body, owner.get_instance_id())
		for entry: Array in _cells[key]:
			var shape: Shape3D = entry[0]
			_shapes.append(shape)  # Keeps the shape resources alive.
			PhysicsServer3D.body_add_shape(body, shape.get_rid(), entry[1])
		# Join the space last so the compound shape is built once.
		PhysicsServer3D.body_set_space(body, space)
		_bodies.append(body)
	_cells.clear()
	owner.set_meta(&"collider_batch", self)
	owner.tree_exiting.connect(_free_bodies)


func _free_bodies() -> void:
	for body in _bodies:
		PhysicsServer3D.free_rid(body)
	_bodies.clear()
