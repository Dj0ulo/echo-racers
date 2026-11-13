class_name Minimap
extends Control
## Circular heading-up minimap: the player arrow sits fixed at the centre pointing up and the map rotates
## around it. The terrain (height-tinted, hill-shaded) and every road of `WorldGenerator.roads` are rendered
## ONCE into a texture covering the whole network; each frame a shader only samples that texture with the
## player's position and heading. Traffic cars, the player arrow and the north marker are drawn on top.
## Everything is derived from the world data at runtime (any number of roads, any map size).

const DIAMETER := 230.0
const VIEW_RADIUS_SLOW := 420.0       ## Metres from the centre to the rim when stopped...
const VIEW_RADIUS_FAST := 620.0       ## ...and at FAST_SPEED_KMH and above.
const FAST_SPEED_KMH := 200.0
const MAX_TEXTURE_SIZE := 4096
const MIN_METRES_PER_PIXEL := 2.0
const TERRAIN_SAMPLES := 320          ## Height samples along the longest side of the map.

const BG := Color(0.17, 0.22, 0.17)
const ROAD_CASING := Color(0.1, 0.11, 0.13, 0.85)
const ROAD_FILL := Color(0.9, 0.9, 0.86)
const HIGHWAY_FILL := Color(1.0, 0.74, 0.24)
const TRAFFIC_DOT := Color(0.35, 0.8, 1.0)
const PLAYER_COLOR := Color(1.0, 0.32, 0.22)
const RIM := Color(1, 1, 1, 0.55)
const ECHO_COLOR := Color(0.3, 0.88, 1.0)
const ECHO_TARGET_COLOR := Color(1.0, 0.4, 0.9)

const MAP_SHADER := """
shader_type canvas_item;
uniform sampler2D map_tex : filter_linear_mipmap, repeat_disable;
uniform vec2 centre_uv;      // Player position in map UV.
uniform vec2 fwd_uv;         // Player forward (screen up), in UV units for the full view radius.
uniform vec2 right_uv;       // Player right (screen right), in UV units for the full view radius.
uniform vec4 bg_color : source_color;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = length(p);
	vec2 uv = centre_uv + right_uv * p.x - fwd_uv * p.y;
	vec4 col = texture(map_tex, uv);
	bool outside = any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)));
	col = outside ? bg_color : col;
	// Darken towards the rim a little, then cut a soft circle.
	col.rgb *= mix(1.0, 0.72, smoothstep(0.55, 1.0, d));
	float aa = fwidth(d) * 1.5;
	col.a = 0.92 * (1.0 - smoothstep(1.0 - aa, 1.0, d));
	COLOR = col;
}
"""

var car: CarController
var world: WorldGenerator
var traffic: Node
var echo_points := PackedVector3Array()  ## Echo course starts (neon diamonds, pinned to the rim when far).
var echo_target := Vector3.ZERO          ## Next checkpoint of the echo race...
var echo_target_active := false          ## ...shown while this is set.
var destination := Vector3.ZERO          ## GPS destination (gold pin, pinned to the rim when far)...
var destination_active := false          ## ...shown while this is set.
var route := PackedVector3Array()        ## GPS route drawn as a gold line (empty = none).

var _map: ColorRect
var _overlay: Control
var _material: ShaderMaterial
var _bounds := Rect2()            ## World x/z rectangle covered by the map texture.
var _metres_per_pixel := 1.0
var _view_radius := VIEW_RADIUS_SLOW
var _ready_to_show := false
var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(DIAMETER, DIAMETER)
	size = custom_minimum_size

	_material = ShaderMaterial.new()
	_material.shader = Shader.new()
	_material.shader.code = MAP_SHADER
	_material.set_shader_parameter(&"bg_color", BG)

	_map = ColorRect.new()
	_map.material = _material
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_map)

	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	_font = ThemeDB.fallback_font
	visible = false
	_build_map.call_deferred()


