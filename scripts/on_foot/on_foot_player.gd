class_name OnFootPlayer extends CharacterBody3D
## Walker: WASD + mouse look, Space to jump, Shift to sprint, F5 cycles the
## camera (first person -> third person behind -> third person in front).
## Keys are read by physical keycode so no InputMap entries are needed.

@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var ground_accel: float = 60.0
@export var ground_friction: float = 50.0
@export var air_accel: float = 12.0
@export var jump_height: float = 1.2
@export var gravity_scale: float = 2.2
@export var fall_gravity_mult: float = 1.35
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.1
@export var mouse_sensitivity: float = 0.0022
@export var eye_height: float = 1.65
@export var bob_amount: float = 0.04
@export var bob_frequency: float = 2.2
@export var third_person_distance: float = 3.2
@export var bark_cooldown: float = 0.45
## A bark carries this many times farther than the normal scare radius.
@export var bark_range_multiplier: float = 2.0
## How fast (rad/s) the model turns to face its direction of travel.
@export var model_turn_speed: float = 10.0

signal barked(world_position: Vector3)

enum CameraMode { FIRST_PERSON, THIRD_BACK, THIRD_FRONT }

## Individual barks (see assets/audio/bark/CREDITS.md). Alternatives to audition
## live in assets/audio/bark/options/.
const DOG_BARKS: Array = [
	preload("res://assets/audio/bark/bark_1.wav"),
	preload("res://assets/audio/bark/bark_2.wav"),
	preload("res://assets/audio/bark/bark_3.wav"),
	preload("res://assets/audio/bark/bark_4.wav"),
]

## Which character the next OnFootPlayer spawns as (set by the chooser scene).
static var selected_character: String = "person"

## Per-sheep chance of a lamb each night, as a percentage. Tunable from the
## chooser scene while validating; hide that field before release.
static var sheep_repro_percent: float = 10.0

## Weapon the person spawns holding ("sword", "bow", or "" for bare hands); set
## by the combat chooser scene. Ignored for the dog.
static var selected_weapon: String = ""

## Sheep in the flock at the start of a fresh run (set from the chooser scene).
## The pen grows to fit.
static var start_sheep_count: int = 25

## Per-character body, camera and animation settings. Models face +Z at identity,
## so they are rotated half a turn to face the -Z movement direction.
const CHARACTERS := {
	"person": {
		"model": preload("res://assets/models/people/Casual_Male.fbx"),
		"model_scale": 0.54,
		"capsule_radius": 0.35,
		"capsule_height": 1.8,
		"eye_height": 1.65,
		"third_person_distance": 3.2,
		"walk_speed": 5.0,
		"sprint_speed": 8.5,
		"jump_height": 1.2,
		"scare_radius": 8.0,
		"barks": [],
		"anim": {
			"idle": "CharacterArmature|Idle",
			"walk": "CharacterArmature|Walk",
			"run": "CharacterArmature|Run",
			"jump": "CharacterArmature|Jump",
		},
	},
	"dog": {
		"model": preload("res://assets/models/animals/Husky.fbx"),
		"model_scale": 0.25,
		"capsule_radius": 0.3,
		"capsule_height": 0.8,
		"eye_height": 0.6,
		"third_person_distance": 2.2,
		"walk_speed": 3.5,
		"sprint_speed": 8.0,
		"jump_height": 0.9,
		"scare_radius": 15.0,
		"barks": DOG_BARKS,
		"bark_anim": "AnimalArmature|Attack",
		"anim": {
			"idle": "AnimalArmature|Idle",
			"walk": "AnimalArmature|Walk",
			"run": "AnimalArmature|Gallop",
			"jump": "AnimalArmature|Gallop_Jump",
		},
	},
}

