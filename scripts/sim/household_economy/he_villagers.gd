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
## Behaviour: each villager follows HEVillagerSchedule -- indoors (hidden) at
## night, walking the roads to work in the morning and home in the evening,
## working (field, pasture and woodlot workers visible on their site, town
## workers hidden inside), loitering on the plaza, or playing in the yard. The
## schedule is a pure function of (villager, sim day, time of day), so this
## layer only evaluates it each frame (set_time / set_day come from the Town
## view's clock); it does not stop at a pause because time itself stops. Plans
## are rebuilt only when the roster, a house or a job changes, or the sim day
## ticks.
##
## Looks: male or female body (Casual_Male / Casual_Female) by the member's
## sex (HEHousehold.SEX_*, from the villager report); skin tone seeded per household so a family resembles itself;
## dependents under HEHousehold.AGING_THRESHOLD_DAYS are children, drawn at
## CHILD_SCALE.
##
## Cost (measured with perf_town_villagers.gd, 480 villagers): the
## AnimationPlayers were the biggest share of a frame, then drawing the skinned
## meshes, then their shadows. So: animations are advanced by hand, at most
## ANIM_UPDATES_PER_FRAME a frame, only for villagers on screen, and not at all
## once the camera is zoomed out past ANIM_MAX_ZOOM (they are a few pixels
## tall); villagers cast shadows only when GameState.villager_shadows is on
## (off by default); and every villager of one skin tone shares one skin
## material.

const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")
const HETownPaths = preload("res://scripts/sim/household_economy/he_town_paths.gd")
const HEVillagerSchedule = preload("res://scripts/sim/household_economy/he_villager_schedule.gd")

const MALE_MODEL := "res://assets/models/people/Casual_Male.fbx"
## Optional: used when present, otherwise everyone uses MALE_MODEL.
const FEMALE_MODEL := "res://assets/models/people/Casual_Female.fbx"
const IDLE_CLIP := "CharacterArmature|Idle"
const WALK_CLIP := "CharacterArmature|Walk"

## Adult height in world units (a house is 4.5 wide).
const ADULT_HEIGHT := 1.8
const CHILD_SCALE := 0.6
const TURN_RATE := 8.0
## Below this ground speed (units per second) a villager stands (idle clip);
## above the second, walks. Two thresholds so a wander's slow turns do not flicker.
const IDLE_BELOW_SPEED := 0.12
const WALK_ABOVE_SPEED := 0.22
## Plans rebuilt per frame after the sim day ticks (the rest keep yesterday's
## indoor pose, which is when everyone is inside anyway).
const REPLANS_PER_FRAME := 96
## Update cadence (frames) off screen; zoomed out, one frame per FAR_STRIDE_ZOOM
## of orthographic size, at most FAR_MAX_STRIDE.
const OFFSCREEN_STRIDE := 8
const FAR_STRIDE_ZOOM := 25.0
const FAR_MAX_STRIDE := 4

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
static var _shirt_materials: Dictionary = {} # Color -> StandardMaterial3D
## The two bodies share every material, so females get their own shirt colour
## (males keep the model's blue) to tell them apart at a distance.
const FEMALE_SHIRT := Color(0.72, 0.27, 0.33)

## While paused the layer does not process; it still jumps to where the
## schedule puts everyone when the time changes (or when it becomes paused).
var paused := false:
	set(value):
		paused = value
		if value and is_inside_tree():
			update_now()

var _villagers: Dictionary = {} # Vector2i(household_id, member_number) -> entry
var _anim_order: Array = [] # villager keys, the round-robin order
var _anim_cursor := 0
var _roster: Dictionary = {} # household_id -> villager report

var _shadows_on := false
var _layout: HETownLayout
var _paths: HETownPaths
var _day := 0
var _frame := 0
var _time := 0.25 ## time of day, 0..1
var _water_sites: Array = [] ## working water sources (site dictionaries), see sync()
var _water_sig := 0
var _hour := 6.0 ## on the schedule's hour line (HEVillagerSchedule.hour_of)

func _ready() -> void:
	_shadows_on = GameState.villager_shadows
	GameState.settings_changed.connect(_on_settings_changed)

func _on_settings_changed() -> void:
	if GameState.villager_shadows == _shadows_on:
		return
	_shadows_on = GameState.villager_shadows
	for mesh_node in find_children("*", "MeshInstance3D", true, false):
		(mesh_node as MeshInstance3D).cast_shadow = _shadow_mode()

