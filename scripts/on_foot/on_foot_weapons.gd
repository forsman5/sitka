class_name OnFootWeapons extends RefCounted
## Weapons the person can carry in On Foot combat mode. Models are KayKit Fantasy
## Weapons Bits; they are parented to the right-hand bone so they follow every
## animation clip. The hand transform is in bone space and is tuned by eye. The
## skeleton is in centimetres (about 54x after the model scale), so weapon scales
## are tiny; sized for a ~0.7 m sword and ~0.9 m bow on the 0.54-scale person.

const HAND_BONE := "Fist.R"

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
		"rotation_degrees": Vector3(90.0, 0.0, 0.0),
		"scale": 0.0085,
		"attack_anim": "CharacterArmature|Shoot_OneHanded",
		"attack_hold": 0.5,
		"cooldown": 0.8,
		"release_delay": 0.25,
	},
}

const ARROW_SCENE := preload("res://assets/models/weapons/arrow_A.gltf")

## Parents a weapon to the model's right hand and returns it, or null when the
## weapon id is unknown or the model has no skeleton.
static func attach(model: Node3D, weapon: String) -> Node3D:
	if not DEFS.has(weapon):
		return null
	var skeleton := model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null or skeleton.find_bone(HAND_BONE) < 0:
		return null
	var def: Dictionary = DEFS[weapon]
	var holder := BoneAttachment3D.new()
	holder.name = "WeaponHand"
	skeleton.add_child(holder)
	holder.bone_name = HAND_BONE
	var node := (def["scene"] as PackedScene).instantiate() as Node3D
	node.name = "Weapon"
	node.position = def["position"]
	node.rotation_degrees = def["rotation_degrees"]
	node.scale = Vector3.ONE * float(def["scale"])
	holder.add_child(node)
	return holder
