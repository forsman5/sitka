extends SceneTree
## Headless inspection of the rider anchor and the horse's three supported gaits.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var visual_scene := load("res://scenes/on_foot/riding_horse.tscn") as PackedScene
	var human_scene := load("res://assets/models/people/Casual_Male.fbx") as PackedScene
	assert(visual_scene != null, "Riding horse scene failed to load")
	assert(human_scene != null, "Human model failed to load")
	var visual := visual_scene.instantiate() as RidingHorseVisual
	root.add_child(visual)
	await process_frame
	assert(visual.rider_anchor != null, "RiderAnchor missing")
	assert(visual._horse_animation != null, "Horse AnimationPlayer missing")
	assert(visual._anchor_bone_index >= 0, "Horse spine anchor bone missing")
	var rider := human_scene.instantiate() as Node3D
	rider.scale = Vector3.ONE * 0.54
	visual.rider_anchor.add_child(rider)
	visual.apply_riding_pose(rider)
	await process_frame
	assert(is_equal_approx(visual._horse_model.rotation.y, PI), "Horse forward axis does not match controller")
	assert(is_equal_approx(rider.rotation.y, PI), "Mounted rider does not face horse forward")
	assert(visual._rider_skeleton != null, "Human Skeleton3D missing")
	assert(visual._rider_bone_indices.size() == RidingHorseVisual.RIDER_SEGMENTS.size(), "Rider pose bone mapping incomplete")
	print("RiderAnchor path: ", visual.rider_anchor.get_path())
	print("Horse model scale: ", visual._horse_model.scale, "; rider scale: ", rider.scale)
	_assert_segment_direction(visual._rider_skeleton, "UpperArm.L", "LowerArm.L", Vector3(0.0, -1.0, 0.0), 0.9)
	_assert_segment_direction(visual._rider_skeleton, "LowerArm.L", "Fist.L", Vector3(0.0, -1.0, 0.0), 0.9)
	_assert_segment_direction(visual._rider_skeleton, "UpperLeg.L", "LowerLeg.L", Vector3(0.0, -1.0, 0.0), 0.75)
	_assert_segment_direction(visual._rider_skeleton, "LowerLeg.L", "LowerLeg.L_end", Vector3(0.0, 0.0, -1.0), 0.9)
	_assert_segment_direction(visual._rider_skeleton, "UpperArm.R", "LowerArm.R", Vector3(0.0, -1.0, 0.0), 0.9)
	_assert_segment_direction(visual._rider_skeleton, "LowerArm.R", "Fist.R", Vector3(0.0, -1.0, 0.0), 0.9)
	_assert_segment_direction(visual._rider_skeleton, "UpperLeg.R", "LowerLeg.R", Vector3(0.0, -1.0, 0.0), 0.75)
	_assert_segment_direction(visual._rider_skeleton, "LowerLeg.R", "LowerLeg.R_end", Vector3(0.0, 0.0, -1.0), 0.9)
	for marker in ["Fist.L", "Fist.R", "LowerLeg.L_end", "LowerLeg.R_end"]:
		var marker_index := visual._rider_skeleton.find_bone(marker)
		var marker_world := visual._rider_skeleton.to_global(visual._rider_skeleton.get_bone_global_pose(marker_index).origin)
		print(marker, " anchor-local=", visual.rider_anchor.to_local(marker_world))
	var horse_head_index := visual._horse_skeleton.find_bone("Head")
	var horse_head_world := visual._horse_skeleton.to_global(visual._horse_skeleton.get_bone_global_pose(horse_head_index).origin)
	print("Horse head anchor-local=", visual.rider_anchor.to_local(horse_head_world))
	for gait in ["Idle", "Walk", "Gallop"]:
		visual.set_gait(gait)
		await create_timer(0.45).timeout
		print(gait, " clip=", visual._horse_animation.current_animation,
			" anchor=", visual.rider_anchor.position,
			" rider=", rider.position,
			" upper_arm_pose=", visual._rider_skeleton.get_bone_pose_rotation(visual._rider_bone_indices["UpperArm.L"]))
		assert(visual._horse_animation.current_animation == gait, "Horse gait did not switch to " + gait)
	visual.clear_riding_pose(rider)
	assert(is_equal_approx(rider.position.y, 0.0), "Rider model did not restore to on-foot height")
	assert(is_equal_approx(rider.rotation.y, PI), "Rider model did not restore on-foot facing")
	print("Rider pose cleared and original gait/idle animation resumed: ", visual.get_node("RiderAnchor/Casual_Male/AnimationPlayer").current_animation)
	quit()

func _assert_segment_direction(skeleton: Skeleton3D, bone_name: String, child_name: String, target: Vector3, min_dot: float) -> void:
	var bone_index := skeleton.find_bone(bone_name)
	var child_index := skeleton.find_bone(child_name)
	var actual: Vector3 = skeleton.get_bone_global_pose(child_index).origin - skeleton.get_bone_global_pose(bone_index).origin
	var alignment := actual.normalized().dot(target.normalized())
	print("Pose segment ", bone_name, " -> ", child_name, ": ", actual.normalized(), " (alignment ", alignment, ")")
	assert(alignment >= min_dot, "%s segment is not aligned for riding: %.3f" % [bone_name, alignment])