var _head: Node3D
var _arm: SpringArm3D
var _camera: Camera3D
var _model: Node3D
var _anim: AnimationPlayer
var _skeleton: Skeleton3D
var _bow_bones: Dictionary = {}
var _bow_pose_weight: float = 0.0
var _bow_draw_fraction: float = 0.0
var _hair_mesh: MeshInstance3D
var _hair_surface_index: int = -1
var _hidden_hair_material: StandardMaterial3D
var _collision_shape: CollisionShape3D
var _mounted_horse: OnFootHorse
var _foot_camera_mode: int = CameraMode.THIRD_BACK
var _camera_mode: int = CameraMode.THIRD_BACK
var _bark_player: AudioStreamPlayer3D
var _bark_cooldown_left: float = 0.0
var _bark_anim_left: float = 0.0
var _bark_anim_pending: bool = false
var _last_bark: int = -1
var _weapon: String = ""
var _drawing: bool = false
var _draw_time: float = 0.0
var _attack_cooldown_left: float = 0.0
var _attack_anim_pending: bool = false
var _pitch: float = 0.0
var _coyote_left: float = 0.0
var _buffer_left: float = 0.0
var _bob_t: float = 0.0
var _was_on_floor: bool = true
var _land_dip: float = 0.0
var _gravity: float
var _character: Dictionary

## Where to put the player back if they ever fall out of the world.
var spawn_point: Vector3 = Vector3.ZERO
@export var fall_limit: float = -8.0

func _ready() -> void:
	_character = CHARACTERS[selected_character]
	add_to_group("on_foot_player")
	# The island terrain lives on layer 2 (the RTS uses it for click picking).
	collision_mask = 1 | 2
	# Stay glued to rolling terrain instead of going briefly airborne on slopes.
	floor_snap_length = 0.5
	walk_speed = _character["walk_speed"]
	sprint_speed = _character["sprint_speed"]
	jump_height = _character["jump_height"]
	eye_height = _character["eye_height"]
	third_person_distance = _character["third_person_distance"]
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * gravity_scale

	var shape := CapsuleShape3D.new()
	shape.radius = _character["capsule_radius"]
	shape.height = _character["capsule_height"]
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5
	add_child(col)
	_collision_shape = col

	_head = Node3D.new()
	_head.position.y = eye_height
	add_child(_head)

	# SpringArm pulls the camera in when something is between it and the head.
	_arm = SpringArm3D.new()
	_arm.shape = SphereShape3D.new()
	(_arm.shape as SphereShape3D).radius = 0.2
	_arm.margin = 0.1
	_arm.add_excluded_object(get_rid())
	_head.add_child(_arm)

	_camera = Camera3D.new()
	_camera.fov = 80.0
	_camera.current = true
	_arm.add_child(_camera)

	_model = (_character["model"] as PackedScene).instantiate()
	_model.rotation_degrees = Vector3(0, 180, 0)
	_model.scale = Vector3.ONE * float(_character["model_scale"])
	add_child(_model)
	if selected_character == "person":
		SkinTones.apply_random(_model)
	_anim = _model.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if selected_character == "person" and selected_weapon != "":
		_skeleton = _model.find_child("Skeleton3D", true, false) as Skeleton3D
		if selected_weapon == "bow":
			_setup_first_person_hair()
		var holder := OnFootWeapons.attach(_model, selected_weapon)
		if holder != null:
			_weapon = selected_weapon
			if _weapon == "bow":
				for bone_name in ["UpperArm.L", "LowerArm.L", "UpperArm.R", "LowerArm.R"]:
					_bow_bones[bone_name] = _skeleton.find_bone(bone_name)

	_bark_player = AudioStreamPlayer3D.new()
	_bark_player.position.y = eye_height * 0.8
	_bark_player.unit_size = 15.0
	_bark_player.max_distance = 150.0
	add_child(_bark_player)

	_set_camera_mode(_camera_mode)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	set_process_priority(100)

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -PI * 0.495, PI * 0.495)
		_head.rotation.x = _pitch
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT 			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if _weapon != "":
			attack()
		else:
			bark()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		release_draw()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_SPACE:
			if _mounted_horse == null:
				_buffer_left = jump_buffer_time
		elif event.physical_keycode == KEY_F5:
			_set_camera_mode((_camera_mode + 1) % CameraMode.size())
		elif event.physical_keycode == KEY_E and selected_character == "person":
			if _mounted_horse != null:
				_dismount()
			else:
				_try_mount()

