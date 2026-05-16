extends "res://scripts/entities/building/deposit_building.gd"

const BUNK_BEDS_COST := 50
@export var bed_count: int = 4

func get_available_upgrades() -> Array:
	if has_upgrade("bunk_beds"):
		return []
	return [{"id": "bunk_beds", "label": "Bunk Beds (%dw)" % BUNK_BEDS_COST, "cost_wood": BUNK_BEDS_COST}]

func get_bed_count() -> int:
	return bed_count if has_upgrade("bunk_beds") else 0

func _on_upgrade_applied(id: String) -> void:
	if id == "bunk_beds":
		add_to_group("sleep_point")
		_add_upgrade_marker()

func _add_upgrade_marker() -> void:
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.25
	sphere.height = 0.5
	marker.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.8, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.5, 0.8)
	marker.set_surface_override_material(0, mat)
	marker.position = Vector3(0.0, 3.2, 0.0)
	add_child(marker)
