extends SceneTree

## Renders the person holding each weapon (needs a real renderer, so run
## without --headless):
##   godot --path . --script res://scripts/on_foot/harness/capture_weapons.gd -- --output=C:/tmp/weapons.png [--anim=attack] [--draw=1.0] [--fp=x,y,z] [--only=bow]

func _init() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var output_path := "user://weapons.png"
	var anim_mode := "idle"
	var draw_fraction := -1.0
	var aim_pitch := 0.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
		elif argument.begins_with("--anim="):
			anim_mode = argument.trim_prefix("--anim=")
		elif argument.begins_with("--pitch="):
			aim_pitch = deg_to_rad(float(argument.trim_prefix("--pitch=")))
		elif argument.begins_with("--draw="):
			draw_fraction = clampf(float(argument.trim_prefix("--draw=")), 0.0, 1.0)

	var world := Node3D.new()
	root.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	world.add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.45, 0.55, 0.65)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.7)
	world.add_child(env)

	# --sweep=<weapon> renders that weapon at several hand rotations (x,y,z degrees,
	# semicolon-separated) so a hold can be picked by eye.
	var sweep_weapon := ""
	var sweep_rots: Array = []
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--sweep="):
			sweep_weapon = argument.trim_prefix("--sweep=")
		elif argument.begins_with("--rots="):
			for part in argument.trim_prefix("--rots=").split(";"):
				var v := part.split(",")
				sweep_rots.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
	var jobs: Array = []
	if sweep_weapon != "":
		for r in sweep_rots:
			jobs.append([sweep_weapon, r])
	else:
		var only := ""
		for argument in OS.get_cmdline_user_args():
			if argument.begins_with("--only="):
				only = argument.trim_prefix("--only=")
		for weapon in OnFootWeapons.DEFS:
			if only == "" or weapon == only:
				jobs.append([weapon, null])

	var side := "--side" in OS.get_cmdline_user_args()
	var oblique := "--oblique" in OS.get_cmdline_user_args()
	var step := 1.3 if side else 2.4
	var x := -step * (jobs.size() - 1) * 0.5
	for job in jobs:
		var weapon: String = job[0]
		var model: Node3D = (OnFootPlayer.CHARACTERS["person"]["model"] as PackedScene).instantiate()
		model.rotation_degrees = Vector3(0, 180, 0)
		model.scale = Vector3.ONE * float(OnFootPlayer.CHARACTERS["person"]["model_scale"])
		model.position = Vector3(0, 0, x) if side else Vector3(x, 0, 0)
		world.add_child(model)
		var holder := OnFootWeapons.attach(model, weapon)
		if holder == null:
			push_error("could not attach %s" % weapon)
		elif job[1] != null:
			holder.get_node("Weapon").rotation_degrees = job[1]
		var anim := model.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if anim:
			var clip := "CharacterArmature|Idle"
			if anim_mode == "attack":
				clip = OnFootWeapons.DEFS[weapon].get("attack_anim", clip)
			anim.play(clip)
			anim.seek(0.25 if anim_mode == "attack" else 0.0, true)
			anim.pause()
		if weapon == "bow" and draw_fraction >= 0.0:
			var skeleton := model.find_child("Skeleton3D", true, false) as Skeleton3D
			var bones := {}
			for bone_name in ["UpperArm.L", "LowerArm.L", "UpperArm.R", "LowerArm.R", "Torso"]:
				bones[bone_name] = skeleton.find_bone(bone_name)
			OnFootPlayer.apply_bow_pose_to_skeleton(skeleton, bones, 1.0, draw_fraction)
			OnFootPlayer.apply_aim_pitch_to_skeleton(skeleton, bones["Torso"], aim_pitch)
			OnFootWeapons.apply_bow_draw_pose(model, holder, draw_fraction, 1.0)
		if "--fp" in "".join(OS.get_cmdline_user_args()):
			_hide_hair(model)
			_print_bow_points(model, holder)
		x += step

	var cam := Camera3D.new()
	var fp_pos := Vector3.INF
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fp="):
			var v := argument.trim_prefix("--fp=").split(",")
			fp_pos = Vector3(float(v[0]), float(v[1]), float(v[2]))
	cam.position = Vector3(4.2 + 2.0 * jobs.size(), 1.1, 0) if side else Vector3(3.1, 1.6, -4.2) if oblique else Vector3(0, 1.1, -4.2 if "--front" in OS.get_cmdline_user_args() else 4.2)
	cam.look_at_from_position(cam.position, Vector3(0, 0.95, 0))
	cam.fov = 40.0 + 12.0 * maxf(jobs.size() - 2, 0.0)
	if side:
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 2.6
		cam.position = Vector3(6.0, 0.7, 0.0)
		cam.look_at_from_position(cam.position, Vector3(0, 0.7, 0))
	if fp_pos != Vector3.INF:
		# First-person view from the player's camera position (x,y,z; the model faces -Z).
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = 80.0
		cam.position = fp_pos
		cam.rotation = Vector3.ZERO
	world.add_child(cam)
	cam.current = true

	await process_frame
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(output_path)
	print("saved %s (%s)" % [output_path, error_string(error)])
	quit(0 if error == OK else 1)


## Mirrors OnFootPlayer's first-person hair hiding so the capture matches the game.
func _hide_hair(model: Node3D) -> void:
	var hair := model.find_child("Body2", true, false) as MeshInstance3D
	if hair == null or hair.mesh == null:
		return
	var invisible := StandardMaterial3D.new()
	invisible.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	invisible.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
	invisible.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	for i in hair.mesh.get_surface_count():
		if hair.mesh.surface_get_name(i) in ["Hair", "Face"]:
			hair.set_surface_override_material(i, invisible)

func _print_bow_points(model: Node3D, holder: Node3D) -> void:
	var skeleton := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		return
	for bone_name in ["Head", "Fist.L", "Fist.R"]:
		var index := skeleton.find_bone(bone_name)
		if index >= 0:
			print("%s %s" % [bone_name, skeleton.to_global(skeleton.get_bone_global_pose(index).origin)])
	if holder != null:
		print("holder %s" % holder.global_position)