## Finds the world, renders the terrain and road network into a texture once.
func _build_map() -> void:
	var scene := get_tree().current_scene
	if world == null and scene:
		world = scene.get_node_or_null(^"World") as WorldGenerator
	if traffic == null and scene:
		traffic = scene.get_node_or_null(^"Traffic")
	if world == null or world.roads.is_empty():
		push_warning("Minimap: no world roads found, minimap disabled.")
		return

	# Bounds: every road point, padded so the view never runs off the map near the network's edge.
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for road in world.roads:
		for p in road.points:
			lo = lo.min(Vector2(p.x, p.z))
			hi = hi.max(Vector2(p.x, p.z))
	var pad := VIEW_RADIUS_FAST * 1.45
	_bounds = Rect2(lo, hi - lo).grow(pad)
	var longest := maxf(_bounds.size.x, _bounds.size.y)
	_metres_per_pixel = maxf(MIN_METRES_PER_PIXEL, longest / MAX_TEXTURE_SIZE)
	var px := Vector2i(ceili(_bounds.size.x / _metres_per_pixel), ceili(_bounds.size.y / _metres_per_pixel))

	var t0 := Time.get_ticks_msec()
	var terrain_tex := _build_terrain_texture()

	# Draw everything once in an off-screen viewport (GPU polylines, antialiased).
	var vp := SubViewport.new()
	vp.size = px
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var painter := Node2D.new()
	painter.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	painter.draw.connect(_paint_map.bind(painter, terrain_tex, Vector2(px)))
	vp.add_child(painter)
	add_child(vp)
	_material.set_shader_parameter(&"map_tex", vp.get_texture())

	if DisplayServer.get_name() != "headless":  # Nothing is ever drawn headless.
		await RenderingServer.frame_post_draw
		# Copy to a mipmapped texture (smooth when shrunk/rotated) and drop the viewport.
		var image := vp.get_texture().get_image()
		if image and not image.is_empty():
			image.generate_mipmaps()
			_material.set_shader_parameter(&"map_tex", ImageTexture.create_from_image(image))
			vp.queue_free()
	print("Minimap: %d roads, %.0f x %.0f m at %.1f m/px, built in %d ms" % [
		world.roads.size(), _bounds.size.x, _bounds.size.y, _metres_per_pixel, Time.get_ticks_msec() - t0])
	_ready_to_show = true


## Height-tinted, hill-shaded background sampled from the world terrain (cheap: a few hundred samples a side).
func _build_terrain_texture() -> Texture2D:
	var terrain = world.terrain
	if terrain == null or not terrain.has_method(&"get_height"):
		return null
	var longest := maxf(_bounds.size.x, _bounds.size.y)
	var cell := longest / TERRAIN_SAMPLES
	var w := maxi(ceili(_bounds.size.x / cell), 2)
	var h := maxi(ceili(_bounds.size.y / cell), 2)
	var heights := PackedFloat32Array()
	heights.resize(w * h)
	var h_min := INF
	var h_max := -INF
	for j in h:
		var z := _bounds.position.y + (j + 0.5) * cell
		for i in w:
			var v: float = terrain.get_height(_bounds.position.x + (i + 0.5) * cell, z)
			heights[j * w + i] = v
			h_min = minf(h_min, v)
			h_max = maxf(h_max, v)
	var image := Image.create(w, h, false, Image.FORMAT_RGB8)
	var light := Vector2(-0.7, -0.7).normalized()  # Lit from the north-west.
	for j in h:
		for i in w:
			var v := heights[j * w + i]
			var dx := heights[j * w + mini(i + 1, w - 1)] - heights[j * w + maxi(i - 1, 0)]
			var dz := heights[mini(j + 1, h - 1) * w + i] - heights[maxi(j - 1, 0) * w + i]
			var slope := Vector2(dx, dz) / (2.0 * cell)
			var shade := clampf(1.0 - slope.dot(light) * 0.9, 0.78, 1.18)
			image.set_pixel(i, j, _height_color(v, h_min, h_max) * shade)
	var tex := ImageTexture.create_from_image(image)
	return tex


static func _height_color(v: float, h_min: float, h_max: float) -> Color:
	# Absolute heights for the lowlands (so they read alike on any map), relative for the peaks.
	var low := Color(0.3, 0.44, 0.24)
	var mid := Color(0.42, 0.53, 0.28)
	var high := Color(0.52, 0.5, 0.42)
	var peak := Color(0.82, 0.84, 0.86)
	if v < 30.0:
		return low.lerp(mid, clampf((v - h_min) / maxf(30.0 - h_min, 1.0), 0.0, 1.0))
	var t := clampf((v - 30.0) / maxf(h_max - 30.0, 1.0), 0.0, 1.0)
	if t < 0.6:
		return mid.lerp(high, t / 0.6)
	return high.lerp(peak, (t - 0.6) / 0.4)


