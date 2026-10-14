extends Node3D

## The town's people, drawn as visual-only character models: one per household
## member, from HESimulation.get_villager_reports(). Owned by HETownView and fed
## through sync(); it owns no economy state and no positions the layout cares
## about.
##
## Identity: a villager is (household_id, member_number) -- member numbers are
## 1-based, workers first then dependents, the same numbering as the
## dashboard's household and person detail pages (HESimulation.
## get_person_summary). Members have no persistent ids, so when a member
## leaves, later members of that household shift down a number; their node is
## kept by key and simply re-dressed if its model kind changes.
##
## Behaviour (this slice): everyone mills about in the yard in front of their
## house -- the strip between its front wall and the road it faces. Homeless
## households, and towns that do not model housing, mill about at the edge of
## the civic plaza. No commuting yet. Movement is seeded per villager, in real
## time, and stops while the dashboard is paused.
##
## Looks: male or female body (Casual_Male / Casual_Female) seeded per
## villager; skin tone seeded per household so a family resembles itself;
## dependents under HEHousehold.AGING_THRESHOLD_DAYS are children, drawn at
## CHILD_SCALE.
##
## Cost (measured with perf_town_villagers.gd, 480 villagers): the
## AnimationPlayers were the biggest share of a frame, then drawing the skinned
## meshes, then their shadows. So: animations are advanced by hand, at most
## ANIM_UPDATES_PER_FRAME a frame, only for villagers on screen, and not at all
## once the camera is zoomed out past ANIM_MAX_ZOOM (they are a few pixels
## tall); villagers cast no shadows; and every villager of one skin tone shares
## one skin material.

const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

const MALE_MODEL := "res://assets/models/people/Casual_Male.fbx"
## Optional: used when present, otherwise everyone uses MALE_MODEL.
const FEMALE_MODEL := "res://assets/models/people/Casual_Female.fbx"
const IDLE_CLIP := "CharacterArmature|Idle"
const WALK_CLIP := "CharacterArmature|Walk"

## Adult height in world units (a house is 4.5 wide).
const ADULT_HEIGHT := 1.8
const CHILD_SCALE := 0.6
const WALK_SPEED := 1.1
const CHILD_WALK_SPEED := 1.4
const TURN_RATE := 8.0
## Seconds a villager stands before picking a new spot.
const IDLE_TIME := Vector2(1.5, 6.0)
## Yard: from this far in front of the house's front wall, this deep, and this
## far past each side wall.
const YARD_GAP := 0.4
const YARD_DEPTH := 1.8
const YARD_SIDE_OVERHANG := 1.0
## Plaza ring for the homeless, as distances from the civic anchor.
const PLAZA_RING := Vector2(8.5, 11.5)
## Candidate spots tried when picking where to stand next (see _free_spot).
const SPOT_TRIES := 4
## Screen-space pick radius in pixels, around the villager's chest.
const PICK_RADIUS_PX := 14.0
## Animation budget: AnimationPlayers advanced per frame (round robin over the
## villagers on screen; each catches up on the time it missed).
const ANIM_UPDATES_PER_FRAME := 64
## Orthographic camera size above which animations stop (pose held).
const ANIM_MAX_ZOOM := 50.0
## Most missed time one catch-up advances, so a villager coming back on screen
## does not jump through a long stretch of its clip.
const ANIM_MAX_CATCH_UP := 0.5

static var _scene_cache: Dictionary = {}
static var _skin_materials: Dictionary = {} # Color -> StandardMaterial3D

var paused := false

var _villagers: Dictionary = {} # Vector2i(household_id, member_number) -> entry
var _anim_order: Array = [] # villager keys, the round-robin order
var _anim_cursor := 0
var _roster: Dictionary = {} # household_id -> villager report

