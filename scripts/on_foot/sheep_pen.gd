class_name SheepPen extends Node3D
## Rectangular wooden sheepfold built from KayKit fence segments. The pen is
## centred on this node; the +Z side has a one-segment opening with the gate
## swung open into the pen, so a herd can be driven in.

const FENCE := preload("res://assets/models/buildings/fence_wood_straight.gltf")
const GATE := preload("res://assets/models/buildings/fence_wood_straight_gate.gltf")

## The KayKit fence is hex-tile sized (~0.55m tall); scale it up to sheep scale.
const FENCE_SCALE := 2.4
## Segment length / height / thickness at FENCE_SCALE (model is 1.1547 long).
const SEGMENT_LENGTH := 1.154701 * FENCE_SCALE
const FENCE_HEIGHT := 0.55 * FENCE_SCALE
## The mesh sits at x = -1.0 in its own tile; shift it so the segment is centred.
const MESH_CENTER_OFFSET := 1.0 * FENCE_SCALE

@export var segments_wide: int = 4
@export var segments_deep: int = 3
## Which front-side slot (0-based, left to right) is the open gate.
@export var gate_slot: int = 1

signal sheep_penned(total: int)

## Distance inside the fence line of the outermost row of penned sheep, and the
## grid spacing between them. The whole interior is filled, not just the walls.
const SLOT_INSET := 1.0
const SLOT_SPACING := 1.5
## Clear radius kept around the swung-open gate leaf so sheep don't stand in it.
const GATE_CLEARANCE := 0.9

var penned_count: int = 0
var _slots: Array[Vector3] = []   # local-space stand points, filled back row first
var _slot_yaws: Array[float] = []

func _ready() -> void:
	var half_w := segments_wide * SEGMENT_LENGTH * 0.5
	var half_d := segments_deep * SEGMENT_LENGTH * 0.5
	_build_slots(half_w, half_d)
	_build_detector(half_w, half_d)

	# Back (-Z) and front (+Z) sides run along X; left/right sides along Z.
	for i in segments_wide:
		var x := -half_w + (i + 0.5) * SEGMENT_LENGTH
		_add_segment(FENCE, Vector3(x, 0, -half_d), 90.0)
		if i == gate_slot:
			# Hinged at the slot's left edge and swung 90 degrees into the pen.
			var hinge := Vector3(x - SEGMENT_LENGTH * 0.5, 0, half_d)
			_add_segment(GATE, hinge + Vector3(0, 0, -SEGMENT_LENGTH * 0.5), 0.0)
		else:
			_add_segment(FENCE, Vector3(x, 0, half_d), 90.0)
	for j in segments_deep:
		var z := -half_d + (j + 0.5) * SEGMENT_LENGTH
		_add_segment(FENCE, Vector3(-half_w, 0, z), 0.0)
		_add_segment(FENCE, Vector3(half_w, 0, z), 0.0)

## How many sheep a pen of this size holds.
static func capacity_for(wide: int, deep: int, gate: int = 1) -> int:
	return _slot_points(wide * SEGMENT_LENGTH * 0.5, deep * SEGMENT_LENGTH * 0.5,
			_gate_hinge_x(wide, gate)).size()

## Smallest segment growth (added to both dimensions) whose pen holds `heads`.
static func growth_for(heads: int, wide: int, deep: int, gate: int = 1) -> int:
	var grow := 0
	while capacity_for(wide + grow, deep + grow, gate) < heads:
		grow += 1
	return grow

## The gate leaf is hinged at its slot's left edge and swings into the pen.
static func _gate_hinge_x(wide: int, gate: int) -> float:
	return -wide * SEGMENT_LENGTH * 0.5 + gate * SEGMENT_LENGTH

## Grid of stand points over the whole interior, ordered back wall first (then
## centre-out within a row) so later arrivals never have to squeeze past sheep
## that have already settled, with the gate leaf's footprint left clear.
static func _slot_points(half_w: float, half_d: float, hinge_x: float) -> Array[Vector3]:
	var inner_w := half_w - SLOT_INSET
	var inner_d := half_d - SLOT_INSET
	var cols := int((inner_w * 2.0) / SLOT_SPACING) + 1
	var rows := int((inner_d * 2.0) / SLOT_SPACING) + 1
	var x0 := -(cols - 1) * SLOT_SPACING * 0.5
	var z0 := -(rows - 1) * SLOT_SPACING * 0.5
	var pts: Array[Vector3] = []
	for r in rows:
		var row: Array[Vector3] = []
		for c in cols:
			var p := Vector3(x0 + c * SLOT_SPACING, 0.0, z0 + r * SLOT_SPACING)
			# Gate leaf runs from the hinge on the front wall back across the pen.
			if absf(p.x - hinge_x) < GATE_CLEARANCE and p.z > half_d - SEGMENT_LENGTH - GATE_CLEARANCE:
				continue
			row.append(p)
		row.sort_custom(func(a: Vector3, b: Vector3) -> bool: return absf(a.x) < absf(b.x))
		pts.append_array(row)
	return pts

## Each sheep faces its nearest wall.
func _build_slots(half_w: float, half_d: float) -> void:
	for p in _slot_points(half_w, half_d, _gate_hinge_x(segments_wide, gate_slot)):
		var to_x := half_w - absf(p.x)
		var to_z := half_d - absf(p.z)
		var facing := Vector3(signf(p.x), 0, 0) if to_x < to_z else Vector3(0, 0, signf(p.z) if p.z != 0.0 else -1.0)
		_add_slot(p, facing)

func _add_slot(pos: Vector3, facing: Vector3) -> void:
	_slots.append(pos)
	_slot_yaws.append(atan2(-facing.x, -facing.z))

func _build_detector(half_w: float, half_d: float) -> void:
	var area := Area3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(half_w * 2.0 - 0.8, 2.0, half_d * 2.0 - 0.8)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = 1.0
	area.add_child(col)
	area.body_entered.connect(_on_body_entered)
	add_child(area)

func _on_body_entered(body: Node3D) -> void:
	var sheep := body as OnFootSheep
	if sheep == null or sheep.penned or penned_count >= _slots.size():
		return
	var slot := penned_count
	penned_count += 1
	sheep.pen_in(to_global(_slots[slot]), rotation.y + _slot_yaws[slot])
	sheep_penned.emit(penned_count)

func _add_segment(scene: PackedScene, pos: Vector3, yaw_deg: float) -> void:
	# Sit each segment on the ground beneath it, sunk a little to hide slope gaps.
	var terrain := get_tree().get_first_node_in_group("heightmap_terrain")
	if terrain != null:
		var g := to_global(pos)
		pos.y = terrain.get_height(g.x, g.z) - global_position.y - 0.1
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees.y = yaw_deg
	add_child(body)

	var model := scene.instantiate() as Node3D
	model.scale = Vector3.ONE * FENCE_SCALE
	model.position.x = MESH_CENTER_OFFSET
	body.add_child(model)

	var shape := BoxShape3D.new()
	shape.size = Vector3(0.25, FENCE_HEIGHT, SEGMENT_LENGTH)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = FENCE_HEIGHT * 0.5
	body.add_child(col)
