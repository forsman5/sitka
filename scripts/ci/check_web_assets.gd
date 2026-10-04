extends SceneTree

## Fail the Web build if Godot silently skips model imports on a fresh runner.
const REQUIRED_MODELS: PackedStringArray = [
	"res://assets/models/animals/Cow.fbx",
	"res://assets/models/buildings/building_castle_blue.gltf",
	"res://assets/models/buildings/building_home_A_blue.gltf",
	"res://assets/models/buildings/building_home_B_blue.gltf",
	"res://assets/models/buildings/building_tavern_blue.gltf",
	"res://assets/models/buildings/tent.gltf",
	"res://assets/models/nature/tree_single_A.gltf",
	"res://assets/models/nature/tree_single_B.gltf",
]

func _initialize() -> void:
	call_deferred("_check")

func _check() -> void:
	var failures := 0
	for path in REQUIRED_MODELS:
		var scene := ResourceLoader.load(path, "PackedScene") as PackedScene
		if scene == null:
			push_error("Web asset did not import: %s" % path)
			failures += 1
			continue
		var instance := scene.instantiate()
		if not _has_mesh(instance):
			push_error("Web asset has no mesh: %s" % path)
			failures += 1
		instance.free()

	var capital_scene := ResourceLoader.load("res://scenes/entities/building/capital.tscn") as PackedScene
	if capital_scene == null:
		push_error("Capital scene did not load")
		failures += 1
	else:
		var capital := capital_scene.instantiate()
		var castle := capital.get_node_or_null("CastleMesh")
		if castle == null or not _has_mesh(castle):
			push_error("Capital scene has no visible castle mesh")
			failures += 1
		capital.free()

	if failures == 0:
		print("Web asset check passed: %d models and capital mesh" % REQUIRED_MODELS.size())
	quit(1 if failures else 0)

func _has_mesh(node: Node) -> bool:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return true
	for child in node.get_children():
		if _has_mesh(child):
			return true
	return false