## Rebuilds the roster from `reports` (get_villager_reports) and `layout`.
## Existing villagers keep their node and position; only new ones are added
## and departed ones removed.
func sync(layout: HETownLayout, reports: Array) -> void:
	_roster.clear()
	var wanted: Dictionary = {}
	for report in reports:
		var household_id := int(report["household_id"])
		_roster[household_id] = report
		var workers: PackedInt32Array = report["worker_ages"]
		var dependents: PackedInt32Array = report["dependent_ages"]
		var yard := _yard_for(layout, report)
		for i in workers.size() + dependents.size():
			var member_number := i + 1
			var is_worker := i < workers.size()
			var age: int = workers[i] if is_worker else dependents[i - workers.size()]
			var child := not is_worker and age < HEHousehold.AGING_THRESHOLD_DAYS
			var key := Vector2i(household_id, member_number)
			wanted[key] = true
			_place(key, yard, child)
	for key in _villagers.keys():
		if not wanted.has(key):
			(_villagers[key]["node"] as Node3D).queue_free()
			_villagers.erase(key)
	_anim_order = _villagers.keys()
	_anim_cursor = 0

func villager_count() -> int:
	return _villagers.size()

## Keys of every villager, for checks.
func villager_keys() -> Array:
	return _villagers.keys()

## The villager report of a household, or {}.
func household_report(household_id: int) -> Dictionary:
	return _roster.get(household_id, {})

## Ground position of a villager, or Vector3.INF.
func villager_position(key: Vector2i) -> Vector3:
	if not _villagers.has(key):
		return Vector3.INF
	return (_villagers[key]["node"] as Node3D).position

