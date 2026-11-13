class_name RoadGraph
extends RefCounted
## GPS road graph for route finding (AStar3D). Nodes every NODE_SPACING metres along every road of the
## network, joined where an open road ends on another road. Divided roads (with a median) get one directed
## chain per carriageway, on its lanes; one-way ramps are a directed chain; other roads are a two-way chain on
## the centreline whose route points are pushed onto the right-hand lane once the travel direction is known.

const NODE_SPACING := 8.0
const JOIN_REACH := 30.0   ## Max horizontal distance from a road end to the node of the road it joins.
const JOIN_CLIMB := 7.0    ## Max height difference for that join (keeps bridges apart from roads below).
const START_REACH := 45.0  ## Start-node search radius around the car before falling back to the nearest node.

enum Flow { FORWARD, BACKWARD, BOTH }

var _astar := AStar3D.new()
var _pos := PackedVector3Array()      ## Node positions.
var _dir := PackedVector3Array()      ## Horizontal travel direction of directed nodes, zero for two-way ones.
var _lateral := PackedFloat32Array()  ## Right-hand lane offset applied to two-way nodes along a route.
var _road := PackedInt32Array()       ## Road index of each node.
var _chain := PackedInt32Array()      ## Chain index of each node (one road can have two).


func build(roads: Array[RoadPath]) -> void:
	var ends: Array[Dictionary] = []  ## {id, flow, at_start}
	var chain := 0
	for ri in roads.size():
		var r := roads[ri]
		var n := r.sample_count()
		if n < 2:
			continue
		var stride := maxi(1, roundi(NODE_SPACING / r.step))
		var idx := PackedInt32Array()
		for i in range(0, n, stride):
			idx.append(i)
		if r.closed:
			if n - idx[idx.size() - 1] < stride / 2 and idx.size() > 2:
				idx.remove_at(idx.size() - 1)
		elif idx[idx.size() - 1] != n - 1:
			idx.append(n - 1)
		var chains: Array = []  ## [ids, flow]
		if r.one_way:
			chains.append([_add_chain(r, ri, chain, idx, 0.0, Flow.FORWARD), Flow.FORWARD])
		elif r.median_width > 0.0:
			var off := r.median_width * 0.5 + r.lanes_per_side * r.lane_width * 0.5
			chains.append([_add_chain(r, ri, chain, idx, off, Flow.FORWARD), Flow.FORWARD])
			chain += 1
			chains.append([_add_chain(r, ri, chain, idx, -off, Flow.BACKWARD), Flow.BACKWARD])
		else:
			chains.append([_add_chain(r, ri, chain, idx, 0.0, Flow.BOTH), Flow.BOTH])
			_set_lateral(chains[0][0], r.median_width * 0.5 + r.lanes_per_side * r.lane_width * 0.5)
		chain += 1
		if not r.closed:
			for c: Array in chains:
				var ids: PackedInt32Array = c[0]
				ends.append({"id": ids[0], "flow": c[1], "at_start": true})
				ends.append({"id": ids[ids.size() - 1], "flow": c[1], "at_start": false})
	for e in ends:
		_join_end(e)


