class_name RidingHorseVisual
extends Node3D
## Visual horse and rider anchor for the On Foot riding experiment.
## The anchor follows the horse's animated spine position while staying upright.

const HORSE_SCALE := 0.35
const RIDER_MODEL_LOWERING := 0.47
const ANCHOR_BONE := "Torso2"

@onready var rider_anchor: Node3D = $RiderAnchor
@onready var _horse_model: Node3D = $Model

var _horse_skeleton: Skeleton3D
var _horse_animation: AnimationPlayer
var _anchor_bone_index: int = -1
var _current_gait: String = ""
var _rider_model: Node3D
var _rider_skeleton: Skeleton3D
var _rider_animation: AnimationPlayer
var _rider_bone_indices: Dictionary = {}
var _rider_time: float = 0.0
var _rider_base_y: float = 0.0
var _saved_animation: String = ""
var _rider_scale: Vector3 = Vector3.ONE
var _reins: Array[MeshInstance3D] = []
var _rein_material: StandardMaterial3D

# Target segment directions are in Skeleton3D space. The imported armature
# maps skeleton -Y to character-forward +Z and skeleton -Z to character-down.
# Each direction is solved from the bone's actual rest basis below.
const RIDER_SEGMENTS := [
	{"bone": "UpperArm.L", "child": "LowerArm.L", "direction": Vector3(0.0, -0.94, -0.34)},
	{"bone": "UpperArm.R", "child": "LowerArm.R", "direction": Vector3(0.0, -0.94, -0.34)},
	{"bone": "LowerArm.L", "child": "Fist.L", "direction": Vector3(0.0, -0.97, -0.24)},
	{"bone": "LowerArm.R", "child": "Fist.R", "direction": Vector3(0.0, -0.97, -0.24)},
	{"bone": "UpperLeg.L", "child": "LowerLeg.L", "direction": Vector3(0.45, -0.76, -0.46)},
	{"bone": "UpperLeg.R", "child": "LowerLeg.R", "direction": Vector3(-0.45, -0.76, -0.46)},
	{"bone": "LowerLeg.L", "child": "LowerLeg.L_end", "direction": Vector3(0.0, 0.0, -1.0)},
	{"bone": "LowerLeg.R", "child": "LowerLeg.R_end", "direction": Vector3(0.0, 0.0, -1.0)},
]

func _ready() -> void:
	_horse_model.scale = Vector3.ONE * HORSE_SCALE
	# Source mesh faces +Z; the On Foot controller travels along local -Z.
	_horse_model.rotation.y = PI
	_horse_skeleton = _horse_model.find_child("Skeleton3D", true, false) as Skeleton3D
	_horse_animation = _horse_model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _horse_skeleton != null:
		_anchor_bone_index = _horse_skeleton.find_bone(ANCHOR_BONE)
	# glTF clips import as one-shot; without looping the gait freezes on its last pose.
	if _horse_animation != null:
		for clip in ["Idle", "Walk", "Gallop"]:
			if _horse_animation.has_animation(clip):
				_horse_animation.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_build_riding_gear()
	set_process_priority(100)
	set_gait("Idle")

## Selects the horse animation. Accepts Idle, Walk, Gallop, or Jump case-insensitively.
## Jump plays once and holds its last pose until another gait is selected.
func set_gait(gait: String) -> void:
	var requested := gait.strip_edges().to_lower()
	var clip := "Idle"
	match requested:
		"walk":
			clip = "Walk"
		"gallop", "run":
			clip = "Gallop"
		"jump":
			clip = "Gallop_Jump"
		"idle", "":
			clip = "Idle"
	if _horse_animation != null and _horse_animation.has_animation(clip):
		if _current_gait != clip:
			_horse_animation.play(clip, 0.12)
		_current_gait = clip

