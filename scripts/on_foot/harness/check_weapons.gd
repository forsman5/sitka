extends SceneTree
## Spawns the On Foot world armed and exercises the sword swing and bow shot. Run with:
##   godot --headless --path . --script res://scripts/on_foot/harness/check_weapons.gd

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

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
	check(player.attack(), "sword attack starts")
	check(not player.attack(), "sword attack respects cooldown")
	player._update_animation()
	check(player._anim.current_animation == "CharacterArmature|SwordSlash", "slash clip plays (got %s)" % player._anim.current_animation)
	spawned[0].queue_free()
	await process_frame

	# Bow: attached, shot plays the clip then releases an arrow that flies and sticks.
	spawned = await _spawn("bow")
	player = spawned[1]
	check(player._model.find_child("WeaponHand", true, false) != null, "bow is in hand")
	check(player.attack(), "bow attack starts")
	player._update_animation()
	check(player._anim.current_animation == "CharacterArmature|Shoot_OneHanded", "shoot clip plays (got %s)" % player._anim.current_animation)
	await create_timer(0.4).timeout
	var arrow: OnFootArrow = null
	for child in spawned[0].get_children():
		if child is OnFootArrow:
			arrow = child
	check(arrow != null, "an arrow was released")
	if arrow != null:
		# The world auto-pauses without a captured mouse (headless), so step by hand.
		var start := arrow.global_position
		for i in 20:
			arrow._physics_process(1.0 / 60.0)
		check(arrow.global_position.distance_to(start) > 5.0, "arrow flew")
		check(arrow.velocity.y < 0.0, "gravity pulls the arrow down")
	spawned[0].queue_free()
	await process_frame

	OnFootPlayer.selected_weapon = ""
	if failures == 0:
		print("WEAPONS OK")
	quit(1 if failures else 0)