## Left click: play a random bark (dog only; the person has none). Returns whether
## a bark played. Emits `barked` so animals can react later.
func bark() -> bool:
	var barks: Array = _character.get("barks", [])
	if barks.is_empty() or _bark_cooldown_left > 0.0:
		return false
	# Never the same clip twice in a row, and a little pitch variation.
	var idx := randi() % barks.size()
	if barks.size() > 1 and idx == _last_bark:
		idx = (idx + 1 + randi() % (barks.size() - 1)) % barks.size()
	_last_bark = idx
	_bark_player.stream = barks[idx]
	_bark_player.pitch_scale = randf_range(0.93, 1.07)
	_bark_player.play()
	_bark_cooldown_left = bark_cooldown
	_bark_anim_pending = _character.has("bark_anim")
	barked.emit(global_position)
	return true

## Left click with a weapon: swing the sword, or loose an arrow where the camera
## points. Returns whether an attack started.
func attack() -> bool:
	if _weapon == "" or _attack_cooldown_left > 0.0 or _mounted_horse != null or _drawing:
		return false
	var def: Dictionary = OnFootWeapons.DEFS[_weapon]
	if def.has("draw_time"):
		# Bow: start drawing; letting go of the button fires (see release_draw).
		_drawing = true
		_draw_time = 0.0
		return true
	_attack_cooldown_left = float(def["cooldown"])
	_attack_anim_pending = true
	return true

## 0..1 draw strength of the bow right now (0 when not drawing).
func draw_fraction() -> float:
	if not _drawing:
		return 0.0
	return clampf(_draw_time / float(OnFootWeapons.DEFS[_weapon]["draw_time"]), 0.0, 1.0)

## Left button released: loose the arrow with power scaled by how long it was
## drawn (full power after draw_time). A tap shorter than min_draw cancels.
func release_draw() -> void:
	if not _drawing:
		return
	var def: Dictionary = OnFootWeapons.DEFS[_weapon]
	var fraction := draw_fraction()
	var held := _draw_time
	_drawing = false
	_draw_time = 0.0
	if held < float(def["min_draw"]):
		return
	_attack_cooldown_left = float(def["cooldown"])
	_release_arrow(lerpf(OnFootArrow.MIN_POWER, 1.0, fraction))

func _release_arrow(power: float) -> void:
	if not is_inside_tree():
		return
	var arrow := OnFootArrow.new()
	get_parent().add_child(arrow)
	var forward := -_camera.global_transform.basis.z
	arrow.global_position = _head.global_position + forward * 0.6
	arrow.velocity = forward * OnFootArrow.SPEED * power
	arrow.look_at(arrow.global_position + forward, Vector3.UP)

## How far (in metres) a bark startles animals.
func bark_radius() -> float:
	return scare_radius() * bark_range_multiplier

## How close (in metres) animals let this character get before fleeing.
func scare_radius() -> float:
	return _character["scare_radius"]

func _set_camera_mode(mode: int) -> void:
	_camera_mode = mode
	# Keep the bow user visible in first person so the draw pose can be seen.
	# Move the camera just ahead of the face; the body stays behind the view.
	var show_bow_pose := mode == CameraMode.FIRST_PERSON and _weapon == "bow"
	_model.visible = mode != CameraMode.FIRST_PERSON or show_bow_pose
	_head.position.z = -0.24 if show_bow_pose else 0.0
	_set_first_person_hair_hidden(show_bow_pose)
	_arm.spring_length = 0.0 if mode == CameraMode.FIRST_PERSON else third_person_distance
	# Rotating the arm half a turn puts the camera in front, looking back at us.
	_arm.rotation.y = PI if mode == CameraMode.THIRD_FRONT else 0.0

