extends Node3D

## The town's herds, drawn as visual-only animal models: one per head of each
## Cattle Ranch / Sheep Farm (capped), grazing in that business's pasture.
## Owned by HETownView and fed through sync(); it owns no economy state. The
## head count shown comes from the business report's herd_size, so the view
## follows the simulation but never changes it.
##
## Movement reuses the on-foot sheep's flocking (Jadhav et al. 2024,
## docs/sheep-flocking-plan.md, OnFootSheep): each animal repels close mates,
## is attracted to a few random near ones, aligns to one of those, and carries
## its previous heading, plus noise re-rolled about once a second. There is no
## dog here (herding is a later step), so the only other drive is the
## graze/wander alternation OnFootSheep uses when calm. Cattle use the same
## rules at a slower pace.
##
## Animals live in each pasture's local frame (the same rotation as the site's
## body) and stay inside its grazing rectangle, which excludes the barn end.

const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

const SPECIES := {
	"Sheep": {"model": "res://assets/models/animals/Sheep.fbx", "length": 1.3, "speed": 1.2, "cap": 40, "rep": 1.5},
	"Cattle": {"model": "res://assets/models/animals/Cow.fbx", "length": 2.4, "speed": 0.9, "cap": 24, "rep": 2.6},
}
## Same weights as OnFootSheep's Flocking group.
const FLOCK_K := 10
const FLOCK_N_ATT := 5
const FLOCK_N_ALI := 1
const W_REP := 2.0
const W_ATT := 1.5
const W_ALI := 1.3
const W_INERTIA := 1.0
const NOISE_STRENGTH := 0.5
const RESAMPLE_INTERVAL := 1.0
const TURN_RATE := 6.0
const ACCEL := 14.0
## Pasture margin kept clear of animals, and the barn end (barn + door yard).
const EDGE_MARGIN := 1.5
const BARN_END := 10.5
const EDGE_PUSH_BAND := 3.0
## Herds past this camera size are a few pixels each: stop steering them.
const MAX_ZOOM := 140.0

static var _scene_cache: Dictionary = {}
static var _scale_cache: Dictionary = {} # species -> uniform scale

var paused := false

var _herds: Dictionary = {} # site_id -> herd entry
var _camera: Camera3D
var _rng := RandomNumberGenerator.new()

class Animal extends RefCounted:
	var node: Node3D
	var model: Node3D
	var pos := Vector2.ZERO
	var vel := Vector2.ZERO
	var heading := Vector2.ZERO
	var noise := Vector2.ZERO
	var grazing := true
	var state_left := 0.0
	var wander_dir := Vector2.ZERO
	var resample_left := 0.0
	var att: Array = []
	var ali: Array = []
	var bob := 0.0

func _init() -> void:
	_rng.seed = 424242

func set_camera(camera: Camera3D) -> void:
	_camera = camera

## Rebuilds the drawn herds from `layout` and the business `reports`. A herd's
## animals keep their nodes and positions; only the count changes.
func sync(layout: HETownLayout, reports: Array) -> void:
	var by_business: Dictionary = {}
	for report in reports:
		if report.has("herd_size"):
			by_business[int(report["business_id"])] = report
	var wanted: Dictionary = {}
	for site in layout.get_sites():
		if not site["built"] or site["under_construction"]:
			continue
		var business_id: int = site["business_id"]
		if business_id == HETownLayout.NO_BUSINESS or not by_business.has(business_id):
			continue
		var report: Dictionary = by_business[business_id]
		var species := str(report["species"])
		if not SPECIES.has(species):
			continue
		wanted[int(site["site_id"])] = true
		_sync_herd(site, species, int(round(float(report["herd_size"]))))
	for site_id in _herds.keys():
		if not wanted.has(site_id):
			(_herds[site_id]["root"] as Node3D).queue_free()
			_herds.erase(site_id)

func herd_count() -> int:
	return _herds.size()

## Animals drawn for the herd on `site_id` (0 when none).
func animal_count(site_id: int) -> int:
	return (_herds[site_id]["animals"] as Array).size() if _herds.has(site_id) else 0

func total_animals() -> int:
	var total := 0
	for site_id in _herds:
		total += (_herds[site_id]["animals"] as Array).size()
	return total

