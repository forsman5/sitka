extends Node3D
## First-person view of the main RTS island: the same heightmap terrain (default
## MapConfig, so the same island), forest and berry-bush managers, and day/night
## cycle -- minus the RTS-only machinery (capital placement, selection, nav baking).

## Must load first: resource nodes reference Island, and Island preloads resource
## scenes, so the script load order has to start from Island, as in the RTS world.
const _ISLAND_SCRIPT := preload("res://scripts/world/world.gd")
const TERRAIN_SCENE := preload("res://scenes/world/heightmap_terrain.tscn")
const FOREST_MANAGER := preload("res://scripts/world/forest_manager.gd")
const BUSH_MANAGER := preload("res://scripts/world/bush_manager.gd")
const DAY_NIGHT_CYCLE := preload("res://scripts/world/day_night_cycle.gd")

## Established forest / bushes at start; the managers keep spawning more over time.
const INITIAL_TREES := 60
const INITIAL_BUSH_CLUSTERS := 12
## Each day is a dusk challenge: start at 6:30pm with the sun setting and get the
## flock penned before night falls at 9pm. The cycle is sped up so that stretch
## lasts DUSK_SECONDS of real time.
const START_TIME_OF_DAY := 18.5 / 24.0
const NIGHT_TIME := 21.0 / 24.0
const DUSK_SECONDS := 120.0

## Esc often releases mouse capture itself (browser pointer lock, embedded game
## window) before the game sees a key press, so a lost capture also opens the menu.
const ESC_DEBOUNCE_MSEC := 250

# [time, sky_top, horizon] -- same time keys as day_night_cycle.gd.
const _SKY_KEYS := [
	[0.00, Color(0.01, 0.01, 0.05), Color(0.04, 0.05, 0.12)],
	[0.25, Color(0.30, 0.38, 0.62), Color(0.95, 0.60, 0.38)],
	[0.50, Color(0.28, 0.52, 0.88), Color(0.68, 0.80, 0.92)],
	[0.75, Color(0.30, 0.30, 0.55), Color(0.95, 0.50, 0.25)],
	[1.00, Color(0.01, 0.01, 0.05), Color(0.04, 0.05, 0.12)],
]

var _pen: SheepPen
var _pause_layer: CanvasLayer
var _auto_paused_at: int = -ESC_DEBOUNCE_MSEC
var _terrain: Node
var _sky_mat: ProceduralSkyMaterial
var _clock: Label

func _ready() -> void:
	GameState.time_of_day = START_TIME_OF_DAY
	_build_environment()
	_build_island()

	var spawn := _ground_point(Vector2.ZERO)
	var player := OnFootPlayer.new()
	player.name = "Player"
	player.spawn_point = spawn + Vector3(0, 0.5, 0)
	player.position = player.spawn_point
	add_child(player)

	_spawn_companion(spawn)
	_spawn_pen()
	_spawn_flock()

	var hint := Label.new()
	hint.text = "WASD move · Shift sprint · Space jump · F5 camera view · Esc menu"
	if OnFootPlayer.selected_character == "dog":
		hint.text = "Left click bark · " + hint.text
	hint.position = Vector2(12, 8)
	var layer := CanvasLayer.new()
	layer.add_child(hint)
	add_child(layer)
	_build_pause_menu()

	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", 28)
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock.anchor_left = 1.0
	_clock.anchor_right = 1.0
	_clock.offset_left = -260.0
	_clock.offset_right = -16.0
	_clock.offset_top = 44.0
	layer.add_child(_clock)

	var points := Label.new()
	points.text = "Points: 0"
	points.add_theme_font_size_override("font_size", 28)
	points.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	points.anchor_left = 1.0
	points.anchor_right = 1.0
	points.offset_left = -260.0
	points.offset_right = -16.0
	points.offset_top = 8.0
	layer.add_child(points)
	_pen.sheep_penned.connect(func(total: int) -> void: points.text = "Points: %d" % total)

func _process(_delta: float) -> void:
	_update_sky(GameState.time_of_day)
	_update_clock(GameState.time_of_day)
	if not get_tree().paused and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_auto_paused_at = Time.get_ticks_msec()
		_set_paused(true)

