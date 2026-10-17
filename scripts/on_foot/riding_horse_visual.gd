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

const RIDER_POSE_DEGREES := {
	"UpperLeg.L": Vector3(-76.0, 0.0, -32.0),
	"UpperLeg.R": Vector3(-76.0, 0.0, 32.0),
	"LowerLeg.L": Vector3(96.0, 0.0, 0.0),
	"LowerLeg.R": Vector3(96.0, 0.0, 0.0),
	"UpperArm.L": Vector3(-64.0, 0.0, -7.0),
	"UpperArm.R": Vector3(-64.0, 0.0, 7.0),
	"LowerArm.L": Vector3(-28.0, 0.0, 0.0),
	"LowerArm.R": Vector3(-28.0, 0.0, 0.0),
	"Torso": Vector3(-5.0, 0.0, 0.0),
	"Head": Vector3(3.0, 0.0, 0.0),
}

func _ready() -> void:
	_horse_model.scale = Vector3.ONE * HORSE_SCALE
	# Source mesh faces +Z; the On Foot controller travels along local -Z.
	_horse_model.rotation.y = PI
	_horse_skeleton = _horse_model.find_child("Skeleton3D", true, false) as Skeleton3D
	_horse_animation = _horse_model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _horse_skeleton != null:
		_anchor_bone_index = _horse_skeleton.find_bone(ANCHOR_BONE)
	set_process_priority(100)
	set_gait("Idle")

## Selects the horse animation. Accepts Idle, Walk, or Gallop case-insensitively.
func set_gait(gait: String) -> void:
	var requested := gait.strip_edges().to_lower()
	var clip := "Idle"
	match requested:
		"walk":
			clip = "Walk"
		"gallop", "run":
			clip = "Gallop"
		"idle", "":
			clip = "Idle"
	if _horse_animation != null and _horse_animation.has_animation(clip):
		if _current_gait != clip:
			_horse_animation.play(clip)
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
		for bone_name in RIDER_POSE_DEGREES:
			var index := _rider_skeleton.find_bone(bone_name)
			if index >= 0:
				_rider_bone_indices[bone_name] = index
	model.position = Vector3(0.0, _rider_base_y, 0.0)
	# The source horse and human rigs face +Z, while the movement controller's
	# forward direction is -Z.
	model.rotation = Vector3(0.0, PI, 0.0)
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

func _process(delta: float) -> void:
	_update_rider_anchor()
	if is_instance_valid(_rider_model):
		_rider_time += delta
		_apply_rider_pose(_rider_bob())

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
	if _rider_skeleton == null:
		return
	for bone_name in _rider_bone_indices:
		var degrees: Vector3 = RIDER_POSE_DEGREES[bone_name]
		if bone_name.begins_with("UpperLeg"):
			degrees.x += bob * 40.0
		elif bone_name.begins_with("UpperArm"):
			degrees.x += bob * 24.0
		elif bone_name == "Torso":
			degrees.x -= bob * 35.0
		var index: int = _rider_bone_indices[bone_name]
		_rider_skeleton.set_bone_pose_rotation(index, Quaternion.from_euler(degrees * (PI / 180.0)))
