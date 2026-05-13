extends StaticBody3D

signal world_clicked(world_pos: Vector3)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var camera := get_viewport().get_camera_3d()
		if camera == null:
			return
		var hit := _raycast_y0(camera, event.position)
		if hit != Vector3.INF:
			world_clicked.emit(hit)

# Intersect camera ray with the Y=0 ground plane. Returns Vector3.INF on miss.
func _raycast_y0(camera: Camera3D, screen_pos: Vector2) -> Vector3:
	var origin := camera.project_ray_origin(screen_pos)
	var dir    := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.0001:
		return Vector3.INF
	var t := -origin.y / dir.y
	if t < 0.0:
		return Vector3.INF
	return origin + dir * t