func _shadow_mode() -> GeometryInstance3D.ShadowCastingSetting:
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _shadows_on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Rebuilds the roster from `reports` (get_villager_reports) and `layout`.
## Existing villagers keep their node; only new ones are added and departed
## ones removed, and a villager's plan is rebuilt only if its role, house or
## workplace changed.
func sync(layout: HETownLayout, reports: Array, water_sites: Array = []) -> void:
	if layout != _layout:
		_layout = layout
		_paths = HETownPaths.new(layout)
	var water_sig := 0
	for water in water_sites:
		water_sig = hash([water_sig, int(water["site_id"])]) & 0x7FFFFFFF
	if water_sig != _water_sig:
		_water_sig = water_sig
		_water_sites = water_sites
	_roster.clear()
	var wanted: Dictionary = {}
	var work_sites: Dictionary = {} # employer business id -> site, or {}
	for report in reports:
		var household_id := int(report["household_id"])
		_roster[household_id] = report
		var workers: PackedInt32Array = report["worker_ages"]
		var dependents: PackedInt32Array = report["dependent_ages"]
		var worker_sexes: PackedInt32Array = report["worker_sexes"]
		var dependent_sexes: PackedInt32Array = report["dependent_sexes"]
		var home := _home_site(layout, report)
		var employer := int(report["employer_business_id"])
		if not work_sites.has(employer):
			work_sites[employer] = _work_site(layout, employer)
		for i in workers.size() + dependents.size():
			var member_number := i + 1
			var is_worker := i < workers.size()
			var age: int = workers[i] if is_worker else dependents[i - workers.size()]
			var child := not is_worker and age < HEHousehold.AGING_THRESHOLD_DAYS
			var sex: int = worker_sexes[i] if is_worker else dependent_sexes[i - workers.size()]
			var role := HEVillagerSchedule.ROLE_CHILD if child else HEVillagerSchedule.ROLE_ADULT
			var work: Dictionary = {}
			if is_worker and employer != -1 and not (work_sites[employer] as Dictionary).is_empty():
				role = HEVillagerSchedule.ROLE_EMPLOYED
				work = work_sites[employer]
			var key := Vector2i(household_id, member_number)
			wanted[key] = true
			_place(key, role, child, sex == HEHousehold.SEX_FEMALE, home, work)
	for key in _villagers.keys():
		if not wanted.has(key):
			(_villagers[key]["node"] as Node3D).queue_free()
			_villagers.erase(key)
	_anim_order = _villagers.keys()
	_anim_cursor = 0

## The sim day (the schedule's per-day jitter and rosters follow it). Plans
## for the new day are built over the next frames.
func set_day(day: int) -> void:
	if day == _day:
		return
	_day = day
	if _is_idle():
		update_now()

## The Town view's clock (0 = midnight, 0.5 = noon).
func set_time(time_of_day: float) -> void:
	_time = fposmod(time_of_day, 1.0)
	_hour = HEVillagerSchedule.hour_of(_time)
	if _is_idle():
		update_now()

## Puts every villager where the schedule says it is now (used while the layer
## is not processing, and by checks).
func update_now() -> void:
	for key in _villagers:
		var entry: Dictionary = _villagers[key]
		if entry["plan_day"] != _day:
			_replan(entry)
		_update_entry(entry, 0.0)

func _is_idle() -> bool:
	return paused or process_mode == Node.PROCESS_MODE_DISABLED or not is_inside_tree()

func villager_count() -> int:
	return _villagers.size()

## Keys of every villager, for checks.
func villager_keys() -> Array:
	return _villagers.keys()

## The villager report of a household, or {}.
func household_report(household_id: int) -> Dictionary:
	return _roster.get(household_id, {})

## Ground position of a villager (the door while inside), or Vector3.INF.
func villager_position(key: Vector2i) -> Vector3:
	if not _villagers.has(key):
		return Vector3.INF
	return (_villagers[key]["node"] as Node3D).position

## Whether the villager is drawn (false while indoors).
func villager_visible(key: Vector2i) -> bool:
	return _villagers.has(key) and (_villagers[key]["node"] as Node3D).visible

## What the villager is doing now: {"visible", "activity", "site_id"} (see
## HEVillagerSchedule), or {} for an unknown villager.
func villager_activity(key: Vector2i) -> Dictionary:
	if not _villagers.has(key):
		return {}
	var seg: Dictionary = _villagers[key]["seg"]
	if seg.is_empty():
		return {}
	return {"visible": seg["type"] != "inside", "activity": seg["act"], "site_id": seg["site_id"]}

