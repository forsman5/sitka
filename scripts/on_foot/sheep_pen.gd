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

func _ready() -> void:
	var half_w := segments_wide * SEGMENT_LENGTH * 0.5
	var half_d := segments_deep * SEGMENT_LENGTH * 0.5

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
