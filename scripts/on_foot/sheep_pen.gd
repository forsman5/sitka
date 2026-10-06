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

## Distance inside the fence line that penned sheep stand at, and their spacing.
const SLOT_INSET := 1.0
const SLOT_SPACING := 1.7

var penned_count: int = 0
var _slots: Array[Vector3] = []   # local-space stand points, evenly spaced along the walls
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

## Slots run along the back wall, then the left and right walls (stopping short
## of the front so the open gate stays clear). Each sheep faces its wall.
func _build_slots(half_w: float, half_d: float) -> void:
	var inner_w := half_w - SLOT_INSET
	var inner_d := half_d - SLOT_INSET
	var n_back := int((inner_w * 2.0) / SLOT_SPACING) + 1
	var back_start := -(n_back - 1) * SLOT_SPACING * 0.5
	for i in n_back:
		_add_slot(Vector3(back_start + i * SLOT_SPACING, 0, -inner_d), Vector3(0, 0, -1))
	var z := -inner_d + SLOT_SPACING
	while z <= inner_d - SLOT_SPACING * 0.5:
		_add_slot(Vector3(-inner_w, 0, z), Vector3(-1, 0, 0))
		_add_slot(Vector3(inner_w, 0, z), Vector3(1, 0, 0))
		z += SLOT_SPACING

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