## The role a villager is playing today (HEVillagerSchedule.ROLE_*), or "".
func villager_role(key: Vector2i) -> String:
	return str(_villagers[key]["role"]) if _villagers.has(key) else ""

## The villager drawn nearest `screen_position` within PICK_RADIUS_PX, as
## Vector2i(household_id, member_number), or Vector2i(-1, -1). Villagers
## indoors are not drawn and cannot be picked.
func pick(camera: Camera3D, screen_position: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_dist := PICK_RADIUS_PX
	for key in _villagers:
		var entry: Dictionary = _villagers[key]
		var node := entry["node"] as Node3D
		if not node.visible:
			continue
		var chest := node.position + Vector3.UP * ADULT_HEIGHT * (CHILD_SCALE if entry["child"] else 1.0) * 0.55
		if camera.is_position_behind(chest):
			continue
		var d := camera.unproject_position(chest).distance_to(screen_position)
		if d < best_dist:
			best_dist = d
			best = key
	return best

# ---------------------------------------------------------------------------

## The household's house site, or {} when homeless (or the house is not built).
func _home_site(layout: HETownLayout, report: Dictionary) -> Dictionary:
	var dwelling_id := int(report["dwelling_id"])
	var site := layout.site_of_dwelling(dwelling_id) if dwelling_id != -1 else {}
	if site.is_empty() or not bool(site.get("built", false)):
		return {}
	return site

## The employer's site once it is open for work, else {}.
func _work_site(layout: HETownLayout, business_id: int) -> Dictionary:
	if business_id == -1:
		return {}
	var site := layout.site_of_business(business_id)
	if site.is_empty() or not bool(site.get("built", false)) or bool(site.get("under_construction", false)):
		return {}
	return site

func _place(key: Vector2i, role: String, child: bool, female: bool, home: Dictionary, work: Dictionary) -> void:
	var entry: Dictionary = _villagers.get(key, {})
	female = female and ResourceLoader.exists(FEMALE_MODEL)
	if not entry.is_empty() and (entry["child"] != child or entry["female"] != female):
		(entry["node"] as Node3D).queue_free()
		entry = {}
	var sig := Vector4i(HEVillagerSchedule.ROLES.find(role), int(home.get("site_id", -1)), int(work.get("site_id", -1)), _water_sig)
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
			"role": role,
			"home": home,
			"work": work,
			"sig": sig,
			"plan": {},
			"plan_day": -1,
			"seg": {},
			"seg_applied": {},
			"moving": false,
			"hide_t0": 0.0, # plan hours the villager is known to stay indoors (hide_t0 >= hide_t1: unknown)
			"hide_t1": 0.0,
			"dt": 0.0, # real seconds since the last update
			"phase": hash(key) & 7,
			"anim_debt": 0.0, # seconds of animation not yet advanced
		}
		_villagers[key] = entry
		node.rotation.y = rng.randf() * TAU
		_play(entry, IDLE_CLIP)
		# Manual mode: pose it now (never left in the rest pose, even while
		# zoomed out), at a random point of the clip so idles are not in step.
		if entry["anim"] != null:
			(entry["anim"] as AnimationPlayer).advance(rng.randf_range(0.0, 2.0))
		_replan(entry)
		_update_entry(entry, 0.0)
		return
	if entry["sig"] != sig:
		entry["role"] = role
		entry["home"] = home
		entry["work"] = work
		entry["sig"] = sig
		_replan(entry)
		_update_entry(entry, 0.0)

func _replan(entry: Dictionary) -> void:
	entry["plan"] = HEVillagerSchedule.plan(entry["key"], entry["role"], _day, entry["home"], entry["work"], _paths, _water_sites)
	entry["plan_day"] = _day
	entry["seg"] = {}
	entry["hide_t0"] = 0.0
	entry["hide_t1"] = 0.0

