class_name OnFootWeapons extends RefCounted
## Weapons the person can carry in On Foot combat mode. Models are KayKit Fantasy
## Weapons Bits; they are parented to the hand bone (right for the sword, left for the bow) so they follow every
## animation clip. The hand transform is in bone space and is tuned by eye. The
## skeleton is in centimetres (about 54x after the model scale), so weapon scales
## are tiny; sized for a ~0.7 m sword and ~0.9 m bow on the 0.54-scale person.

const HAND_BONE := "Fist.R"  # default; a def may set "bone" (the bow is held in the left)

const DEFS := {
	"sword": {
		"label": "Sword",
		"scene": preload("res://assets/models/weapons/sword_A.gltf"),
		"position": Vector3(0.0, 0.0, 0.0),
		"rotation_degrees": Vector3(62.86, 162.11, 175.08),
		"scale": 0.0075,
		"attack_anim": "CharacterArmature|SwordSlash",
		"attack_hold": 0.55,
		"cooldown": 0.6,
	},
	"bow": {
		"label": "Bow",
		"scene": preload("res://assets/models/weapons/bow_A_withString.gltf"),
		"position": Vector3(0.0, 0.0, 0.0),
		"bone": "Fist.L",
		# The hand rests at the hip between shots, so lay the bow across the ground
		# plane. The procedural draw pose turns it upright when the player aims.
		"rotation_degrees": Vector3(-96.4, 14.4, -92.3),
		"scale": 0.0093,
		# Hold to draw; release fires. No clip yet: the draw pose (left arm out, right
		# hand pulling the string) is still to be animated.
		"draw_time": 1.0,
		"min_draw": 0.15,
		"cooldown": 0.4,
	},
}

const ARROW_SCENE := preload("res://assets/models/weapons/arrow_A.gltf")

## Parents a weapon to the model's right hand and returns it, or null when the
## weapon id is unknown or the model has no skeleton.
static func attach(model: Node3D, weapon: String) -> Node3D:
	if not DEFS.has(weapon):
		return null
	var skeleton := model.find_child("Skeleton3D", true, false) as Skeleton3D
	var def: Dictionary = DEFS[weapon]
	var bone: String = def.get("bone", HAND_BONE)
	if skeleton == null or skeleton.find_bone(bone) < 0:
		return null
	var holder := BoneAttachment3D.new()
	holder.name = "WeaponHand"
	skeleton.add_child(holder)
	holder.bone_name = bone
	var node := (def["scene"] as PackedScene).instantiate() as Node3D
	node.name = "Weapon"
	node.position = def["position"]
	node.rotation_degrees = def["rotation_degrees"]
	node.scale = Vector3.ONE * float(def["scale"])
	holder.add_child(node)
	return holder

## The bow mesh has a Draw blend shape for its string. Match it to the procedural
## arm pose so the string moves back with the drawing hand.
static func apply_bow_draw_pose(model: Node3D, holder: Node3D, fraction: float, pose_weight: float) -> void:
	if model == null or holder == null:
		return
	var weapon := holder.get_node_or_null("Weapon") as Node3D
	if weapon == null:
		return
	var forward := model.global_transform.basis.z.normalized()
	weapon.global_position = holder.global_position + forward * 0.06 * clampf(pose_weight, 0.0, 1.0)
	var mesh_instances := weapon.find_children("*", "MeshInstance3D", true, false)
	if mesh_instances.is_empty():
		return
	var mesh_instance := mesh_instances[0] as MeshInstance3D
	if mesh_instance.mesh == null:
		return
	var draw_shape := -1
	for shape_index in mesh_instance.mesh.get_blend_shape_count():
		if mesh_instance.mesh.get_blend_shape_name(shape_index) == "Draw":
			draw_shape = shape_index
			break
	if draw_shape >= 0:
		mesh_instance.set_blend_shape_value(draw_shape, clampf(fraction * pose_weight, 0.0, 1.0))