func _paint_map(painter: Node2D, terrain_tex: Texture2D, px: Vector2) -> void:
	if terrain_tex:
		painter.draw_texture_rect(terrain_tex, Rect2(Vector2.ZERO, px), false)
	else:
		painter.draw_rect(Rect2(Vector2.ZERO, px), BG)
	var lines: Array[PackedVector2Array] = []
	for road in world.roads:
		var line := PackedVector2Array()
		line.resize(road.points.size())
		for k in road.points.size():
			var p := road.points[k]
			line[k] = (Vector2(p.x, p.z) - _bounds.position) / _metres_per_pixel
		if road.closed and line.size() > 2:
			line.append(line[0])
			line.append(line[1])  # Overlap one segment so the joint is seamless.
		lines.append(line)
	# Casings under everything, then country roads, then highways on top.
	for k in lines.size():
		painter.draw_polyline(lines[k], ROAD_CASING, _road_width(world.roads[k]) + 7.0 / _metres_per_pixel, true)
	for pass_highway in [false, true]:
		for k in lines.size():
			var road: RoadPath = world.roads[k]
			if road.is_highway == pass_highway:
				painter.draw_polyline(lines[k], HIGHWAY_FILL if road.is_highway else ROAD_FILL, _road_width(road), true)


## Drawn width in texture pixels: exaggerated so roads stay readable at minimap scale.
func _road_width(road: RoadPath) -> float:
	var metres := maxf(road.half_width * 2.0 * 1.3, 30.0) if road.is_highway else maxf(road.half_width * 2.0, 16.0)
	return metres / _metres_per_pixel


func _process(delta: float) -> void:
	visible = _ready_to_show and car != null
	if not visible:
		return
	var target := lerpf(VIEW_RADIUS_SLOW, VIEW_RADIUS_FAST, clampf(car.get_speed_kmh() / FAST_SPEED_KMH, 0.0, 1.0))
	_view_radius = lerpf(_view_radius, target, 1.0 - exp(-1.5 * delta))
	var pos := car.global_position
	var axes := _heading_axes()
	var to_uv := Vector2(_view_radius, _view_radius) / _bounds.size
	_material.set_shader_parameter(&"centre_uv", (Vector2(pos.x, pos.z) - _bounds.position) / _bounds.size)
	_material.set_shader_parameter(&"fwd_uv", axes[0] * to_uv)
	_material.set_shader_parameter(&"right_uv", axes[1] * to_uv)
	_overlay.queue_redraw()


## Horizontal forward and right unit vectors (world x/z) of the player's car.
func _heading_axes() -> Array[Vector2]:
	var f := -car.global_basis.z
	var fwd := Vector2(f.x, f.z)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector2(0, -1)
	return [fwd, Vector2(-fwd.y, fwd.x)]


## World x/z → overlay pixels (centre of the control is the player).
func _to_screen(world_xz: Vector2, centre: Vector2, axes: Array[Vector2], radius_px: float) -> Vector2:
	var d := world_xz - centre
	return Vector2(d.dot(axes[1]), -d.dot(axes[0])) * (radius_px / _view_radius)


