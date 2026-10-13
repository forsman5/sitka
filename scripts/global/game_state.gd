extends Node

signal gold_changed(amount: int)
signal wood_changed(amount: int)
signal food_changed(amount: int)
signal settings_changed

const SETTINGS_PATH := "user://settings.cfg"
const MAX_SPARKLINE_DAYS := 700
const MAX_BLOTTER_DAYS := 730
## Real seconds per day in the household economy's Town view.
const TOWN_DAY_SECONDS_OPTIONS: Array[float] = [120.0, 60.0]

## Days of history every sparkline/chart shows (the sim retains up to 730).
var sparkline_days: int = 360
## Days of events the household-economy blotter shows.
var blotter_days: int = 365
## How long one day lasts in the household Town view (one of
## TOWN_DAY_SECONDS_OPTIONS). 120 matches the RTS day/night cycle.
var town_day_seconds: float = 120.0
## Dev mode shows the household-economy dashboard's free "Create business"
## menu. Turn it off to force new buildings through the Government build menu.
var dev_mode: bool = true

@export var gather_speed: float = 1.3
@export var game_speed: float = 1.0
@export var pause_on_escape: bool = true
@export var settler_cost: int = 30
@export var forest_hut_cost: int = 50
@export var house_cost: int = 40
@export var dock_cost: int = 60
@export var barn_cost: int = 60
@export var ship_cost: int = 50
@export var cow_cost: int = 40
@export var sheep_cost: int = 30
var time_of_day: float = 0.25
var pending_load: Dictionary = {}
var current_save_name: String = ""
var day_count: int = 1
@export var show_day_counter: bool = false
@export var show_next_cow_btn: bool = false

var _economy_relay: IslandEconomy = null

func _ready() -> void:
	_load_settings()
	IslandsManager.active_island_changed.connect(_relay_economy)

func _relay_economy(island: Node) -> void:
	if _economy_relay:
		_economy_relay.gold_changed.disconnect(gold_changed.emit)
		_economy_relay.wood_changed.disconnect(wood_changed.emit)
		_economy_relay.food_changed.disconnect(food_changed.emit)
	_economy_relay = island.economy if island else null
	if _economy_relay:
		_economy_relay.gold_changed.connect(gold_changed.emit)
		_economy_relay.wood_changed.connect(wood_changed.emit)
		_economy_relay.food_changed.connect(food_changed.emit)
		gold_changed.emit(_economy_relay.gold)
		wood_changed.emit(_economy_relay.wood)
		food_changed.emit(_economy_relay.food)

var player_gold: int:
	get: return _economy_relay.gold if _economy_relay else 0
	set(v):
		if _economy_relay:
			_economy_relay.gold = v
		else:
			gold_changed.emit(v)

var player_wood: int:
	get: return _economy_relay.wood if _economy_relay else 0
	set(v):
		if _economy_relay:
			_economy_relay.wood = v
		else:
			wood_changed.emit(v)

var player_food: int:
	get: return _economy_relay.food if _economy_relay else 0
	set(v):
		if _economy_relay:
			_economy_relay.food = v
		else:
			food_changed.emit(v)

func reset() -> void:
	if _economy_relay:
		_economy_relay.reset()
	game_speed = 1.0
	time_of_day = 0.25
	current_save_name = ""
	day_count = 1

func set_history_settings(new_sparkline_days: int, new_blotter_days: int) -> void:
	sparkline_days = clampi(new_sparkline_days, 1, MAX_SPARKLINE_DAYS)
	blotter_days = clampi(new_blotter_days, 1, MAX_BLOTTER_DAYS)
	_save_settings()
	settings_changed.emit()

func set_town_day_seconds(seconds: float) -> void:
	if not TOWN_DAY_SECONDS_OPTIONS.has(seconds) or town_day_seconds == seconds:
		return
	town_day_seconds = seconds
	_save_settings()
	settings_changed.emit()

func set_dev_mode(enabled: bool) -> void:
	if dev_mode == enabled:
		return
	dev_mode = enabled
	_save_settings()
	settings_changed.emit()

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("history", "sparkline_days", sparkline_days)
	cfg.set_value("history", "blotter_days", blotter_days)
	cfg.set_value("dev", "dev_mode", dev_mode)
	cfg.set_value("town", "day_seconds", town_day_seconds)
	cfg.save(SETTINGS_PATH)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	sparkline_days = clampi(int(cfg.get_value("history", "sparkline_days", sparkline_days)), 1, MAX_SPARKLINE_DAYS)
	blotter_days = clampi(int(cfg.get_value("history", "blotter_days", blotter_days)), 1, MAX_BLOTTER_DAYS)
	dev_mode = bool(cfg.get_value("dev", "dev_mode", dev_mode))
	var saved_day_seconds := float(cfg.get_value("town", "day_seconds", town_day_seconds))
	if TOWN_DAY_SECONDS_OPTIONS.has(saved_day_seconds):
		town_day_seconds = saved_day_seconds
