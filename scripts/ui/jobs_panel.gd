extends Panel

const ROWS := [
	{"label": "Gather Wood",  "type": "gather",  "arg": 0},
	{"label": "Gather Food",  "type": "gather",  "arg": 2},
	{"label": "Gather Gold",  "type": "gather",  "arg": 3},
	{"label": "Gather Stone", "type": "gather",  "arg": 1},
	{"label": "Build",        "type": "build",   "arg": -1},
	{"label": "Moving",       "type": "move",    "arg": -1},
	{"label": "Idle",         "type": "idle",    "arg": -1},
]

@onready var _vbox: VBoxContainer = $VBox

var _count_labels: Dictionary = {}
var _plus_btns: Dictionary = {}
var _minus_btns: Dictionary = {}
var _connected_jm: Node = null

func _ready() -> void:
	IslandsManager.active_island_changed.connect(_on_island_changed)
	_build_rows()
	_connect_island(IslandsManager.active_island)
	_refresh()

func _connect_island(island: Node) -> void:
	if _connected_jm != null and is_instance_valid(_connected_jm):
		_connected_jm.job_assigned.disconnect(_refresh)
		_connected_jm.job_completed.disconnect(_refresh)
		_connected_jm.job_cancelled.disconnect(_refresh)
		_connected_jm.assignments_changed.disconnect(_refresh)
	_connected_jm = null
	if island == null:
		return
	var jm: Node = island.jobs_manager
	jm.job_assigned.connect(_refresh)
	jm.job_completed.connect(_refresh)
	jm.job_cancelled.connect(_refresh)
	jm.assignments_changed.connect(_refresh)
	_connected_jm = jm

func _on_island_changed(island: Node) -> void:
	_connect_island(island)
	_refresh()

func _build_rows() -> void:
	var read_only := ["move", "idle"]
	for row in ROWS:
		var lbl: String = row["label"]
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 4)
		var name_lbl := Label.new()
		name_lbl.text = lbl
		name_lbl.custom_minimum_size.x = 90
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.add_theme_font_size_override("font_size", 11)
		var count_lbl := Label.new()
		count_lbl.text = "0"
		count_lbl.custom_minimum_size.x = 24
		count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		count_lbl.add_theme_font_size_override("font_size", 11)
		_count_labels[lbl] = count_lbl
		hbox.add_child(name_lbl)
		hbox.add_child(count_lbl)
		if not read_only.has(row["type"]):
			var minus := Button.new()
			minus.text = "-"
			minus.custom_minimum_size = Vector2(24, 24)
			minus.pressed.connect(_on_minus.bind(row))
			_minus_btns[lbl] = minus
			var plus := Button.new()
			plus.text = "+"
			plus.custom_minimum_size = Vector2(24, 24)
			plus.pressed.connect(_on_plus.bind(row))
			_plus_btns[lbl] = plus
			hbox.add_child(minus)
			hbox.add_child(plus)
		_vbox.add_child(hbox)

func _refresh(_a = null, _b = null) -> void:
	var jm: Node = IslandsManager.get_jobs_manager()
	var idle: int = jm.get_idle_count() if jm else 0
	for row in ROWS:
		var lbl: String = row["label"]
		var count: int = _get_count(row, jm)
		_count_labels[lbl].text = str(count)
		if _plus_btns.has(lbl):
			_plus_btns[lbl].disabled = (idle == 0)
		if _minus_btns.has(lbl):
			_minus_btns[lbl].disabled = (count == 0)

func _get_count(row: Dictionary, jm: Node) -> int:
	if jm == null:
		return 0
	match row["type"]:
		"gather":  return jm.get_gather_count(row["arg"])
		"build":   return jm.get_build_count()
		"deposit": return jm.get_deposit_count()
		"move":    return jm.get_move_count()
		"idle":    return jm.get_idle_count()
	return 0

func _on_plus(row: Dictionary) -> void:
	var jm: Node = IslandsManager.get_jobs_manager()
	if jm == null:
		return
	match row["type"]:
		"gather":  jm.increment_gather(row["arg"])
		"build":   jm.increment_build()
		"deposit": jm.increment_deposit()

func _on_minus(row: Dictionary) -> void:
	var jm: Node = IslandsManager.get_jobs_manager()
	if jm == null:
		return
	match row["type"]:
		"gather":  jm.decrement_gather(row["arg"])
		"build":   jm.decrement_build()
		"deposit": jm.decrement_deposit()