func _build_pause_menu() -> void:
	_pause_layer = CanvasLayer.new()
	_pause_layer.layer = 20
	_pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_layer.visible = false
	add_child(_pause_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_layer.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(220, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)

	var resume := Button.new()
	resume.text = "Resume"
	resume.pressed.connect(_set_paused.bind(false))
	box.add_child(resume)

	var quit := Button.new()
	quit.text = "Main Menu"
	quit.pressed.connect(_to_main_menu)
	box.add_child(quit)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		# The same Esc press may already have opened the menu via lost capture.
		if Time.get_ticks_msec() - _auto_paused_at < ESC_DEBOUNCE_MSEC:
			return
		_set_paused(not get_tree().paused)

func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	_pause_layer.visible = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED

func _to_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

## Terrain-height point under an XZ position.
func _ground_point(xz: Vector2) -> Vector3:
	return Vector3(xz.x, _terrain.get_height(xz.x, xz.y), xz.y)

func _build_island() -> void:
	_terrain = TERRAIN_SCENE.instantiate()
	add_child(_terrain)  # Generates the island from the default MapConfig in _ready.

	var water := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(3000, 3000)
	water.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.38, 0.65)
	mat.roughness = 0.05
	water.material_override = mat
	water.name = "WaterPlane"
	add_child(water)

	_build_shore_barrier()

	# Same managers the RTS island runs: trees in the western forest, berry
	# bush clusters spreading across the west of the island. They add their
	# resource nodes as children of this node and keep spawning over time.
	var forest := Node.new()
	forest.name = "ForestManager"
	forest.set_script(FOREST_MANAGER)
	add_child(forest)
	var bushes := Node.new()
	bushes.name = "BushManager"
	bushes.set_script(BUSH_MANAGER)
	add_child(bushes)
	forest.prewarm(INITIAL_TREES)
	bushes.prewarm(INITIAL_BUSH_CLUSTERS)

## Invisible wall ring at the waterline so nobody wades out to the edge of the
## terrain collider and falls off the world.
func _build_shore_barrier() -> void:
	var cfg: MapConfig = _terrain.map_config
	var radius := cfg.island_radius - cfg.shore_width * 0.5
	var segments := 36
	var seg_len := TAU * radius / segments + 0.6
	var body := StaticBody3D.new()
	body.name = "ShoreBarrier"
	add_child(body)
	for i in segments:
		var a := TAU * i / segments
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(seg_len, 10.0, 1.0)
		col.shape = box
		col.position = Vector3(cos(a) * radius, 2.0, sin(a) * radius)
		col.rotation.y = -(a + PI * 0.5)
		body.add_child(col)

## The character you aren't playing: a standing human beside the dog, or the dog
## at heel (left rear) when you're the person.
func _spawn_companion(spawn: Vector3) -> void:
	var as_dog := OnFootPlayer.selected_character == "dog"
	var companion := OnFootCompanion.new()
	companion.name = "Companion"
	companion.setup(as_dog, OnFootCompanion.Mode.STAND if as_dog else OnFootCompanion.Mode.HEEL)
	var offset := Vector3(1.5, 0, 0) if as_dog else OnFootCompanion.HEEL_OFFSET
	var xz := Vector2(spawn.x + offset.x, spawn.z + offset.z)
	companion.position = _ground_point(xz) + Vector3(0, 0.3, 0)
	add_child(companion)

## Open-gated pen on the flat ground east of the town, gate facing the spawn.
func _spawn_pen() -> void:
	_pen = SheepPen.new()
	_pen.name = "SheepPen"
	_pen.position = _ground_point(Vector2(18, -2))
	_pen.rotation_degrees.y = -90.0
	add_child(_pen)

## A small flock a short walk from the spawn point.
func _spawn_flock() -> void:
	var center := Vector2(8, 14)
	for i in randi_range(3, 5):
		var sheep := OnFootSheep.new()
		var xz := center + Vector2(randf_range(-3, 3), randf_range(-3, 3))
		sheep.position = _ground_point(xz) + Vector3(0, 0.3, 0)
		sheep.rotation.y = randf() * TAU
		add_child(sheep)

## Light and ambient come from the RTS DayNightCycle (it needs siblings named
## DirectionalLight3D and WorldEnvironment). Its flat grey sky colours are meant
## for a top-down view, so the sky here is a real procedural sky that follows the
## same time of day.
func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "DirectionalLight3D"
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)

	_sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.75, 0.85)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var cycle := Node.new()
	cycle.name = "DayNightCycle"
	cycle.set_script(DAY_NIGHT_CYCLE)
	cycle.seconds_per_day = DUSK_SECONDS / (NIGHT_TIME - START_TIME_OF_DAY)
	add_child(cycle)

func _update_clock(t: float) -> void:
	var minutes := int(t * 24.0 * 60.0)
	_clock.text = "%02d:%02d" % [floori(minutes / 60.0), minutes % 60]

func _update_sky(t: float) -> void:
	var a: Array = _SKY_KEYS[0]
	var b: Array = _SKY_KEYS[1]
	for i in range(_SKY_KEYS.size() - 1):
		if t >= _SKY_KEYS[i][0] and t <= _SKY_KEYS[i + 1][0]:
			a = _SKY_KEYS[i]
			b = _SKY_KEYS[i + 1]
			break
	var span: float = b[0] - a[0]
	var f: float = (t - a[0]) / span if span > 0.0 else 0.0
	var top: Color = (a[1] as Color).lerp(b[1], f)
	var horizon: Color = (a[2] as Color).lerp(b[2], f)
	_sky_mat.sky_top_color = top
	_sky_mat.sky_horizon_color = horizon
	_sky_mat.ground_horizon_color = horizon
	_sky_mat.ground_bottom_color = top * 0.4
