extends SceneTree

const Rig = preload("res://scripts/camera/rts_camera.gd")
var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

func _run() -> void:
	var rig := Node3D.new()
	rig.set_script(Rig)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	rig.add_child(camera)
	root.add_child(rig)
	rig.set_process(false)
	rig.position = Vector3(12, 0, -9)
	var anchor := rig.position
	for tilt in [90.0, 50.0, 20.0]:
		rig._current_tilt = tilt
		for yaw in [0.0, 45.0, 90.0, 180.0, 270.0, 360.0]:
			rig.rotate_view(yaw - rig._current_yaw)
			check(rig.position.is_equal_approx(anchor), "Rotation moved the orbit anchor")
			var forward := -camera.global_basis.z
			var hit := camera.global_position + forward * (-camera.global_position.y / forward.y)
			check(hit.distance_to(anchor) < 0.001, "Camera no longer points at orbit anchor")
	rig._current_tilt = 50.0
	rig.rotate_view(-rig._current_yaw)
	var original: Vector2 = rig._visible_half_extent()
	rig.rotate_view(90.0)
	var rotated: Vector2 = rig._visible_half_extent()
	check(rotated.is_equal_approx(Vector2(original.y, original.x)), "Rotated bounds do not swap axes")
	check(rig._screen_ground_direction(Vector3.RIGHT).is_equal_approx(Vector3.FORWARD), "Pan is not camera-relative")
	rig.pan_limit = Vector2(100, 100)
	rig.center_on(Vector3(1000, 0, 1000))
	check(rig.position.x + rotated.x <= 100.001 and rig.position.z + rotated.y <= 100.001, "Rotated boundary clamp failed")
	rig.free()
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("PASS: camera orbit anchor, tilt/yaw combinations, relative pan, and rotated bounds")
	quit(0 if failures.is_empty() else 1)