## Call after parenting the player's human model under RiderAnchor.
## The helper owns and pauses its AnimationPlayer until clear_riding_pose().
func apply_riding_pose(model: Node3D) -> void:
	if model == null or not is_instance_valid(model):
		return
	if _rider_model == model:
		return
	if is_instance_valid(_rider_model):
		clear_riding_pose(_rider_model)

	_rider_model = model
	_rider_skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	_rider_animation = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_rider_scale = model.scale
	_rider_base_y = -RIDER_MODEL_LOWERING
	_rider_time = 0.0
	if _rider_animation != null:
		_saved_animation = _rider_animation.current_animation
		_rider_animation.stop(true)
	else:
		_saved_animation = ""
	if _rider_skeleton != null:
		_rider_skeleton.reset_bone_poses()
		_rider_bone_indices.clear()
		for segment in RIDER_SEGMENTS:
			var bone_name: String = segment["bone"]
			var index := _rider_skeleton.find_bone(bone_name)
			var child_index := _rider_skeleton.find_bone(segment["child"])
			if index >= 0 and child_index >= 0:
				_rider_bone_indices[bone_name] = index
	model.position = Vector3(0.0, _rider_base_y, 0.0)
	# The source horse and human rigs face +Z, while the movement controller's
	# forward direction is -Z.
	model.rotation = Vector3(0.0, PI, 0.0)
	_apply_rider_bone_pose()
	_apply_rider_pose(0.0)

## Clears procedural bone overrides and returns the human model to its on-foot
## local transform. Call before moving it back under the player controller.
func clear_riding_pose(model: Node3D) -> void:
	if model == null or not is_instance_valid(model):
		return
	var skeleton := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton != null:
		skeleton.reset_bone_poses()
	model.position = Vector3.ZERO
	model.rotation = Vector3(0.0, PI, 0.0)
	model.scale = _rider_scale
	var animation_player := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if animation_player != null:
		var resume_clip := _saved_animation
		if resume_clip.is_empty() or not animation_player.has_animation(resume_clip):
			resume_clip = "CharacterArmature|Idle"
		if animation_player.has_animation(resume_clip):
			animation_player.play(resume_clip)
	if _rider_model == model:
		_rider_model = null
		_rider_skeleton = null
		_rider_animation = null
		_rider_bone_indices.clear()
		_saved_animation = ""

## Stops a rider weapon animation and returns to the procedural reins pose.
func restore_rider_pose() -> void:
	if not is_instance_valid(_rider_model):
		return
	if _rider_animation != null:
		_rider_animation.stop(true)
	if _rider_skeleton != null:
		_rider_skeleton.reset_bone_poses()
		_apply_rider_bone_pose()

func _process(delta: float) -> void:
	_update_rider_anchor()
	if is_instance_valid(_rider_model):
		_rider_time += delta
		_apply_rider_pose(_rider_bob())
		_update_reins()

func _update_rider_anchor() -> void:
	if _horse_skeleton == null or _anchor_bone_index < 0:
		return
	var bone_position: Vector3 = _horse_skeleton.get_bone_global_pose(_anchor_bone_index).origin
	var model_basis := _horse_model.transform.basis
	# Follow the spine's animated translation without inheriting its twist.
	rider_anchor.position = _horse_model.position + model_basis * bone_position + Vector3.UP * 0.07

func _rider_bob() -> float:
	var frequency := 1.5
	var amplitude := 0.012
	match _current_gait:
		"Walk":
			frequency = 5.2
			amplitude = 0.018
		"Gallop":
			frequency = 7.4
			amplitude = 0.027
	return sin(_rider_time * frequency * TAU) * amplitude

func _apply_rider_pose(bob: float) -> void:
	if not is_instance_valid(_rider_model):
		return
	_rider_model.position.y = _rider_base_y + bob