func _setup_first_person_hair() -> void:
	_hair_mesh = _model.find_child("Body2", true, false) as MeshInstance3D
	if _hair_mesh == null or _hair_mesh.mesh == null:
		return
	for surface_index in _hair_mesh.mesh.get_surface_count():
		if _hair_mesh.mesh.surface_get_name(surface_index) == "Hair":
			_hair_surface_index = surface_index
			break
	_hidden_hair_material = StandardMaterial3D.new()
	_hidden_hair_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hidden_hair_material.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
	_hidden_hair_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

func _set_first_person_hair_hidden(hidden: bool) -> void:
	if _hair_mesh == null or _hair_surface_index < 0:
		return
	_hair_mesh.set_surface_override_material(_hair_surface_index, _hidden_hair_material if hidden else null)

func _physics_process(delta: float) -> void:
	_bark_cooldown_left = maxf(_bark_cooldown_left - delta, 0.0)
	_bark_anim_left = maxf(_bark_anim_left - delta, 0.0)
	_attack_cooldown_left = maxf(_attack_cooldown_left - delta, 0.0)
	if _drawing:
		_draw_time += delta
	if _mounted_horse != null:
		_mounted_step(delta)
		return
	if global_position.y < fall_limit:
		global_position = spawn_point
		velocity = Vector3.ZERO

	var on_floor := is_on_floor()

	# Landing dip, scaled by impact speed.
	if on_floor and not _was_on_floor:
		_land_dip = clampf(-velocity.y * 0.012, 0.0, 0.12)
	_was_on_floor = on_floor

	if on_floor:
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)
	_buffer_left = maxf(_buffer_left - delta, 0.0)

	# Gravity (heavier on the way down for a snappier arc).
	if not on_floor:
		var g := _gravity * (fall_gravity_mult if velocity.y < 0.0 else 1.0)
		velocity.y -= g * delta

	# Jump: buffered press + coyote window. Holding Space re-jumps on landing.
	if _buffer_left > 0.0 and _coyote_left > 0.0:
		velocity.y = sqrt(2.0 * _gravity * jump_height)
		_buffer_left = 0.0
		_coyote_left = 0.0
	elif on_floor and Input.is_physical_key_pressed(KEY_SPACE) and _buffer_left <= 0.0:
		_buffer_left = jump_buffer_time

	# Horizontal movement.
	var input := Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		input.x = int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A))
		input.y = int(Input.is_physical_key_pressed(KEY_S)) - int(Input.is_physical_key_pressed(KEY_W))
	input = input.limit_length(1.0)
	var wish := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized() * input.length()
	var speed := sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	var target := Vector3(wish.x, 0.0, wish.z) * speed
	var horiz := Vector3(velocity.x, 0.0, velocity.z)

	if input != Vector2.ZERO:
		horiz = horiz.move_toward(target, (ground_accel if on_floor else air_accel) * delta)
	elif on_floor:
		horiz = horiz.move_toward(Vector3.ZERO, ground_friction * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z

	move_and_slide()
	_update_model_facing(delta)
	_update_camera(delta)
	_update_animation()

func _process(delta: float) -> void:
	if _weapon != "bow" or _skeleton == null:
		return
	if _drawing:
		_bow_draw_fraction = draw_fraction()
	_bow_pose_weight = move_toward(_bow_pose_weight, 1.0 if _drawing else 0.0, delta * (7.0 if _drawing else 5.0))
	if _bow_pose_weight <= 0.001:
		_bow_draw_fraction = 0.0
	_apply_bow_pose(_bow_pose_weight, _bow_draw_fraction)

func _apply_bow_pose(weight: float, fraction: float) -> void:
	apply_bow_pose_to_skeleton(_skeleton, _bow_bones, weight, fraction)

static func apply_bow_pose_to_skeleton(skeleton: Skeleton3D, bones: Dictionary, weight: float, fraction: float) -> void:
	if skeleton == null:
		return
	# Imported armature axes: -Y is forward, +Z is up. Segment vectors are in
	# Skeleton3D space; solve rotations from each bone's actual rest segment.
	var hand_back := lerpf(0.12, 0.62, fraction)
	var elbow_up := lerpf(0.34, 0.49, fraction)
	var poses := [
		{"bone": "UpperArm.L", "child": "LowerArm.L", "direction": Vector3(0.0, -0.90, 0.42)},
		{"bone": "LowerArm.L", "child": "Fist.L", "direction": Vector3(0.0, -0.98, 0.18)},
		{"bone": "UpperArm.R", "child": "LowerArm.R", "direction": Vector3(0.30, -0.91, elbow_up)},
		{"bone": "LowerArm.R", "child": "Fist.R", "direction": Vector3(0.22 - fraction * 0.12, hand_back, 0.42)},
	]
	for segment in poses:
		var bone_index := int(bones.get(segment["bone"], -1))
		var child_index := skeleton.find_bone(segment["child"])
		if bone_index < 0 or child_index < 0:
			continue
		var rest := skeleton.get_bone_global_rest(bone_index)
		var child_rest := skeleton.get_bone_global_rest(child_index)
		var local_segment: Vector3 = rest.basis.inverse() * (child_rest.origin - rest.origin)
		var animated_rotation := skeleton.get_bone_pose_rotation(bone_index)
		skeleton.set_bone_pose_rotation(bone_index, Quaternion.IDENTITY)
		var parent_basis := skeleton.get_bone_global_pose(bone_index).basis
		var target_local: Vector3 = parent_basis.inverse() * segment["direction"]
		var target_rotation := Quaternion(local_segment.normalized(), target_local.normalized())
		skeleton.set_bone_pose_rotation(bone_index, animated_rotation.slerp(target_rotation, weight))


func _try_mount() -> void:
	for node in get_tree().get_nodes_in_group("on_foot_horse"):
		var horse := node as OnFootHorse
		if horse == null or horse.rider != null:
			continue
		var offset := horse.global_position - global_position
		if Vector2(offset.x, offset.z).length() > 3.0 or absf(offset.y) > 1.5:
			continue
		_mounted_horse = horse
		_drawing = false
		horse.rider = self
		horse.stop()
		_foot_camera_mode = _camera_mode
		_set_camera_mode(CameraMode.THIRD_BACK)
		eye_height = 2.45
		third_person_distance = 4.4
		_arm.spring_length = third_person_distance
		_collision_shape.set_deferred("disabled", true)
		collision_layer = 0
		collision_mask = 0
		velocity = Vector3.ZERO
		_buffer_left = 0.0
		var anchor := horse.visual.get_node("RiderAnchor") as Node3D
		_model.reparent(anchor, false)
		horse.visual.call("apply_riding_pose", _model)
		_sync_mounted_camera()
		return


func _mounted_step(delta: float) -> void:
	var input := Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		input.x = int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A))
		input.y = int(Input.is_physical_key_pressed(KEY_S)) - int(Input.is_physical_key_pressed(KEY_W))
	input = input.limit_length(1.0)
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized() * input.length()
	var jump := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_physical_key_pressed(KEY_SPACE)
	_mounted_horse.ride_step(delta, direction, Input.is_physical_key_pressed(KEY_SHIFT), jump)
	_sync_mounted_camera()