func _draw_overlay() -> void:
	if car == null:
		return
	var c := _overlay.size * 0.5
	var r := minf(c.x, c.y)
	var pos := Vector2(car.global_position.x, car.global_position.z)
	var axes := _heading_axes()

	# Traffic cars.
	if is_instance_valid(traffic):
		for node in traffic.get_children():
			var n3 := node as Node3D
			if n3 == null or not n3.visible:
				continue
			var s := _to_screen(Vector2(n3.global_position.x, n3.global_position.z), pos, axes, r)
			if s.length() < r - 4.0:
				_overlay.draw_circle(c + s, 2.6, Color(0, 0, 0, 0.6))
				_overlay.draw_circle(c + s, 1.9, TRAFFIC_DOT)

	# GPS route, then its destination.
	if route.size() >= 2:
		_draw_route(c, r, pos, axes)
	if destination_active:
		_draw_pin(c, r, _to_screen(Vector2(destination.x, destination.z), pos, axes, r))

	# Echo points, and the next checkpoint during an echo race (both pinned to the rim when off the map).
	var pulse := 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.006)
	for p in echo_points:
		_draw_echo_marker(c, r, _to_screen(Vector2(p.x, p.z), pos, axes, r), Color(ECHO_COLOR, pulse), 7.0)
	if echo_target_active:
		_draw_echo_marker(c, r, _to_screen(Vector2(echo_target.x, echo_target.z), pos, axes, r), ECHO_TARGET_COLOR, 8.0)

	# Rim.
	_overlay.draw_arc(c, r - 1.0, 0.0, TAU, 96, RIM, 2.0, true)

	# North marker on the rim (world north = -z).
	var north := _to_screen(pos + Vector2(0, -1), pos, axes, r).normalized()
	var np := c + north * (r - 1.0)
	_overlay.draw_circle(np, 11.0, Color(0.08, 0.09, 0.11, 0.9))
	_overlay.draw_arc(np, 11.0, 0.0, TAU, 32, RIM, 1.5, true)
	var fs := 14
	var glyph := _font.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	_overlay.draw_string(_font, np + Vector2(-glyph.x * 0.5, fs * 0.36), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
			Color(1.0, 0.45, 0.4))

	# Player arrow, fixed at the centre pointing up.
	var arrow := PackedVector2Array([c + Vector2(0, -10), c + Vector2(7, 8), c + Vector2(0, 4), c + Vector2(-7, 8)])
	var outline := arrow.duplicate()
	outline.append(arrow[0])
	_overlay.draw_colored_polygon(arrow, PLAYER_COLOR)
	_overlay.draw_polyline(outline, Color(1, 1, 1, 0.95), 1.6, true)


func _draw_echo_marker(c: Vector2, r: float, s: Vector2, col: Color, size: float) -> void:
	var edge := r - size - 3.0
	if s.length() > edge:
		s = s.normalized() * edge
		size *= 0.75
	var p := c + s
	var diamond := PackedVector2Array([p + Vector2(0, -size), p + Vector2(size, 0), p + Vector2(0, size), p + Vector2(-size, 0)])
	_overlay.draw_circle(p, size * 1.5, Color(col, col.a * 0.25))
	_overlay.draw_colored_polygon(diamond, col)
	diamond.append(diamond[0])
	_overlay.draw_polyline(diamond, Color(1, 1, 1, 0.9), 1.4, true)


## The route as a cased gold polyline, split where it leaves the circle.
func _draw_route(c: Vector2, r: float, pos: Vector2, axes: Array[Vector2]) -> void:
	var limit := r - 3.0
	var run := PackedVector2Array()
	var step := maxi(1, route.size() / 400)
	for i in range(0, route.size(), step):
		var s := _to_screen(Vector2(route[i].x, route[i].z), pos, axes, r)
		if s.length() < limit:
			run.append(c + s)
		elif run.size() >= 2:
			_overlay.draw_polyline(run, Color(0.1, 0.07, 0.0, 0.8), 6.0, true)
			_overlay.draw_polyline(run, Gps.COLOR, 3.2, true)
			run.clear()
		else:
			run.clear()
	if run.size() >= 2:
		_overlay.draw_polyline(run, Color(0.1, 0.07, 0.0, 0.8), 6.0, true)
		_overlay.draw_polyline(run, Gps.COLOR, 3.2, true)


## Gold destination pin; shrunk and pinned to the rim when off the map.
func _draw_pin(c: Vector2, r: float, s: Vector2) -> void:
	var size := 7.0
	var edge := r - size - 4.0
	if s.length() > edge:
		s = s.normalized() * edge
		size *= 0.8
	var p := c + s
	_overlay.draw_circle(p, size * 1.7, Color(Gps.COLOR, 0.25))
	_overlay.draw_circle(p, size + 1.5, Color(0.1, 0.07, 0.0, 0.9))
	_overlay.draw_circle(p, size, Gps.COLOR)
	_overlay.draw_circle(p, size * 0.38, Color(1, 1, 1, 0.95))