func _build_riding_gear() -> void:
	var leather := StandardMaterial3D.new()
	leather.albedo_color = Color(0.18, 0.065, 0.028)
	leather.roughness = 0.9
	var saddle := MeshInstance3D.new()
	saddle.name = "SaddlePad"
	var saddle_mesh := BoxMesh.new()
	saddle_mesh.size = Vector3(0.56, 0.08, 0.56)
	saddle.mesh = saddle_mesh
	saddle.material_override = leather
	saddle.position = Vector3(0.0, -0.075, 0.0)
	rider_anchor.add_child(saddle)

	var dark_leather := StandardMaterial3D.new()
	dark_leather.albedo_color = Color(0.095, 0.032, 0.016)
	dark_leather.roughness = 0.85
	for side in [-1.0, 1.0]:
		var strap := MeshInstance3D.new()
		strap.name = "StirrupStrap"
		var strap_mesh := BoxMesh.new()
		strap_mesh.size = Vector3(0.025, 0.2, 0.025)
		strap.mesh = strap_mesh
		strap.material_override = dark_leather
		strap.position = Vector3(side * 0.27, -0.17, -0.17)
		rider_anchor.add_child(strap)
		for bar in [
			{ "pos": Vector3(side * 0.29, -0.365, -0.23), "size": Vector3(0.035, 0.15, 0.035) },
			{ "pos": Vector3(side * 0.29, -0.365, -0.11), "size": Vector3(0.035, 0.15, 0.035) },
			{ "pos": Vector3(side * 0.29, -0.43, -0.17), "size": Vector3(0.035, 0.025, 0.16) },
		]:
			var stirrup_bar := MeshInstance3D.new()
			stirrup_bar.name = "Stirrup"
			var stirrup_mesh := BoxMesh.new()
			stirrup_mesh.size = bar["size"]
			stirrup_bar.mesh = stirrup_mesh
			stirrup_bar.material_override = dark_leather
			stirrup_bar.position = bar["pos"]
			rider_anchor.add_child(stirrup_bar)

	_rein_material = StandardMaterial3D.new()
	_rein_material.albedo_color = Color(0.07, 0.025, 0.012)
	_rein_material.roughness = 0.8
	for index in 2:
		var rein := MeshInstance3D.new()
		rein.name = "Rein"
		var rein_mesh := CylinderMesh.new()
		rein_mesh.top_radius = 0.008
		rein_mesh.bottom_radius = 0.008
		rein_mesh.height = 0.5
		rein.mesh = rein_mesh
		rein.material_override = _rein_material
		rider_anchor.add_child(rein)
		_reins.append(rein)

func _update_reins() -> void:
	if _rider_skeleton == null or not is_instance_valid(_rider_model):
		for rein in _reins:
			rein.visible = false
		return
	var armature := _rider_model.find_child("CharacterArmature", true, false) as Node3D
	if armature == null:
		return
	for index in 2:
		var side := -1.0 if index == 0 else 1.0
		var hand_name := "Fist.L" if index == 0 else "Fist.R"
		var hand_bone := _rider_skeleton.find_bone(hand_name)
		if hand_bone < 0:
			continue
		var hand_world := _rider_skeleton.to_global(_rider_skeleton.get_bone_global_pose(hand_bone).origin)
		var start := rider_anchor.to_local(hand_world)
		var finish := Vector3(side * 0.055, -0.03, -0.82)
		var offset := finish - start
		var rein := _reins[index]
		var cylinder := rein.mesh as CylinderMesh
		cylinder.height = maxf(offset.length(), 0.01)
		rein.transform = Transform3D(Basis(Quaternion(Vector3.UP, offset.normalized())), (start + finish) * 0.5)
		rein.visible = true

func _apply_rider_bone_pose() -> void:
	if _rider_skeleton == null:
		return
	for segment in RIDER_SEGMENTS:
		var bone_name: String = segment["bone"]
		var bone_index := _rider_skeleton.find_bone(bone_name)
		var child_index := _rider_skeleton.find_bone(segment["child"])
		if bone_index >= 0 and child_index >= 0:
			_set_segment_direction(bone_index, child_index, segment["direction"])

func _set_segment_direction(bone_index: int, child_index: int, target_direction: Vector3) -> void:
	var bone_rest := _rider_skeleton.get_bone_global_rest(bone_index)
	var child_rest := _rider_skeleton.get_bone_global_rest(child_index)
	var local_segment: Vector3 = bone_rest.basis.inverse() * (child_rest.origin - bone_rest.origin)
	if local_segment.length_squared() < 0.000001:
		return
	# With this bone's pose reset, the current global basis includes any posed
	# parent bones. Solve in that basis so L/R, arm and leg axes stay consistent.
	_rider_skeleton.set_bone_pose_rotation(bone_index, Quaternion.IDENTITY)
	var parent_basis := _rider_skeleton.get_bone_global_pose(bone_index).basis
	var target_local: Vector3 = parent_basis.inverse() * target_direction.normalized()
	var rotation := Quaternion(local_segment.normalized(), target_local.normalized())
	_rider_skeleton.set_bone_pose_rotation(bone_index, rotation)