## The villager drawn nearest `screen_position` within PICK_RADIUS_PX, as
## Vector2i(household_id, member_number), or Vector2i(-1, -1).
func pick(camera: Camera3D, screen_position: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist := PICK_RADIUS_PX
	for key in _villagers:
		var entry: Dictionary = _villagers[key]
		var node := entry["node"] as Node3D
		var chest := node.position + Vector3.UP * ADULT_HEIGHT * (CHILD_SCALE if entry["child"] else 1.0) * 0.55
		if camera.is_position_behind(chest):
			continue
		var d := camera.unproject_position(chest).distance_to(screen_position)
		if d < best_dist:
			best_dist = d
			best = key
	return best

# ---------------------------------------------------------------------------

## Where a household's members mill about: {"center", "front", "side",
## "half_width", "depth"} for a house yard, or {"plaza": true} for the plaza.
func _yard_for(layout: HETownLayout, report: Dictionary) -> Dictionary:
	var dwelling_id := int(report["dwelling_id"])
	var site := layout.site_of_dwelling(dwelling_id) if dwelling_id != -1 else {}
	if site.is_empty() or not bool(site.get("built", false)):
		return {"plaza": true}
	var position: Vector2 = site["position"]
	var half: Vector2 = (site["footprint"] as Vector2) * 0.5
	var access: Vector2 = site["access"]
	var front := Vector2.from_angle(float(site["rotation"])).orthogonal()
	if access.is_finite() and access.distance_to(position) > 0.01:
		front = (access - position).normalized()
	var side := front.orthogonal()
	return {
		"center": position + front * (half.y + YARD_GAP + YARD_DEPTH * 0.5),
		"front": front,
		"side": side,
		"half_width": half.x + YARD_SIDE_OVERHANG,
		"depth": YARD_DEPTH,
	}

func _place(key: Vector2i, yard: Dictionary, child: bool) -> void:
	var entry: Dictionary = _villagers.get(key, {})
	var female := _is_female(key)
	if not entry.is_empty() and (entry["child"] != child or entry["female"] != female):
		(entry["node"] as Node3D).queue_free()
		entry = {}
	if entry.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("villager|%d|%d" % [key.x, key.y])
		var node := _make_model(key, female, child)
		add_child(node)
		entry = {
			"node": node,
			"anim": node.find_child("AnimationPlayer", true, false) as AnimationPlayer,
			"child": child,
			"female": female,
			"key": key,
			"rng": rng,
			"yard": yard,
			"target": Vector3.INF,
			"wait": rng.randf_range(0.0, IDLE_TIME.y),
			"anim_debt": 0.0, # seconds of animation not yet advanced
		}
		node.position = _free_spot(key, yard, rng)
		_villagers[key] = entry
		node.rotation.y = rng.randf() * TAU
		_play(entry, IDLE_CLIP)
		# Manual mode: pose it now (never left in the rest pose, even while
		# zoomed out), at a random point of the clip so idles are not in step.
		if entry["anim"] != null:
			(entry["anim"] as AnimationPlayer).advance(rng.randf_range(0.0, 2.0))
		return
	if entry["yard"] != yard:
		# Moved house (or became homeless): walk over from wherever they are.
		entry["yard"] = yard
		entry["target"] = _free_spot(key, yard, entry["rng"])
		entry["wait"] = 0.0

## HETownView disables this node's processing while hidden or paused.
func _process(delta: float) -> void:
	if paused:
		return
	var step := minf(delta, 0.25)
	for key in _villagers:
		var entry: Dictionary = _villagers[key]
		_step(entry, step)
		entry["anim_debt"] = minf(float(entry["anim_debt"]) + step, ANIM_MAX_CATCH_UP)
	_advance_animations()

## Advances up to ANIM_UPDATES_PER_FRAME on-screen villagers' animations by the
## time each has missed, continuing round robin from where the last frame
## stopped. Nothing animates while zoomed out past ANIM_MAX_ZOOM.
func _advance_animations() -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null or _anim_order.is_empty():
		return
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL and camera.size > ANIM_MAX_ZOOM:
		return
	var updated := 0
	var count := _anim_order.size()
	var scanned := 0
	while scanned < count and updated < ANIM_UPDATES_PER_FRAME:
		var key = _anim_order[(_anim_cursor + scanned) % count]
		scanned += 1
		var entry: Dictionary = _villagers.get(key, {})
		if entry.is_empty() or entry["anim"] == null:
			continue
		var node := entry["node"] as Node3D
		if not camera.is_position_in_frustum(node.position + Vector3.UP):
			continue
		(entry["anim"] as AnimationPlayer).advance(float(entry["anim_debt"]))
		entry["anim_debt"] = 0.0
		updated += 1
	_anim_cursor = (_anim_cursor + scanned) % count

func _step(entry: Dictionary, delta: float) -> void:
	var node := entry["node"] as Node3D
	var target: Vector3 = entry["target"]
	if not target.is_finite():
		entry["wait"] = float(entry["wait"]) - delta
		if float(entry["wait"]) <= 0.0:
			entry["target"] = _free_spot(entry["key"], entry["yard"], entry["rng"])
			_play(entry, WALK_CLIP)
		return
	var to_target := target - node.position
	to_target.y = 0.0
	var speed := CHILD_WALK_SPEED if entry["child"] else WALK_SPEED
	var step := speed * delta
	if to_target.length() <= step:
		node.position = target
		entry["target"] = Vector3.INF
		entry["wait"] = (entry["rng"] as RandomNumberGenerator).randf_range(IDLE_TIME.x, IDLE_TIME.y)
		_play(entry, IDLE_CLIP)
		return
	var direction := to_target.normalized()
	node.position += direction * step
	var yaw := atan2(direction.x, direction.z)
	node.rotation.y = lerp_angle(node.rotation.y, yaw, minf(1.0, TURN_RATE * delta))
	if entry["anim"] != null and (entry["anim"] as AnimationPlayer).current_animation != WALK_CLIP:
		_play(entry, WALK_CLIP)

## A spot in `yard` for villager `key`: the best of SPOT_TRIES random spots,
## the one farthest from where its housemates stand or are heading, so a family
## spreads over the yard instead of piling up.
func _free_spot(key: Vector2i, yard: Dictionary, rng: RandomNumberGenerator) -> Vector3:
	var others: Array[Vector3] = []
	for other_key in _villagers:
		if other_key.x != key.x or other_key == key:
			continue
		var other: Dictionary = _villagers[other_key]
		var target: Vector3 = other["target"]
		others.append(target if target.is_finite() else (other["node"] as Node3D).position)
	var best := _random_spot(yard, rng)
	if others.is_empty():
		return best
	var best_gap := _nearest(best, others)
	for i in SPOT_TRIES - 1:
		var spot := _random_spot(yard, rng)
		var gap := _nearest(spot, others)
		if gap > best_gap:
			best = spot
			best_gap = gap
	return best

static func _nearest(spot: Vector3, others: Array[Vector3]) -> float:
	var nearest := INF
	for other in others:
		nearest = minf(nearest, spot.distance_squared_to(other))
	return nearest

func _random_spot(yard: Dictionary, rng: RandomNumberGenerator) -> Vector3:
	var spot: Vector2
	if yard.get("plaza", false):
		spot = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(PLAZA_RING.x, PLAZA_RING.y)
	else:
		spot = (yard["center"] as Vector2) \
			+ (yard["side"] as Vector2) * rng.randf_range(-float(yard["half_width"]), float(yard["half_width"])) \
			+ (yard["front"] as Vector2) * rng.randf_range(-float(yard["depth"]) * 0.5, float(yard["depth"]) * 0.5)
	return Vector3(spot.x, 0.0, spot.y)

func _play(entry: Dictionary, clip: String) -> void:
	var anim := entry["anim"] as AnimationPlayer
	if anim != null and anim.has_animation(clip) and anim.current_animation != clip:
		anim.play(clip, 0.2)

static func _is_female(key: Vector2i) -> bool:
	if not ResourceLoader.exists(FEMALE_MODEL):
		return false
	return hash("body|%d|%d" % [key.x, key.y]) % 2 == 1

## A model scaled to ADULT_HEIGHT (times CHILD_SCALE), skin toned per
## household, standing on y = 0 and facing local +Z.
func _make_model(key: Vector2i, female: bool, child: bool) -> Node3D:
	var path := FEMALE_MODEL if female else MALE_MODEL
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path)
	var holder := Node3D.new()
	holder.name = "Villager_%d_%d" % [key.x, key.y]
	var model := (_scene_cache[path] as PackedScene).instantiate() as Node3D
	holder.add_child(model)
	var tone_rng := RandomNumberGenerator.new()
	tone_rng.seed = hash("skin|%d" % key.x)
	var tone := _pick_tone(tone_rng)
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_apply_skin(mesh_node, tone)
	var anim := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim != null:
		# Advanced by hand in _advance_animations, under a per-frame budget.
		anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for clip in [IDLE_CLIP, WALK_CLIP]:
			if anim.has_animation(clip):
				anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	var height := _model_height(model)
	var factor := ADULT_HEIGHT / maxf(height, 0.001) * (CHILD_SCALE if child else 1.0)
	model.scale = Vector3.ONE * factor
	return holder

