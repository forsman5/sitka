extends SceneTree
## Spawns the On Foot world armed and exercises the sword swing and bow shot. Run with:
##   godot --path . --script res://scripts/on_foot/harness/check_weapons.gd (windowed, so the click path runs; --headless skips it)

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func _arrows(world: Node) -> Array:
	return world.get_children().filter(func(c): return c is OnFootArrow)

func _spawn(weapon: String) -> Array:
	OnFootPlayer.selected_character = "person"
	OnFootPlayer.selected_weapon = weapon
	OnFootPlayer.start_sheep_count = 1
	var world := (load("res://scenes/on_foot/on_foot.tscn") as PackedScene).instantiate()
	root.add_child(world)
	await physics_frame
	await physics_frame
	var player := get_first_node_in_group("on_foot_player") as OnFootPlayer
	return [world, player]

func _run() -> void:
	# Bare hands: nothing attached, attack() declines.
	var spawned: Array = await _spawn("")
	var player: OnFootPlayer = spawned[1]
	check(player != null, "player spawns unarmed")
	check(player._model.find_child("WeaponHand", true, false) == null, "unarmed person has no weapon in hand")
	check(not player.attack(), "attack() does nothing without a weapon")
	spawned[0].queue_free()
	await process_frame

	# Sword: attached to the hand bone, swing plays the slash clip.
	spawned = await _spawn("sword")
	player = spawned[1]
	check(player._model.find_child("WeaponHand", true, false) != null, "sword is in hand")
	# A real left click must start the attack (the click handler, not just attack()).
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	player._unhandled_input(click)
	# Mouse capture only works with a real window, so skip this part when headless.
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		check(player._attack_cooldown_left > 0.0, "left click swings the sword")
	player._attack_cooldown_left = 0.0
	check(player.attack(), "sword attack starts")
	check(not player.attack(), "sword attack respects cooldown")
	player._update_animation()
	check(player._anim.current_animation == "CharacterArmature|SwordSlash", "slash clip plays (got %s)" % player._anim.current_animation)
	spawned[0].queue_free()
	await process_frame

	# Bow: held in the left hand; hold to draw, release to loose an arrow whose
	# power grows with draw time. A tap shorter than min_draw does nothing.
	spawned = await _spawn("bow")
	var world: Node = spawned[0]
	player = spawned[1]
	var holder := player._model.find_child("WeaponHand", true, false) as BoneAttachment3D
	check(holder != null and holder.bone_name == "Fist.L", "bow is in the left hand")
	check(player.attack() and player._drawing, "bow attack starts a draw")
	check(player.draw_fraction() == 0.0, "draw starts at zero")
	player.release_draw()
	check(_arrows(world).is_empty(), "a tap shorter than min_draw fires nothing")
	check(not player._drawing, "a cancelled draw stops drawing")

	player._attack_cooldown_left = 0.0
	player.attack()
	player._draw_time = 0.5
	check(is_equal_approx(player.draw_fraction(), 0.5), "half draw is 0.5")
	player._process(0.1)
	check(is_equal_approx(player._bow_draw_fraction, 0.5) and player._bow_pose_weight > 0.0, "draw pose tracks half draw strength")
	player.release_draw()
	var pose_before_ease: float = player._bow_pose_weight
	player._process(0.05)
	check(player._bow_pose_weight < pose_before_ease and player._bow_pose_weight > 0.0, "draw pose eases out after release")
	var arrows := _arrows(world)
	check(arrows.size() == 1, "an arrow is released on button release")
	var half_speed: float = arrows[0].velocity.length() if arrows.size() == 1 else 0.0
	player._attack_cooldown_left = 0.0
	player.attack()
	player._draw_time = 5.0
	check(is_equal_approx(player.draw_fraction(), 1.0), "draw caps at 1")
	player.release_draw()
	arrows = _arrows(world)
	check(arrows.size() == 2, "a second arrow is released")
	if arrows.size() == 2:
		var full: OnFootArrow = arrows[1]
		check(is_equal_approx(full.velocity.length(), OnFootArrow.SPEED), "full draw shoots at full speed")
		check(half_speed < full.velocity.length(), "a shorter draw shoots slower")
		# The world auto-pauses without a captured mouse (headless), so step by hand.
		var start := full.global_position
		for i in 20:
			full._physics_process(1.0 / 60.0)
		check(full.global_position.distance_to(start) > 5.0, "arrow flew")
		check(full.velocity.y < 0.0, "gravity pulls the arrow down")
	# Real button events (windowed only): press starts a draw, release looses it.
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		player._attack_cooldown_left = 0.0
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		player._unhandled_input(press)
		check(player._drawing, "left press starts drawing the bow")
		player._draw_time = 1.0
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		player._unhandled_input(release)
		check(not player._drawing and _arrows(world).size() == 3, "left release looses the arrow")
	world.queue_free()
	await process_frame

	OnFootPlayer.selected_weapon = ""
	if failures == 0:
		print("WEAPONS OK")
	quit(1 if failures else 0)