## HETownView disables this node's processing while hidden or paused.
##
## Cost control (the schedule is cheap, 480 of them each frame is not): villagers
## indoors are skipped until their segment ends; the rest are updated every
## frame while on screen and zoomed in, every few frames when zoomed far out
## (they are a few pixels tall), and every OFFSCREEN_STRIDE frames off screen.
## Updates are staggered by a per-villager phase and catch up on the time
## they skipped.
func _process(delta: float) -> void:
	if paused:
		return
	var step := minf(delta, 0.25)
	_frame += 1
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var stride := 1
	if camera != null and camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		stride = clampi(int(camera.size / FAR_STRIDE_ZOOM), 1, FAR_MAX_STRIDE)
	var replans := REPLANS_PER_FRAME
	for key in _villagers:
		var entry: Dictionary = _villagers[key]
		if entry["plan_day"] != _day and replans > 0:
			replans -= 1
			_replan(entry)
		if entry["plan_day"] == _day and _hour >= float(entry["hide_t0"]) and _hour < float(entry["hide_t1"]):
			continue # indoors until the segment ends
		var owed := float(entry["dt"]) + step
		var node := entry["node"] as Node3D
		var cadence := OFFSCREEN_STRIDE
		if camera == null or camera.is_position_in_frustum(node.position + Vector3.UP):
			cadence = stride
		if cadence > 1 and (_frame + int(entry["phase"])) % cadence != 0:
			entry["dt"] = owed
			continue
		entry["dt"] = 0.0
		_update_entry(entry, owed)
		if node.visible:
			entry["anim_debt"] = minf(float(entry["anim_debt"]) + owed, ANIM_MAX_CATCH_UP)
	_advance_animations()

## Moves one villager to where its plan puts it at the layer's current time.
## `delta` (seconds of real time since the last update, 0 for a jump) drives
## the facing and the walk/idle clip.
func _update_entry(entry: Dictionary, delta: float) -> void:
	var node := entry["node"] as Node3D
	var villager_plan: Dictionary = entry["plan"]
	var seg: Dictionary = entry["seg"]
	if seg.is_empty() or _hour >= float(seg["t1"]) or _hour < float(seg["t0"]):
		seg = HEVillagerSchedule.segment_at(villager_plan, _hour)
		entry["seg"] = seg
	if seg["type"] == "inside":
		if node.visible:
			node.visible = false
		if not is_same(entry["seg_applied"], seg):
			entry["seg_applied"] = seg
			var door: Vector2 = seg["pos"]
			node.position = Vector3(door.x, 0.0, door.y)
		entry["hide_t0"] = float(seg["t0"])
		entry["hide_t1"] = float(seg["t1"])
		return
	entry["hide_t0"] = 0.0
	entry["hide_t1"] = 0.0
	var pos := HEVillagerSchedule.position_of(seg, _hour)
	var next := Vector3(pos.x, 0.0, pos.y)
	var moved := next - node.position
	entry["seg_applied"] = seg
	if not node.visible:
		node.visible = true
		node.position = next
		return
	node.position = next
	if delta <= 0.0:
		return
	var distance := moved.length()
	if distance > 0.0001 and distance < 2.0:
		var yaw := atan2(moved.x, moved.z)
		node.rotation.y = lerp_angle(node.rotation.y, yaw, minf(1.0, TURN_RATE * delta))
	var speed := distance / delta
	if entry["moving"] and speed < IDLE_BELOW_SPEED:
		entry["moving"] = false
		_play(entry, IDLE_CLIP)
	elif not entry["moving"] and speed > WALK_ABOVE_SPEED and distance < 2.0:
		entry["moving"] = true
		_play(entry, WALK_CLIP)

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
		if not node.visible or not camera.is_position_in_frustum(node.position + Vector3.UP):
			continue
		(entry["anim"] as AnimationPlayer).advance(float(entry["anim_debt"]))
		entry["anim_debt"] = 0.0
		updated += 1
	_anim_cursor = (_anim_cursor + scanned) % count

func _play(entry: Dictionary, clip: String) -> void:
	var anim := entry["anim"] as AnimationPlayer
	if anim != null and anim.has_animation(clip) and anim.current_animation != clip:
		anim.play(clip, 0.2)

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
		mesh_node.cast_shadow = _shadow_mode()
		_apply_skin(mesh_node, tone)
		if female:
			_apply_shirt(mesh_node, FEMALE_SHIRT)
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

static func _apply_shirt(mesh_node: MeshInstance3D, color: Color) -> void:
	for i in mesh_node.mesh.get_surface_count():
		if mesh_node.mesh.surface_get_name(i) != "Shirt":
			continue
		if not _shirt_materials.has(color):
			var material := StandardMaterial3D.new()
			material.albedo_color = color
			_shirt_materials[color] = material
		mesh_node.set_surface_override_material(i, _shirt_materials[color])
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