func _sync_mounted_camera() -> void:
	global_position = _mounted_horse.global_position
	_head.position.y = eye_height


func _dismount() -> void:
	var landing := _find_dismount_position()
	if not landing.is_finite():
		return
	var horse := _mounted_horse
	if horse.visual.has_method("clear_riding_pose"):
		horse.visual.call("clear_riding_pose", _model)
	_model.reparent(self, false)
	_model.position = Vector3.ZERO
	_model.rotation_degrees = Vector3(0, 180, 0)
	_model.scale = Vector3.ONE * float(_character["model_scale"])
	global_position = landing
	velocity = Vector3.ZERO
	_mounted_horse = null
	horse.rider = null
	horse.stop()
	eye_height = float(_character["eye_height"])
	third_person_distance = float(_character["third_person_distance"])
	_set_camera_mode(_foot_camera_mode)
	_collision_shape.set_deferred("disabled", false)
	collision_layer = 1
	collision_mask = 1 | 2


func _find_dismount_position() -> Vector3:
	var horse := _mounted_horse
	var terrain := get_tree().get_first_node_in_group("heightmap_terrain")
	if terrain == null:
		return Vector3.INF
	var side := horse.global_transform.basis.x
	var back := horse.global_transform.basis.z
	var offsets := [side * 2.0, -side * 2.0, back * 2.2, (side + back).normalized() * 2.2, (-side + back).normalized() * 2.2]
	var space := get_world_3d().direct_space_state
	for offset: Vector3 in offsets:
		var xz: Vector3 = horse.global_position + offset
		var from: Vector3 = Vector3(xz.x, horse.global_position.y + 3.0, xz.z)
		var to: Vector3 = from + Vector3.DOWN * 6.0
		var ray := PhysicsRayQueryParameters3D.create(from, to, 2)
		var ground := space.intersect_ray(ray)
		if ground.is_empty() or (ground["normal"] as Vector3).dot(Vector3.UP) < 0.75:
			continue
		var point := ground["position"] as Vector3
		if point.y < 0.05 or absf(point.y - horse.global_position.y) > 1.2:
			continue
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = _collision_shape.shape
		query.transform = Transform3D(Basis.IDENTITY, point + Vector3.UP * (0.5 * (_collision_shape.shape as CapsuleShape3D).height + 0.1))
		query.collision_mask = 1
		query.exclude = [get_rid(), horse.get_rid()]
		if space.intersect_shape(query, 1).is_empty():
			return point + Vector3.UP * 0.1
	return Vector3.INF