## Shortest drivable route from `from` (heading `heading`, may be zero) to `to`: node positions on their
## lane, without lift. Empty when no route exists.
func find_route(from: Vector3, heading: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	if _pos.is_empty():
		return out
	var start := _nearest(from, heading, START_REACH)
	var goal := _nearest(to, Vector3.ZERO, INF)
	var path := _astar.get_id_path(start, goal)
	for k in path.size():
		var id := path[k]
		var p := _pos[id]
		if _lateral[id] > 0.0:
			var a := _pos[path[maxi(k - 1, 0)]]
			var b := _pos[path[mini(k + 1, path.size() - 1)]]
			var d := Vector3(b.x - a.x, 0.0, b.z - a.z)
			if d.length_squared() > 0.01:
				d = d.normalized()
				p += Vector3(-d.z, 0.0, d.x) * _lateral[id]
		out.append(p)
	return out


func _add_chain(r: RoadPath, ri: int, chain: int, idx: PackedInt32Array, lateral: float, flow: Flow) -> PackedInt32Array:
	var ids := PackedInt32Array()
	for i in idx:
		var id := _pos.size()
		var p := r.points[i] + r.right_at(i) * lateral
		var d := Vector3.ZERO
		if flow == Flow.FORWARD:
			d = r.tangents[i]
		elif flow == Flow.BACKWARD:
			d = -r.tangents[i]
		_pos.append(p)
		_dir.append(d)
		_lateral.append(0.0)
		_road.append(ri)
		_chain.append(chain)
		_astar.add_point(id, p)
		if not ids.is_empty():
			_link(ids[ids.size() - 1], id, flow)
		ids.append(id)
	if r.closed and ids.size() > 2:
		_link(ids[ids.size() - 1], ids[0], flow)
	return ids


func _set_lateral(ids: PackedInt32Array, offset: float) -> void:
	for id in ids:
		_lateral[id] = offset


## `a` → `b` in index order; BACKWARD chains are driven from `b` to `a`.
func _link(a: int, b: int, flow: Flow) -> void:
	match flow:
		Flow.FORWARD:
			_astar.connect_points(a, b, false)
		Flow.BACKWARD:
			_astar.connect_points(b, a, false)
		_:
			_astar.connect_points(a, b, true)


## Joins a road end to the nearest suitable node of each other chain within reach. Traffic enters a chain
## at the start of a FORWARD road (or the end of a BACKWARD one) and leaves it at the other end.
func _join_end(e: Dictionary) -> void:
	var id: int = e["id"]
	var flow: int = e["flow"]
	var p := _pos[id]
	var d := _dir[id]
	var best := {}  ## chain -> [node, distance]
	for h in _pos.size():
		if _road[h] == _road[id]:
			continue
		var q := _pos[h]
		if absf(q.y - p.y) > JOIN_CLIMB:
			continue
		var dist := Vector2(q.x - p.x, q.z - p.z).length()
		if dist > JOIN_REACH:
			continue
		var hd := _dir[h]
		if d != Vector3.ZERO and hd != Vector3.ZERO and d.dot(hd) < 0.0:
			continue
		var c := _chain[h]
		if not best.has(c) or dist < (best[c] as Array)[1]:
			best[c] = [h, dist]
	for c in best:
		var h: int = (best[c] as Array)[0]
		var entering: bool = (flow == Flow.FORWARD and e["at_start"]) or (flow == Flow.BACKWARD and not e["at_start"])
		if flow == Flow.BOTH and _dir[h] == Vector3.ZERO:
			_astar.connect_points(id, h, true)
		elif flow == Flow.BOTH:
			# Two-way road meeting a carriageway: enter and leave it in its direction of travel.
			_astar.connect_points(h, id, false)
			var nxt := _next_on_chain(h)
			_astar.connect_points(id, nxt if nxt >= 0 else h, false)
		elif entering:
			_astar.connect_points(h, id, false)
		else:
			_astar.connect_points(id, h, false)


func _next_on_chain(h: int) -> int:
	for c in _astar.get_point_connections(h):
		if _chain[c] == _chain[h] and not _astar.are_points_connected(c, h, false):
			return c
	return -1


## Nearest node to `p` (horizontal distance, height counts half). With a heading, directed nodes pointing
## the other way within `reach` are penalised so the route starts on the carriageway the car is driving on.
func _nearest(p: Vector3, heading: Vector3, reach: float) -> int:
	var h := Vector3(heading.x, 0.0, heading.z)
	var use_heading := h.length_squared() > 0.01
	if use_heading:
		h = h.normalized()
	var best := 0
	var best_score := INF
	for i in _pos.size():
		var q := _pos[i]
		var dist := Vector2(q.x - p.x, q.z - p.z).length() + absf(q.y - p.y) * 0.5
		var score := dist
		if use_heading and dist < reach and _dir[i] != Vector3.ZERO and _dir[i].dot(h) < 0.0:
			score += reach
		if score < best_score:
			best_score = score
			best = i
	return best
