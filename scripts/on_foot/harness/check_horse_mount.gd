extends SceneTree
## Exercises mount, horse movement, and safe dismount in the full On Foot world.


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	OnFootPlayer.selected_character = "person"
	OnFootPlayer.start_sheep_count = 1
	var scene := load("res://scenes/on_foot/on_foot.tscn") as PackedScene
	assert(scene != null)
	var world := scene.instantiate()
	root.add_child(world)
	await physics_frame
	var player := root.get_tree().get_first_node_in_group("on_foot_player") as OnFootPlayer
	var horse := root.get_tree().get_first_node_in_group("on_foot_horse") as OnFootHorse
	assert(player != null and horse != null, "Player or horse did not spawn")
	assert(horse.visual != null, "Horse model is missing")
	player.global_position = horse.global_position + Vector3(-2.0, 0.0, 0.0)
	player._try_mount()
	assert(player._mounted_horse == horse and horse.rider == player, "Mount failed")
	assert(player._model.get_parent() == horse.visual.get_node("RiderAnchor"), "Rider did not attach to horse")
	for i in 30:
		horse.ride_step(1.0 / 60.0, Vector3.FORWARD, true)
		await physics_frame
	assert(horse.global_position.distance_to(Vector3(4.0, horse.global_position.y, -3.0)) > 0.2, "Horse did not move")
	var horse_animation := horse.visual.get("_horse_animation") as AnimationPlayer
	assert(horse_animation.current_animation == "Gallop", "Gallop clip did not play")
	for clip in ["Idle", "Walk", "Gallop"]:
		assert(horse_animation.get_animation(clip).loop_mode == Animation.LOOP_LINEAR, clip + " clip does not loop")
	# Gallop must keep animating: the pose changes over time rather than freezing.
	# Step past several full cycles by hand: a one-shot clip would end and stop playing.
	horse_animation.advance(horse_animation.current_animation_length * 3.3)
	assert(horse_animation.is_playing() and horse_animation.current_animation == "Gallop", "Gallop stopped after one cycle")
	assert(horse_animation.current_animation_position < horse_animation.current_animation_length, "Gallop position stuck at the end")
	for i in 5:
		horse.ride_step(1.0 / 60.0, Vector3.ZERO, false, true)
		await physics_frame
	assert(not horse.is_on_floor() and horse.velocity.y != 0.0, "Horse did not leave the ground on jump")
	assert(horse_animation.current_animation == "Gallop_Jump", "Jump clip did not play")
	var landed := false
	for i in 240:
		horse.ride_step(1.0 / 60.0, Vector3.ZERO, false)
		await physics_frame
		if horse.is_on_floor():
			landed = true
			break
	assert(landed, "Horse never landed after jump")
	horse.ride_step(1.0 / 60.0, Vector3.ZERO, false)
	assert(horse_animation.current_animation != "Gallop_Jump", "Gait stayed on Jump after landing")
	var expected := player._find_dismount_position()
	assert(expected.is_finite(), "No safe dismount point near the horse")
	player._dismount()
	assert(player._mounted_horse == null and horse.rider == null, "Dismount failed")
	assert(player._model.get_parent() == player, "Human model did not return to player")
	assert(player.global_position.distance_to(expected) < 0.5, "Dismount did not use safe ground position")
	player.global_position = horse.global_position + Vector3(-2.0, 0.0, 0.0)
	player._try_mount()
	assert(player._mounted_horse == horse, "Second mount failed")
	var blockers := StaticBody3D.new()
	blockers.collision_layer = 1
	blockers.collision_mask = 0
	world.add_child(blockers)
	for offset in [Vector3(2, 0, 0), Vector3(-2, 0, 0), Vector3(0, 0, 2.2), Vector3(2, 0, 2.2), Vector3(-2, 0, 2.2)]:
		var shape := BoxShape3D.new()
		shape.size = Vector3(1.5, 2.5, 1.5)
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = horse.global_position + horse.global_transform.basis * offset + Vector3.UP * 1.25
		blockers.add_child(col)
	await physics_frame
	player._dismount()
	assert(player._mounted_horse == horse, "Dismount ignored blocked landing area")
	blockers.queue_free()
	await physics_frame
	player._dismount()
	assert(player._mounted_horse == null, "Dismount failed after clearing obstacles")
	print("PASS horse mount, gallop, repeated mount, blocked exit, and safe dismount")
	world.queue_free()
	await process_frame
	quit()