## Like SkinTones.apply, but every villager of one tone shares one material.
static func _apply_skin(mesh_node: MeshInstance3D, tone: Color) -> void:
	for i in mesh_node.mesh.get_surface_count():
		if mesh_node.mesh.surface_get_name(i) != "Skin":
			continue
		if not _skin_materials.has(tone):
			var material := StandardMaterial3D.new()
			material.albedo_color = tone
			_skin_materials[tone] = material
		mesh_node.set_surface_override_material(i, _skin_materials[tone])
		return

## SkinTones' weighted tones, picked with a seeded rng instead of the global one.
static func _pick_tone(rng: RandomNumberGenerator) -> Color:
	var roll := rng.randf() * 100.0
	var acc := 0.0
	for entry in SkinTones.TONES:
		acc += float(entry["weight"])
		if roll < acc:
			return entry["color"]
	return SkinTones.TONES[-1]["color"]

## Unscaled height of a freshly instanced model's meshes (rest pose bounds).
static func _model_height(model: Node3D) -> float:
	var top := -INF
	var bottom := INF
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		var box: AABB = mesh_node.transform * mesh_node.get_aabb()
		var parent := mesh_node.get_parent()
		while parent != null and parent != model:
			if parent is Node3D:
				box = (parent as Node3D).transform * box
			parent = parent.get_parent()
		top = maxf(top, box.end.y)
		bottom = minf(bottom, box.position.y)
	return top - bottom if top > bottom else ADULT_HEIGHT
