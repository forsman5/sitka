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
	assert(visual._rider_bone_indices.size() == RidingHorseVisual.RIDER_POSE_DEGREES.size(), "Rider pose bone mapping incomplete")
	print("RiderAnchor path: ", visual.rider_anchor.get_path())
	print("Horse model scale: ", visual._horse_model.scale, "; rider scale: ", rider.scale)
	for gait in ["Idle", "Walk", "Gallop"]:
		visual.set_gait(gait)
		await create_timer(0.45).timeout
		print(gait, " clip=", visual._horse_animation.current_animation,
			" anchor=", visual.rider_anchor.position,
			" rider=", rider.position,
			" torso_pose=", visual._rider_skeleton.get_bone_pose_rotation(visual._rider_bone_indices["Torso"]))
		assert(visual._horse_animation.current_animation == gait, "Horse gait did not switch to " + gait)
	visual.clear_riding_pose(rider)
	assert(is_equal_approx(rider.position.y, 0.0), "Rider model did not restore to on-foot height")
	assert(is_equal_approx(rider.rotation.y, PI), "Rider model did not restore on-foot facing")
	print("Rider pose cleared and original gait/idle animation resumed: ", visual.get_node("RiderAnchor/Casual_Male/AnimationPlayer").current_animation)
	quit()