## The camera yaw drives the body, but the model turns to face where it is
## actually moving, so strafing and backpedalling read as a turn instead of
## sliding sideways in the forward-walk pose. Standing still eases the model
## back to face where the camera looks.
func _update_model_facing(delta: float) -> void:
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	# Models face +Z at identity; the body's forward is -Z.
	var target_yaw := rotation.y + PI
	if horiz.length() > 0.5:
		target_yaw = atan2(horiz.x, horiz.z)
	var current_yaw := rotation.y + _model.rotation.y
	var new_yaw := lerp_angle(current_yaw, target_yaw, clampf(model_turn_speed * delta, 0.0, 1.0))
	_model.rotation.y = new_yaw - rotation.y

func _update_camera(delta: float) -> void:
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var bob := 0.0
	if _camera_mode == CameraMode.FIRST_PERSON and is_on_floor() and horiz_speed > 0.5:
		_bob_t += delta * bob_frequency * horiz_speed
		bob = sin(_bob_t) * bob_amount * clampf(horiz_speed / walk_speed, 0.0, 1.5)
	_land_dip = move_toward(_land_dip, 0.0, delta * 0.6)
	var target_y := eye_height + bob - _land_dip
	_head.position.y = lerpf(_head.position.y, target_y, clampf(delta * 25.0, 0.0, 1.0))

func _update_animation() -> void:
	if _anim == null or not _model.visible:
		_bark_anim_pending = false
		_attack_anim_pending = false
		return
	if _attack_anim_pending:
		_attack_anim_pending = false
		var def: Dictionary = OnFootWeapons.DEFS[_weapon]
		_bark_anim_left = float(def["attack_hold"])
		_anim.play(def["attack_anim"], 0.05)
	# One-shot bark pose; hold it briefly before returning to locomotion.
	if _bark_anim_pending:
		_bark_anim_pending = false
		_bark_anim_left = 0.45
		_anim.play(_character["bark_anim"], 0.05)
	if _bark_anim_left > 0.0:
		return
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var anims: Dictionary = _character["anim"]
	var clip: String = anims["idle"]
	if not is_on_floor():
		clip = anims["jump"]
	elif horiz_speed > walk_speed + 0.5:
		clip = anims["run"]
	elif horiz_speed > 0.5:
		clip = anims["walk"]
	if _anim.current_animation != clip:
		_anim.play(clip, 0.15)