## Local positions of a herd's animals, for checks.
func animal_positions(site_id: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _herds.has(site_id):
		for animal in _herds[site_id]["animals"]:
			out.append((animal as Animal).pos)
	return out

## The grazing rectangle (local x/z) of a pasture footprint.
static func graze_rect(footprint: Vector2) -> Rect2:
	var left := -footprint.x * 0.5 + BARN_END
	var right := footprint.x * 0.5 - EDGE_MARGIN
	var top := -footprint.y * 0.5 + EDGE_MARGIN
	var bottom := footprint.y * 0.5 - EDGE_MARGIN
	return Rect2(left, top, maxf(right - left, 1.0), maxf(bottom - top, 1.0))

# ---------------------------------------------------------------------------
# Herds
# ---------------------------------------------------------------------------

func _sync_herd(site: Dictionary, species: String, head: int) -> void:
	var site_id: int = site["site_id"]
	var spec: Dictionary = SPECIES[species]
	var count := clampi(head, 0, int(spec["cap"]))
	var entry: Dictionary = _herds.get(site_id, {})
	if not entry.is_empty() and entry["species"] != species:
		(entry["root"] as Node3D).queue_free()
		entry = {}
	if entry.is_empty():
		var root := Node3D.new()
		root.name = "Herd%d" % site_id
		add_child(root)
		entry = {"root": root, "species": species, "animals": [], "rect": Rect2()}
		_herds[site_id] = entry
	var root_node := entry["root"] as Node3D
	var position: Vector2 = site["position"]
	root_node.position = Vector3(position.x, 0.0, position.y)
	root_node.rotation.y = -float(site["rotation"])
	var rect := graze_rect(site["footprint"])
	entry["rect"] = rect
	var animals: Array = entry["animals"]
	while animals.size() > count:
		var gone: Animal = animals.pop_back()
		gone.node.queue_free()
	while animals.size() < count:
		animals.append(_spawn(root_node, species, rect))

func _spawn(root: Node3D, species: String, rect: Rect2) -> Animal:
	var spec: Dictionary = SPECIES[species]
	var animal := Animal.new()
	var holder := Node3D.new()
	var path: String = spec["model"]
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path)
	var model := (_scene_cache[path] as PackedScene).instantiate() as Node3D
	# Quaternius models face +Z; the holder's yaw drives -Z (as OnFootSheep does).
	model.rotation_degrees = Vector3(0, 180, 0)
	holder.add_child(model)
	root.add_child(holder)
	if not _scale_cache.has(species):
		_scale_cache[species] = _fit_scale(model, float(spec["length"]))
	model.scale = Vector3.ONE * float(_scale_cache[species])
	var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if GameState.villager_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for mesh_node in model.find_children("*", "MeshInstance3D", true, false):
		(mesh_node as MeshInstance3D).cast_shadow = shadow
	animal.node = holder
	animal.model = model
	animal.pos = Vector2(
		_rng.randf_range(rect.position.x, rect.end.x),
		_rng.randf_range(rect.position.y, rect.end.y))
	animal.state_left = _rng.randf_range(0.5, 4.0)
	animal.resample_left = _rng.randf()
	animal.bob = _rng.randf() * TAU
	holder.rotation.y = _rng.randf() * TAU
	holder.position = Vector3(animal.pos.x, 0.0, animal.pos.y)
	return animal

## Uniform scale that makes the model's longest ground axis `length` units.
func _fit_scale(model: Node3D, length: float) -> float:
	var bounds := AABB()
	var first := true
	var to_local := model.global_transform.affine_inverse()
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		var box: AABB = (to_local * mesh_node.global_transform) * mesh_node.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		return 1.0
	return length / maxf(maxf(bounds.size.x, bounds.size.z), 0.001)

# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if paused or _herds.is_empty():
		return
	if _camera != null and _camera.size > MAX_ZOOM:
		return
	delta = minf(delta, 0.1)
	for site_id in _herds:
		var entry: Dictionary = _herds[site_id]
		_step_herd(entry["animals"], entry["rect"], SPECIES[entry["species"]], delta)

func _step_herd(animals: Array, rect: Rect2, spec: Dictionary, delta: float) -> void:
	var speed: float = spec["speed"]
	var rep_distance: float = spec["rep"]
	for animal: Animal in animals:
		animal.resample_left -= delta
		if animal.resample_left <= 0.0:
			_resample(animal, animals)
		var desired := Vector2.ZERO
		var move_speed := speed
		animal.state_left -= delta
		if animal.state_left <= 0.0:
			animal.grazing = not animal.grazing
			animal.state_left = _rng.randf_range(2.0, 5.0) if animal.grazing else _rng.randf_range(1.5, 3.5)
			animal.wander_dir = _wander_dir(animal, rect)
		if animal.grazing:
			move_speed = 0.0
		else:
			var steer := animal.wander_dir
			steer += _separation(animal, animals, rep_distance) * W_REP
			steer += _attraction(animal) * W_ATT + _alignment(animal) * W_ALI
			steer += animal.heading * W_INERTIA + animal.noise * NOISE_STRENGTH
			steer += _edge_push(animal.pos, rect) * 3.0
			desired = steer.normalized() if steer.length() > 0.001 else animal.wander_dir
			animal.heading = desired
		if animal.grazing:
			animal.heading = Vector2.ZERO
		animal.vel = animal.vel.move_toward(desired * move_speed, ACCEL * delta)
		animal.pos += animal.vel * delta
		animal.pos = Vector2(
			clampf(animal.pos.x, rect.position.x, rect.end.x),
			clampf(animal.pos.y, rect.position.y, rect.end.y))
		_pose(animal, delta)

func _pose(animal: Animal, delta: float) -> void:
	var node := animal.node
	node.position = Vector3(animal.pos.x, 0.0, animal.pos.y)
	var moving := animal.vel.length()
	if moving > 0.2:
		node.rotation.y = lerp_angle(node.rotation.y, atan2(-animal.vel.x, -animal.vel.y), clampf(delta * TURN_RATE, 0.0, 1.0))
		# The models ship few clips, so fake a walk with a bob and sway.
		animal.bob += delta * moving * 6.0
		animal.model.position.y = absf(sin(animal.bob)) * 0.05
		animal.model.rotation.z = sin(animal.bob) * 0.04
	else:
		animal.model.position.y = move_toward(animal.model.position.y, 0.0, delta)
		animal.model.rotation.z = move_toward(animal.model.rotation.z, 0.0, delta)

func _resample(animal: Animal, animals: Array) -> void:
	animal.resample_left = RESAMPLE_INTERVAL * _rng.randf_range(0.75, 1.25)
	animal.noise = Vector2.from_angle(_rng.randf() * TAU) * _rng.randf()
	var near: Array = []
	for other: Animal in animals:
		if other != animal:
			near.append([animal.pos.distance_squared_to(other.pos), other])
	near.sort_custom(func(a, b): return a[0] < b[0])
	var pool: Array = []
	for i in mini(FLOCK_K, near.size()):
		pool.append(near[i][1])
	pool.shuffle()
	animal.att = pool.slice(0, FLOCK_N_ATT)
	animal.ali = animal.att.slice(0, FLOCK_N_ALI)

func _separation(animal: Animal, animals: Array, rep_distance: float) -> Vector2:
	var push := Vector2.ZERO
	for other: Animal in animals:
		if other == animal:
			continue
		var off := animal.pos - other.pos
		var d := off.length()
		if d > 0.01 and d < rep_distance:
			push += off / d * (rep_distance - d) / rep_distance
	return push

func _attraction(animal: Animal) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for other: Animal in animal.att:
		sum += other.pos - animal.pos
		n += 1
	if n == 0:
		return Vector2.ZERO
	sum /= n
	return sum.normalized() if sum.length() > 0.01 else Vector2.ZERO

func _alignment(animal: Animal) -> Vector2:
	var sum := Vector2.ZERO
	for other: Animal in animal.ali:
		if other.vel.length() > 0.2:
			sum += other.vel.normalized()
	return sum.normalized() if sum.length() > 0.01 else Vector2.ZERO

## Gentle wander that drifts back toward nearby mates, as OnFootSheep does.
func _wander_dir(animal: Animal, rect: Rect2) -> Vector2:
	var dir := Vector2.from_angle(_rng.randf() * TAU)
	var to_mates := _attraction(animal)
	if to_mates != Vector2.ZERO:
		dir = (dir + to_mates * 1.5).normalized()
	var out := (dir + _edge_push(animal.pos, rect) * 2.0)
	return out.normalized() if out.length() > 0.001 else dir

func _edge_push(pos: Vector2, rect: Rect2) -> Vector2:
	var push := Vector2.ZERO
	if pos.x < rect.position.x + EDGE_PUSH_BAND:
		push.x = 1.0
	elif pos.x > rect.end.x - EDGE_PUSH_BAND:
		push.x = -1.0
	if pos.y < rect.position.y + EDGE_PUSH_BAND:
		push.y = 1.0
	elif pos.y > rect.end.y - EDGE_PUSH_BAND:
		push.y = -1.0
	return push
