extends Control

## H1 equivalent of scripts/sim/dashboard.gd: a live, speed-controllable
## read-out of HESimulation. This is a view only -- it holds one
## HESimulation instance, advances it by calling advance_ticks(), and
## re-renders from HESimulation's read-only query methods. It never reaches
## into HESimulation's internal Dictionaries directly, and holds no
## economic rules of its own.

const EscapeMenu = preload("res://scripts/ui/escape_menu.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HESparkline = preload("res://scripts/sim/household_economy/he_sparkline.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 4242
const SECONDS_PER_DAY_AT_1X := 1.0
const WAGE_TOOLTIP := "A business paying above the reference wage grows (green); one paying below shrinks (red)."
## Filters always rescan this complete simulated-time window. The view is
## scrollable, so no separate event-count cap can hide an enabled category.
const BLOTTER_HISTORY_DAYS := 30
const BUSINESS_STATUS_COLUMN_WIDTH := 430.0
const TRADER_TRANSACTION_HISTORY_DAYS := 30
const BUSINESS_EMPLOYMENT_VISIBLE_EVENTS := 50
const BLOTTER_FILTERS := [
	{"type": "birth", "label": "Births"},
	{"type": "emigrate", "label": "Starvation emigration"},
	{"type": "old_age", "label": "Old-age deaths"},
	{"type": "adopted", "label": "Adoptions"},
	{"type": "split", "label": "Household founding"},
	{"type": "coming_of_age", "label": "Coming of age"},
	{"type": "job", "label": "Hiring"},
	{"type": "fired", "label": "Firing / layoffs"},
]

const SCENARIOS := [
	{"label": "Five businesses, evenly staffed", "builder": "build_three_business_economy"},
	{"label": "Five businesses, lopsided start", "builder": "build_lopsided_start"},
	{"label": "Six businesses, with Bloomery", "builder": "build_three_business_economy_with_bloomery"},
	{"label": "Seven businesses, with Bloomery and Iron Mine", "builder": "build_economy_with_bloomery_and_iron_mine"},
]

var _simulation: HESimulation
var _speed_multiplier: float = 1.0
var _day_accumulator: float = 0.0

var _day_label: Label
var _city_stats_label: Label
var _market_grid: GridContainer
var _market_labels: Dictionary = {} # commodity_name -> {"price","offered","funded","traded"}
var _known_market_commodities: Array = [] # rebuild trigger -- see _refresh()
var _business_list: VBoxContainer
var _business_rows: Dictionary = {} # business_id -> {row labels...}
var _household_list: VBoxContainer
var _household_rows: Dictionary = {} # household_id -> {row labels...}
var _known_household_ids: Array[int] = [] # rebuild trigger -- see _refresh()
var _business_names: Dictionary = {} # business_id -> name, for the household table's Employer column
var _blotter_display: RichTextLabel
var _blotter_column: VBoxContainer
var _blotter_toggle_button: Button
var _blotter_filter_button: MenuButton
var _blotter_filter_enabled: Dictionary = {}
var _blotter_minimized: bool = false

## -1 means no business is selected -- the household list fills the
## content_area on its own. Any other value is a business_id whose detail
## panel is stacked on top of (drawn after, in the same anchored area as)
## the household list -- see _build_ui()'s content_area.
var _selected_business_id: int = -1
var _business_detail_panel: PanelContainer
var _business_detail_title: Label
var _business_detail_overview_scroll: ScrollContainer
var _trader_settings_scroll: ScrollContainer
var _trader_settings_list: VBoxContainer
var _trader_settings_button: Button
var _trader_settings_open: bool = false
var _business_detail_sparkline: HESparkline
var _business_detail_production_section: VBoxContainer
var _business_detail_production_legend: HBoxContainer
var _business_detail_production_chart: HESparkline
var _business_detail_grid: GridContainer
var _business_detail_cull_target_box: SpinBox
var _business_detail_cull_target_hint: Label
## Which business the cull-target box was last loaded for. The box is only
## (re)loaded when the selection changes -- the detail view refreshes every
## tick, and rewriting the box then would clobber whatever's being typed.
var _cull_target_loaded_for: int = -1
var _business_detail_herd_events_section: VBoxContainer
var _business_detail_herd_events_display: RichTextLabel
var _business_detail_transaction_section: VBoxContainer
var _business_detail_transaction_grid: GridContainer
var _business_detail_transaction_empty: Label
var _trader_transaction_filter := "both"
var _business_detail_employment_grid: GridContainer
var _business_detail_employment_empty: Label
var _business_employment_filter := "both"
var _business_detail_employee_grid: GridContainer
var _selected_market_commodity: int = -1
var _market_detail_panel: PanelContainer
var _market_detail_title: Label
var _market_detail_content: VBoxContainer
var _selected_household_id: int = -1
var _household_detail_panel: PanelContainer
var _household_detail_title: Label
var _household_detail_content: VBoxContainer

func _ready() -> void:
	# The valley hosting an embedded view has its own menu. get() because
	# embedded_mode only exists once the valley integration lands.
	if not get("embedded_mode"):
		EscapeMenu.attach_to(self)
	for filter in BLOTTER_FILTERS:
		_blotter_filter_enabled[filter["type"]] = true
	_configure_tooltip_theme()
	_load_scenario(0)
	_build_ui()
	_refresh()

func _configure_tooltip_theme() -> void:
	var tooltip_theme := Theme.new()
	var tooltip_panel := StyleBoxFlat.new()
	tooltip_panel.bg_color = Color(0.025, 0.025, 0.04, 0.98)
	tooltip_panel.border_width_left = 1
	tooltip_panel.border_width_top = 1
	tooltip_panel.border_width_right = 1
	tooltip_panel.border_width_bottom = 1
	tooltip_panel.border_color = Color(0.32, 0.32, 0.42, 1.0)
	tooltip_panel.corner_radius_top_left = 4
	tooltip_panel.corner_radius_top_right = 4
	tooltip_panel.corner_radius_bottom_left = 4
	tooltip_panel.corner_radius_bottom_right = 4
	tooltip_panel.content_margin_left = 10.0
	tooltip_panel.content_margin_top = 7.0
	tooltip_panel.content_margin_right = 10.0
	tooltip_panel.content_margin_bottom = 7.0
	tooltip_theme.set_stylebox("panel", "TooltipPanel", tooltip_panel)
	tooltip_theme.set_color("font_color", "TooltipLabel", Color(0.92, 0.92, 0.96))
	theme = tooltip_theme

func _process(delta: float) -> void:
	if _simulation == null or _speed_multiplier <= 0.0:
		return
	_day_accumulator += minf(delta, 0.25) * _speed_multiplier / SECONDS_PER_DAY_AT_1X
	_day_accumulator = minf(_day_accumulator, 8.0) # bound interactive work, same as dashboard.gd
	var days_to_advance := mini(int(_day_accumulator), 4)
	if days_to_advance <= 0:
		return
	for i in range(days_to_advance):
		_simulation.advance_ticks(1)
		_day_accumulator -= 1.0
	_refresh()

func _load_scenario(index: int) -> void:
	var scenario: Dictionary = SCENARIOS[index]
	_simulation = HESimulation.new(SEED, Callable(HEScenarioSeeds, scenario["builder"]))
	_business_names.clear()
	for report in _simulation.get_business_reports():
		_business_names[report["business_id"]] = report["name"]
	_day_accumulator = 0.0
	# A business_id selected in the PREVIOUS scenario has no meaning here --
	# guarded null check because this runs once before _build_ui() ever
	# creates the panel (see _ready()).
	_selected_business_id = -1
	_trader_settings_open = false
	if _business_detail_panel != null:
		_business_detail_panel.visible = false
	_selected_market_commodity = -1
	if _market_detail_panel != null:
		_market_detail_panel.visible = false
	_selected_household_id = -1
	if _household_detail_panel != null:
		_household_detail_panel.visible = false

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 8)
	vbox.add_child(top_bar)

	_day_label = Label.new()
	_day_label.add_theme_font_size_override("font_size", 22)
	top_bar.add_child(_day_label)

	var scenario_picker := OptionButton.new()
	for scenario in SCENARIOS:
		scenario_picker.add_item(scenario["label"])
	scenario_picker.item_selected.connect(func(index: int) -> void:
		_load_scenario(index)
		_rebuild_business_rows()
		_rebuild_household_rows()
		_refresh())
	top_bar.add_child(scenario_picker)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	top_bar.add_child(_make_speed_button("Pause", 0.0))
	top_bar.add_child(_make_speed_button("1x", 1.0))
	top_bar.add_child(_make_speed_button("10x", 10.0))
	top_bar.add_child(_make_speed_button("100x", 100.0))

	_city_stats_label = Label.new()
	_city_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_city_stats_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	vbox.add_child(_city_stats_label)

	# Businesses and Goods share one fixed-height tabbed area. Stacked, the
	# business list grew with every new business and crowded out the
	# households/detail row below; each tab scrolls internally instead.
	var top_tabs := TabContainer.new()
	top_tabs.custom_minimum_size = Vector2(0, 200)
	vbox.add_child(top_tabs)

	var business_scroll := ScrollContainer.new()
	business_scroll.name = "Businesses"
	# Scrolls both axes: the business table is wider than the window AND
	# grows taller with every business. Wheel = vertical, Shift+wheel =
	# horizontal. Also stops the wide grid from stretching the whole page.
	business_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	business_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	top_tabs.add_child(business_scroll)
	_business_list = VBoxContainer.new()
	business_scroll.add_child(_business_list)

	var goods_scroll := ScrollContainer.new()
	goods_scroll.name = "Goods"
	goods_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	top_tabs.add_child(goods_scroll)
	_market_grid = GridContainer.new()
	_market_grid.columns = 5
	_market_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	goods_scroll.add_child(_market_grid)
	_rebuild_market_grid()
	_known_market_commodities = _simulation.get_market_summary().keys()

	var lower_row := HBoxContainer.new()
	lower_row.add_theme_constant_override("separation", 16)
	lower_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(lower_row)

	var household_column := VBoxContainer.new()
	household_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	household_column.size_flags_stretch_ratio = 2.0
	lower_row.add_child(household_column)

	var household_header := Label.new()
	household_header.text = "Households"
	household_header.add_theme_font_size_override("font_size", 16)
	household_column.add_child(household_header)

	# Plain Control, not another box container -- both children below are
	# anchored to fill it completely, so whichever one is .visible occupies
	# the WHOLE area rather than the two sharing it top-to-bottom. That's
	# what makes the business detail panel read as a window stacked on top
	# of the household list (added second, so it draws over it) instead of
	# squeezed in beside it.
	var content_area := Control.new()
	content_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	household_column.add_child(content_area)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	content_area.add_child(scroll)

	_household_list = VBoxContainer.new()
	_household_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_household_list)

	_business_detail_panel = PanelContainer.new()
	_business_detail_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_business_detail_panel.visible = false
	# The default theme's panel style is translucent enough that the
	# household list underneath shows through and muddies the text -- this
	# needs to read as a solid window stacked ON TOP, not a tinted overlay.
	var detail_panel_style := StyleBoxFlat.new()
	detail_panel_style.bg_color = Color(0.08, 0.08, 0.11, 1.0)
	detail_panel_style.border_width_left = 1
	detail_panel_style.border_width_top = 1
	detail_panel_style.border_width_right = 1
	detail_panel_style.border_width_bottom = 1
	detail_panel_style.border_color = Color(0.32, 0.32, 0.42, 1.0)
	detail_panel_style.content_margin_left = 10.0
	detail_panel_style.content_margin_top = 8.0
	detail_panel_style.content_margin_right = 10.0
	detail_panel_style.content_margin_bottom = 8.0
	_business_detail_panel.add_theme_stylebox_override("panel", detail_panel_style)
	content_area.add_child(_business_detail_panel)

	var detail_vbox := VBoxContainer.new()
	_business_detail_panel.add_child(detail_vbox)

	var detail_title_bar := HBoxContainer.new()
	detail_vbox.add_child(detail_title_bar)

	_business_detail_title = Label.new()
	_business_detail_title.add_theme_font_size_override("font_size", 16)
	detail_title_bar.add_child(_business_detail_title)

	var detail_title_spacer := Control.new()
	detail_title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_title_bar.add_child(detail_title_spacer)
	_trader_settings_button = Button.new()
	_trader_settings_button.text = "Export settings"
	_trader_settings_button.visible = false
	_trader_settings_button.pressed.connect(_on_trader_settings_pressed)
	detail_title_bar.add_child(_trader_settings_button)

	var detail_close_button := Button.new()
	detail_close_button.text = "X"
	detail_close_button.tooltip_text = "Close (back to household list)"
	detail_close_button.pressed.connect(_on_business_detail_close_pressed)
	detail_title_bar.add_child(detail_close_button)

	_business_detail_overview_scroll = ScrollContainer.new()
	_business_detail_overview_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_vbox.add_child(_business_detail_overview_scroll)

	# Everything below scrolls together as one column -- the sparkline, the
	# key/value facts, and the employee list -- rather than each getting its
	# own independent scroll region.
	var detail_content := VBoxContainer.new()
	detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_business_detail_overview_scroll.add_child(detail_content)

	var cash_history_label := Label.new()
	cash_history_label.text = "Cash (last %d days)" % HEBusiness.BALANCE_HISTORY_WINDOW_DAYS
	cash_history_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	detail_content.add_child(cash_history_label)

	_business_detail_sparkline = HESparkline.new()
	_business_detail_sparkline.custom_minimum_size = Vector2(0, 60)
	detail_content.add_child(_business_detail_sparkline)

	_business_detail_production_section = VBoxContainer.new()
	detail_content.add_child(_business_detail_production_section)

	var production_header := HBoxContainer.new()
	production_header.add_theme_constant_override("separation", 12)
	_business_detail_production_section.add_child(production_header)
	var production_history_label := Label.new()
	production_history_label.text = "Goods produced per day (last %d days)" % HEBusiness.BALANCE_HISTORY_WINDOW_DAYS
	production_history_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	production_header.add_child(production_history_label)
	_business_detail_production_legend = HBoxContainer.new()
	_business_detail_production_legend.add_theme_constant_override("separation", 12)
	production_header.add_child(_business_detail_production_legend)

	_business_detail_production_chart = HESparkline.new()
	_business_detail_production_chart.custom_minimum_size = Vector2(0, 60)
	_business_detail_production_chart.show_max_label = true
	_business_detail_production_section.add_child(_business_detail_production_chart)

	_business_detail_grid = GridContainer.new()
	_business_detail_grid.columns = 2
	detail_content.add_child(_business_detail_grid)

	_business_detail_transaction_section = VBoxContainer.new()
	detail_content.add_child(_business_detail_transaction_section)

	var transaction_header := HBoxContainer.new()
	_business_detail_transaction_section.add_child(transaction_header)
	var transaction_title := Label.new()
	transaction_title.text = "Transactions (last %d days)" % TRADER_TRANSACTION_HISTORY_DAYS
	transaction_title.add_theme_font_size_override("font_size", 14)
	transaction_header.add_child(transaction_title)
	var transaction_spacer := Control.new()
	transaction_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	transaction_header.add_child(transaction_spacer)
	var transaction_filter_group := ButtonGroup.new()
	for filter in ["both", "import", "export"]:
		var filter_button := Button.new()
		filter_button.text = filter.capitalize() + ("s" if filter != "both" else "")
		filter_button.toggle_mode = true
		filter_button.button_group = transaction_filter_group
		filter_button.button_pressed = filter == _trader_transaction_filter
		filter_button.pressed.connect(_on_trader_transaction_filter_pressed.bind(filter))
		transaction_header.add_child(filter_button)

	_business_detail_transaction_empty = Label.new()
	_business_detail_transaction_empty.text = "No matching transactions in the last %d days." % TRADER_TRANSACTION_HISTORY_DAYS
	_business_detail_transaction_empty.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_business_detail_transaction_section.add_child(_business_detail_transaction_empty)

	_business_detail_transaction_grid = GridContainer.new()
	_business_detail_transaction_grid.columns = 5
	_business_detail_transaction_section.add_child(_business_detail_transaction_grid)

	# Built once, shown for whichever herd business is selected (Cattle Ranch
	# and Sheep Farm both) -- lines come from _format_event, same as the blotter.
	_business_detail_herd_events_section = VBoxContainer.new()
	detail_content.add_child(_business_detail_herd_events_section)
	var cull_target_row := HBoxContainer.new()
	_business_detail_herd_events_section.add_child(cull_target_row)
	var cull_target_label := Label.new()
	cull_target_label.text = "Cull target (head)"
	cull_target_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	cull_target_label.tooltip_text = "The herd size this ranch culls back down to every review. Culled animals are exported; a bigger target needs more staff to look after it."
	cull_target_row.add_child(cull_target_label)
	_business_detail_cull_target_box = SpinBox.new()
	_business_detail_cull_target_box.step = 5.0
	_business_detail_cull_target_box.custom_minimum_size = Vector2(110, 0)
	_business_detail_cull_target_box.value_changed.connect(_on_cull_target_changed)
	cull_target_row.add_child(_business_detail_cull_target_box)
	# Sheep only (hidden for cattle): what flock the settlement's wool demand
	# would actually support. Plain label, refreshed every tick -- unlike the
	# box above it, nothing to clobber.
	_business_detail_cull_target_hint = Label.new()
	_business_detail_cull_target_hint.add_theme_font_size_override("font_size", 12)
	_business_detail_cull_target_hint.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_business_detail_cull_target_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_business_detail_herd_events_section.add_child(_business_detail_cull_target_hint)
	var herd_events_title := Label.new()
	herd_events_title.text = "Herd events (births, culls, hardship sales)"
	herd_events_title.add_theme_font_size_override("font_size", 14)
	_business_detail_herd_events_section.add_child(herd_events_title)
	_business_detail_herd_events_display = RichTextLabel.new()
	_business_detail_herd_events_display.bbcode_enabled = true
	_business_detail_herd_events_display.fit_content = true
	_business_detail_herd_events_display.scroll_active = false
	_business_detail_herd_events_section.add_child(_business_detail_herd_events_display)

	var employment_section := VBoxContainer.new()
	detail_content.add_child(employment_section)
	var employment_header := HBoxContainer.new()
	employment_section.add_child(employment_header)
	var employment_title := Label.new()
	employment_title.text = "Employment blotter (latest %d)" % BUSINESS_EMPLOYMENT_VISIBLE_EVENTS
	employment_title.add_theme_font_size_override("font_size", 14)
	employment_header.add_child(employment_title)
	var employment_spacer := Control.new()
	employment_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	employment_header.add_child(employment_spacer)
	var employment_filter_group := ButtonGroup.new()
	for filter in ["both", "job", "fired"]:
		var filter_button := Button.new()
		filter_button.text = {"both": "Both", "job": "Hires", "fired": "Firings"}[filter]
		filter_button.toggle_mode = true
		filter_button.button_group = employment_filter_group
		filter_button.button_pressed = filter == _business_employment_filter
		filter_button.pressed.connect(_on_business_employment_filter_pressed.bind(filter))
		employment_header.add_child(filter_button)
	_business_detail_employment_empty = Label.new()
	_business_detail_employment_empty.text = "No employment events recorded for this business yet."
	_business_detail_employment_empty.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	employment_section.add_child(_business_detail_employment_empty)
	_business_detail_employment_grid = GridContainer.new()
	_business_detail_employment_grid.columns = 5
	employment_section.add_child(_business_detail_employment_grid)

	var employees_label := Label.new()
	employees_label.text = "Employees"
	employees_label.add_theme_font_size_override("font_size", 14)
	detail_content.add_child(employees_label)

	_business_detail_employee_grid = GridContainer.new()
	_business_detail_employee_grid.columns = 5
	detail_content.add_child(_business_detail_employee_grid)
	_trader_settings_scroll = ScrollContainer.new()
	_trader_settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_trader_settings_scroll.visible = false
	detail_vbox.add_child(_trader_settings_scroll)
	_trader_settings_list = VBoxContainer.new()
	_trader_settings_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trader_settings_list.add_theme_constant_override("separation", 8)
	_trader_settings_scroll.add_child(_trader_settings_list)

	_market_detail_panel = PanelContainer.new()
	_market_detail_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_market_detail_panel.add_theme_stylebox_override("panel", detail_panel_style.duplicate())
	_market_detail_panel.visible = false
	content_area.add_child(_market_detail_panel)
	var market_detail_box := VBoxContainer.new()
	_market_detail_panel.add_child(market_detail_box)
	var market_title_bar := HBoxContainer.new()
	market_detail_box.add_child(market_title_bar)
	_market_detail_title = Label.new()
	_market_detail_title.add_theme_font_size_override("font_size", 16)
	market_title_bar.add_child(_market_detail_title)
	var market_title_spacer := Control.new()
	market_title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	market_title_bar.add_child(market_title_spacer)
	var market_close := Button.new()
	market_close.text = "X"
	market_close.tooltip_text = "Close (back to household list)"
	market_close.pressed.connect(_on_market_detail_close_pressed)
	market_title_bar.add_child(market_close)
	var market_scroll := ScrollContainer.new()
	market_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	market_detail_box.add_child(market_scroll)
	_market_detail_content = VBoxContainer.new()
	_market_detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_market_detail_content.add_theme_constant_override("separation", 6)
	market_scroll.add_child(_market_detail_content)

	_household_detail_panel = PanelContainer.new()
	_household_detail_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_household_detail_panel.add_theme_stylebox_override("panel", detail_panel_style.duplicate())
	_household_detail_panel.visible = false
	content_area.add_child(_household_detail_panel)
	var household_detail_box := VBoxContainer.new()
	_household_detail_panel.add_child(household_detail_box)
	var household_title_bar := HBoxContainer.new()
	household_detail_box.add_child(household_title_bar)
	_household_detail_title = Label.new()
	_household_detail_title.add_theme_font_size_override("font_size", 16)
	household_title_bar.add_child(_household_detail_title)
	var household_title_spacer := Control.new()
	household_title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	household_title_bar.add_child(household_title_spacer)
	var household_close := Button.new()
	household_close.text = "X"
	household_close.tooltip_text = "Close (back to household list)"
	household_close.pressed.connect(_on_household_detail_close_pressed)
	household_title_bar.add_child(household_close)
	var household_scroll := ScrollContainer.new()
	household_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	household_detail_box.add_child(household_scroll)
	_household_detail_content = VBoxContainer.new()
	_household_detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_household_detail_content.add_theme_constant_override("separation", 6)
	household_scroll.add_child(_household_detail_content)

	_blotter_column = VBoxContainer.new()
	lower_row.add_child(_blotter_column)

	var blotter_header := HBoxContainer.new()
	_blotter_column.add_child(blotter_header)

	# Doubles as the header label AND the minimize/restore control -- see
	# _set_blotter_minimized() -- rather than a separate label plus button,
	# since a minimized blotter has almost no width to spare for both.
	_blotter_toggle_button = Button.new()
	_blotter_toggle_button.flat = true
	_blotter_toggle_button.add_theme_font_size_override("font_size", 16)
	_blotter_toggle_button.pressed.connect(_on_blotter_toggle_pressed)
	blotter_header.add_child(_blotter_toggle_button)

	_blotter_filter_button = MenuButton.new()
	_blotter_filter_button.text = "Filters"
	_blotter_filter_button.tooltip_text = "Choose which notification types appear in the blotter"
	var blotter_filter_popup := _blotter_filter_button.get_popup()
	for i in BLOTTER_FILTERS.size():
		blotter_filter_popup.add_check_item(BLOTTER_FILTERS[i]["label"], i)
		blotter_filter_popup.set_item_checked(blotter_filter_popup.get_item_index(i), true)
	blotter_filter_popup.id_pressed.connect(_on_blotter_filter_pressed)
	blotter_header.add_child(_blotter_filter_button)

	_blotter_display = RichTextLabel.new()
	_blotter_display.bbcode_enabled = true
	_blotter_display.scroll_following = false
	_blotter_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_blotter_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blotter_column.add_child(_blotter_display)
	_set_blotter_minimized(false)

	_rebuild_business_rows()
	_rebuild_household_rows()

func _make_speed_button(label: String, speed: float) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.pressed.connect(func() -> void: _speed_multiplier = speed)
	return btn

func _on_blotter_toggle_pressed() -> void:
	_set_blotter_minimized(not _blotter_minimized)

func _on_blotter_filter_pressed(id: int) -> void:
	var event_type: String = BLOTTER_FILTERS[id]["type"]
	var enabled: bool = not _blotter_filter_enabled[event_type]
	_blotter_filter_enabled[event_type] = enabled
	var popup := _blotter_filter_button.get_popup()
	popup.set_item_checked(popup.get_item_index(id), enabled)
	_refresh_blotter()

## Minimized: the blotter shrinks to a thin strip docked at the right edge
## (SIZE_SHRINK_END so it hugs that edge rather than floating wherever its
## small minimum size happens to land) instead of sharing lower_row's width
## with the household/business-detail column -- that column's own
## SIZE_EXPAND_FILL then claims all the space this one gives up
## automatically, no stretch-ratio bookkeeping needed on either side.
func _set_blotter_minimized(minimized: bool) -> void:
	_blotter_minimized = minimized
	_blotter_display.visible = not minimized
	_blotter_filter_button.visible = not minimized
	if minimized:
		_blotter_toggle_button.text = "◂"
		_blotter_toggle_button.tooltip_text = "Restore the blotter"
		_blotter_column.custom_minimum_size = Vector2(32, 0)
		_blotter_column.size_flags_horizontal = Control.SIZE_SHRINK_END
	else:
		_blotter_toggle_button.text = "Blotter (%dd) ▸" % BLOTTER_HISTORY_DAYS
		_blotter_toggle_button.tooltip_text = "Minimize the blotter"
		_blotter_column.custom_minimum_size = Vector2(0, 0)
		_blotter_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_blotter_column.size_flags_stretch_ratio = 1.0

func _on_household_row_selected(household_id: int) -> void:
	_selected_business_id = -1
	_business_detail_panel.visible = false
	_selected_market_commodity = -1
	_market_detail_panel.visible = false
	_selected_household_id = household_id
	_household_detail_panel.visible = true
	_refresh_household_detail()

func _on_household_detail_close_pressed() -> void:
	_selected_household_id = -1
	_household_detail_panel.visible = false

## Rebuilt every refresh; the content is a handful of lines, so there's no
## fixed schema worth updating in place.
func _refresh_household_detail() -> void:
	if _selected_household_id == -1:
		return
	if not _simulation.get_household_ids().has(_selected_household_id):
		# The household died or the scenario reloaded.
		_selected_household_id = -1
		_household_detail_panel.visible = false
		return
	var h := _simulation.get_household_summary(_selected_household_id)
	_household_detail_title.text = "Household %d" % _selected_household_id
	for child in _household_detail_content.get_children():
		_household_detail_content.remove_child(child)
		child.queue_free()

	_add_household_detail_heading("Inventory")
	var inventory: Dictionary = h["inventory"]
	for commodity_name in inventory.keys():
		_add_household_detail_line("%s: %.1f" % [commodity_name, inventory[commodity_name]])

	# One line per household need, straight from the sim's HENeeds -- no list
	# of its own. Amounts are in the need's units; the goods that met it (heat
	# from timber AND charcoal, say) are nested under it rather than each
	# being listed as a separate requirement.
	_add_household_detail_heading("Needs (today)")
	for need in h["needs"]:
		_add_household_detail_line("%s: needs %.2f, met %.2f" % [need["label"], need["required"], need["provided"]])
		for satisfier in need["satisfiers"]:
			if satisfier["consumed"] > 0.0001:
				_add_household_detail_line("    %s used: %.2f" % [satisfier["name"], satisfier["consumed"]])

func _add_household_detail_heading(value: String) -> void:
	var heading := Label.new()
	heading.text = value
	heading.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_household_detail_content.add_child(heading)

func _add_household_detail_line(value: String) -> void:
	var label := Label.new()
	label.text = value
	_household_detail_content.add_child(label)

func _on_business_row_selected(business_id: int) -> void:
	_selected_market_commodity = -1
	_market_detail_panel.visible = false
	_selected_household_id = -1
	_household_detail_panel.visible = false
	_selected_business_id = business_id
	_cull_target_loaded_for = -1
	_trader_settings_open = false
	_business_detail_panel.visible = true
	_refresh_business_detail()

func _on_cull_target_changed(value: float) -> void:
	if _selected_business_id == -1:
		return
	var applied := _simulation.set_herd_cull_target(_selected_business_id, value)
	if applied >= 0.0:
		# Reflect any clamping back into the box without re-triggering this.
		_business_detail_cull_target_box.set_value_no_signal(applied)
		_refresh_business_detail()

func _on_business_detail_close_pressed() -> void:
	_selected_business_id = -1
	_business_detail_panel.visible = false

func _on_trader_settings_pressed() -> void:
	_trader_settings_open = not _trader_settings_open
	if _trader_settings_open:
		_rebuild_trader_settings()
	_update_trader_detail_page()

func _update_trader_detail_page() -> void:
	_business_detail_overview_scroll.visible = not _trader_settings_open
	_trader_settings_scroll.visible = _trader_settings_open
	_trader_settings_button.text = "Overview" if _trader_settings_open else "Export settings"

func _rebuild_trader_settings() -> void:
	for child in _trader_settings_list.get_children():
		_trader_settings_list.remove_child(child)
		child.queue_free()
	var title := Label.new()
	title.text = "Goods this Trader may export"
	title.add_theme_font_size_override("font_size", 16)
	_trader_settings_list.add_child(title)
	var note := Label.new()
	note.text = "Changes take effect on the next day and reset when you load a scenario. Enabled goods use shared export capacity in the order shown. Local households and businesses buy before exports."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trader_settings_list.add_child(note)
	for option in _simulation.get_trader_export_settings(_selected_business_id):
		var checkbox := CheckBox.new()
		checkbox.text = option["name"]
		var option_icon := Commodity.icon_of(option["commodity_id"])
		if option_icon != null:
			checkbox.icon = option_icon
			checkbox.expand_icon = true
			checkbox.add_theme_constant_override("icon_max_width", 18)
		checkbox.button_pressed = option["enabled"]
		checkbox.toggled.connect(_on_trader_export_toggled.bind(_selected_business_id, option["commodity_id"]))
		_trader_settings_list.add_child(checkbox)

func _on_trader_export_toggled(enabled: bool, business_id: int, commodity: int) -> void:
	_simulation.set_trader_export_enabled(business_id, commodity, enabled)
	_refresh()

func _on_market_row_selected(commodity: int) -> void:
	_selected_business_id = -1
	_business_detail_panel.visible = false
	_selected_household_id = -1
	_household_detail_panel.visible = false
	_selected_market_commodity = commodity
	_market_detail_panel.visible = true
	_refresh_market_detail()

func _on_market_detail_close_pressed() -> void:
	_selected_market_commodity = -1
	_market_detail_panel.visible = false

func _refresh_market_detail() -> void:
	if _selected_market_commodity == -1:
		return
	var commodity: Commodity.Type = _selected_market_commodity
	var report := _simulation.get_market_detail(_simulation.get_settlement_ids()[0], commodity)
	_market_detail_title.text = "%s market" % Commodity.name_of(commodity)
	for child in _market_detail_content.get_children():
		_market_detail_content.remove_child(child)
		child.queue_free()
	var clearing: Dictionary = report["last_clearing"]
	_add_market_detail_line("Posted price %.2f  |  Last clearing: offered %.1f, affordable request %.1f, traded %.1f" % [
		report["price"], clearing.get("total_offered", 0.0),
		clearing.get("total_requested_funded", 0.0), clearing.get("quantity_traded", 0.0)])
	_add_market_detail_line("Potential buyers: %d  |  Potential sellers: %d" % [report["buyers"].size(), report["sellers"].size()])
	_add_market_detail_line("Requests and offers estimate the next clearing; affordable does not mean purchased.")
	_add_market_detail_section("Buyers", report["buyers"], "requested", "funded")
	_add_market_detail_section("Sellers", report["sellers"], "offered", "stock")
	_add_market_detail_section("Stored quantities", report["holdings"], "quantity", "")

func _add_market_detail_line(value: String) -> void:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_market_detail_content.add_child(label)

func _add_market_detail_section(title: String, rows: Array, quantity_key: String, secondary_key: String) -> void:
	var heading := Label.new()
	heading.text = "%s (%d)" % [title, rows.size()]
	heading.add_theme_font_size_override("font_size", 14)
	_market_detail_content.add_child(heading)
	if rows.is_empty():
		_add_market_detail_line("None")
		return
	for row in rows:
		if row.get("kind", "") == "export":
			_add_market_detail_line("%s: up to %.1f shared export capacity  |  %.1f exportable from this seller now" % [
				row["owner"], row["capacity"], row["available"]])
			continue
		if row.get("kind", "") == "import":
			_add_market_detail_line("%s: up to %.1f shared import capacity  |  no stored stock" % [
				row["owner"], row["capacity"]])
			continue
		var line := "%s: %.1f %s" % [row["owner"], row[quantity_key], quantity_key]
		if secondary_key != "":
			var secondary_label := "affordable" if secondary_key == "funded" else secondary_key
			line += "  |  %.1f %s" % [row[secondary_key], secondary_label]
		_add_market_detail_line(line)

func _on_trader_transaction_filter_pressed(filter: String) -> void:
	_trader_transaction_filter = filter
	_refresh_business_detail()

func _on_business_employment_filter_pressed(filter: String) -> void:
	_business_employment_filter = filter
	_refresh_business_employment()

## Rebuilds (not just re-labels) the detail grid every call -- the row set
## itself differs by business kind (a Trader has no land/fields, a
## non-field PRODUCTION business has no harvest countdown), so there's no
## single fixed schema to update labels in place against, unlike the
## business/household list rows.
func _refresh_business_detail() -> void:
	if _selected_business_id == -1:
		return
	var report := {}
	for r in _simulation.get_business_reports():
		if r["business_id"] == _selected_business_id:
			report = r
			break
	if report.is_empty():
		# The selected business no longer exists -- e.g. a scenario reload.
		_selected_business_id = -1
		_business_detail_panel.visible = false
		return

	_business_detail_title.text = report["name"]
	_trader_settings_button.visible = report["kind"] == "trader"
	if not _trader_settings_button.visible:
		_trader_settings_open = false
	_update_trader_detail_page()
	_business_detail_sparkline.set_data(report["balance_history"])
	_refresh_business_production_chart(report)

	for child in _business_detail_grid.get_children():
		_business_detail_grid.remove_child(child)
		child.queue_free()

	var runway: float = report["cash_runway_days"]
	var runway_text := "inf" if is_inf(runway) else ("%.0fd" % runway)
	var rows: Array = [
		["Kind", (report["kind"] as String).capitalize()],
		["Capacity", "%d / %d" % [report["capacity"], report["max_capacity"]]],
		["Employed", "%d workers / %d households" % [report["employed_workers"], report["employed_household_count"]]],
	]
	if report.has("herd_size"):
		# A herd's last_actual_units is what the periodic review culled (once
		# per HERD_EVAL_INTERVAL_DAYS), not a daily rate -- label it as such.
		rows.append(["Last review culled", [[report["output_commodity"], "%.1f %s" % [report["last_actual_units"], report["output_commodity"]]]]])
	else:
		rows.append(["Activity" if report["kind"] == "trader" else "Output", [[report["output_commodity"], "%.1f %s/day (planned %.1f)" % [report["last_actual_units"], report["output_commodity"], report["last_planned_units"]], report["kind"] == "trader"]]])
	if report["kind"] != "trader":
		rows.append(["Output inventory", [[report["output_commodity"], "%.1f %s" % [report["stock"], report["output_commodity"]]]]])
	if report.has("input_inventory") and not (report["input_inventory"] as Dictionary).is_empty():
		var input_parts: Array = []
		for commodity_name in (report["input_inventory"] as Dictionary).keys():
			input_parts.append([commodity_name, "%s %.1f" % [commodity_name, report["input_inventory"][commodity_name]]])
		rows.append(["Input inventory", input_parts])
	rows.append_array([
		["Cash", "%.1f" % report["balance"]],
		["Cash runway", runway_text],
		["Revenue/worker (avg)", "%.3f" % report["rolling_average_revenue_per_worker"]],
		["Reference wage", "%.3f" % report["reference_wage_per_worker"]],
		["Wage/worker (last)", "%.3f" % report["last_wage_per_worker"]],
		["Wage shortfall", "%.3f" % report["wage_shortfall"]],
		["Last revenue", "%.2f" % report["last_revenue"]],
		["Last wages paid", "%.2f" % report["last_wages_paid"]],
		["Last cash change", "%.2f" % report["last_cash_change"]],
	])
	if report["land_area_acres"] > 0.0:
		rows.append(["Land", "%.0f acres" % report["land_area_acres"]])
		rows.append(["Next harvest", "%dd" % report["days_to_next_harvest"]])
	if report.has("herd_size"):
		rows.append(["Species", [[report["species"], report["species"]]]])
		rows.append(["Herd size", "%.1f head" % report["herd_size"]])
		rows.append(["Next review", "%dd" % report["days_to_next_harvest"]])
		rows.append(["Husbandry", "%.0f%% care last review (%.2f workers for full care)" % [report["care_fraction"] * 100.0, report["care_workers_needed"]]])
		# Wool is a sheep-only product; a cattle ranch has no wool to report.
		if report["species"] == "Sheep":
			var wool_name := Commodity.name_of(Commodity.Type.WOOL)
			rows.append(["Wool in stock", [[wool_name, "%.1f" % report["wool_stock"]]]])
			rows.append(["Last wool produced", [[wool_name, "%.2f" % report["last_wool_produced"]]]])
		rows.append(["Last hardship butchered", "%.1f head" % report["last_hardship_butchered"]])
	for row in rows:
		_add_detail_row(row[0], row[1])

	var fields: Array = report["fields"]
	for i in fields.size():
		var f: Dictionary = fields[i]
		_add_detail_row("Field %d" % (i + 1), "%.0f ac, day %d/%d" % [f["area"], f["days_growing"], f["growth_days"]])

	_business_detail_herd_events_section.visible = report.has("herd_events")
	if _business_detail_herd_events_section.visible:
		if _cull_target_loaded_for != _selected_business_id:
			_cull_target_loaded_for = _selected_business_id
			_business_detail_cull_target_box.min_value = report["cull_target_min"]
			_business_detail_cull_target_box.max_value = report["cull_target_max"]
			_business_detail_cull_target_box.set_value_no_signal(report["cull_target"])
		var has_wool_hint: bool = report.has("wool_sustaining_unstaffed")
		_business_detail_cull_target_hint.visible = has_wool_hint
		if has_wool_hint:
			_business_detail_cull_target_hint.text = "Sheep needed to cover household wool demand: about %d with no staff, %d at current staffing (%.0f%% care), %d with a full crew." % [
				report["wool_sustaining_unstaffed"], report["wool_sustaining_current"], report["care_fraction"] * 100.0, report["wool_sustaining_staffed"]]
		var herd_events: Array = report["herd_events"]
		if herd_events.is_empty():
			_business_detail_herd_events_display.text = "[i]No herd events yet.[/i]"
		else:
			var herd_lines: Array[String] = []
			for i in range(herd_events.size() - 1, -1, -1):
				herd_lines.append(_format_event(herd_events[i]))
			_business_detail_herd_events_display.text = "\n".join(herd_lines)

	_business_detail_transaction_section.visible = report["kind"] == "trader"
	if _business_detail_transaction_section.visible:
		_refresh_trader_transactions()
	_refresh_business_employment()
	_refresh_business_detail_employees()

## Only PRODUCTION businesses report production_history (traders and herds
## produce nothing through a recipe), so the section hides for the rest. One
## line per output commodity on a shared axis, with a color-keyed legend.
func _refresh_business_production_chart(report: Dictionary) -> void:
	var production_history: Array = report.get("production_history", [])
	_business_detail_production_section.visible = not production_history.is_empty()
	for child in _business_detail_production_legend.get_children():
		_business_detail_production_legend.remove_child(child)
		child.queue_free()
	if production_history.is_empty():
		return
	var series: Array = []
	for i in production_history.size():
		var entry: Dictionary = production_history[i]
		var color := HESparkline.color_for_series(i)
		series.append({"values": entry["values"], "color": color})
		var legend_label := Label.new()
		legend_label.text = entry["commodity"]
		legend_label.add_theme_color_override("font_color", color)
		_business_detail_production_legend.add_child(legend_label)
	_business_detail_production_chart.set_series(series)

## value is either plain text or an Array of [commodity_name, text] parts;
## each part gets the good's icon in front of its text (the name stays in the
## text so the icon is decoration, never the only identifier).
func _add_detail_row(label_text: String, value) -> void:
	var label := Label.new()
	label.text = label_text
	label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_business_detail_grid.add_child(label)
	if value is Array:
		var box := HBoxContainer.new()
		box.add_theme_constant_override("separation", 12)
		for part in value:
			# A third element marks text that names several goods inline
			# (the Trader's "Export (...) / Import (...)" summary).
			box.add_child(_inline_goods_cell(part[1]) if part.size() > 2 and part[2] else _goods_cell(part[0], part[1]))
		_business_detail_grid.add_child(box)
		return
	var value_label := Label.new()
	value_label.text = value
	_business_detail_grid.add_child(value_label)

## Text that mentions goods by name; each mention gets its icon placed right
## before it, e.g. "Export (Grain, Timber)" -> "Export ([icon]Grain, [icon]Timber)".
func _inline_goods_cell(text: String) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	# Longest names first so "Iron Ore" wins over "Iron".
	var names: Array[String] = []
	for t in Commodity.ALL:
		names.append(Commodity.name_of(t))
	names.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	var pattern := RegEx.new()
	pattern.compile("|".join(names.map(func(n: String) -> String: return "\\b%s\\b" % n)))
	var cursor := 0
	for m in pattern.search_all(text):
		var before := text.substr(cursor, m.get_start() - cursor)
		if before != "":
			box.add_child(_plain_label(before))
		box.add_child(_goods_cell(m.get_string(), m.get_string()))
		cursor = m.get_end()
	var rest := text.substr(cursor)
	if rest != "":
		box.add_child(_plain_label(rest))
	return box

func _plain_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label

## Icon (when the good is known and has one) + text label in one cell.
func _goods_cell(commodity_name: String, text: String, min_width: float = 0.0) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	box.custom_minimum_size = Vector2(min_width, 0)
	var commodity := Commodity.type_from_name(commodity_name)
	var icon := Commodity.icon_of(commodity) if commodity != -1 else null
	if icon != null:
		var rect := TextureRect.new()
		rect.texture = icon
		rect.custom_minimum_size = Vector2(18, 18)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		box.add_child(rect)
	var label := Label.new()
	label.text = text
	box.add_child(label)
	return box

func _refresh_trader_transactions() -> void:
	for child in _business_detail_transaction_grid.get_children():
		_business_detail_transaction_grid.remove_child(child)
		child.queue_free()

	for heading in ["Day", "Direction", "Commodity", "Quantity", "Local value"]:
		var header := Label.new()
		header.text = heading
		header.custom_minimum_size = Vector2(80 if heading != "Commodity" else 120, 0)
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		_business_detail_transaction_grid.add_child(header)

	var shown := 0
	for transaction in _simulation.get_trader_transactions(_selected_business_id, TRADER_TRANSACTION_HISTORY_DAYS):
		var direction: String = transaction["direction"]
		if _trader_transaction_filter != "both" and direction != _trader_transaction_filter:
			continue
		var values := [
			str(transaction["day"]),
			direction.capitalize(),
			transaction["commodity"],
			"%.1f" % transaction["quantity"],
			"%.1f" % transaction["local_value"],
		]
		for i in values.size():
			if i == 2:
				_business_detail_transaction_grid.add_child(_goods_cell(values[i], values[i], 120.0))
				continue
			var value := Label.new()
			value.text = values[i]
			if i == 1:
				value.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0) if direction == "import" else Color(0.65, 0.9, 0.65))
			_business_detail_transaction_grid.add_child(value)
		shown += 1
	_business_detail_transaction_empty.visible = shown == 0
	_business_detail_transaction_grid.visible = shown > 0

func _refresh_business_employment() -> void:
	for child in _business_detail_employment_grid.get_children():
		_business_detail_employment_grid.remove_child(child)
		child.queue_free()

	for heading in ["Day", "Event", "Household", "Workers", "Reason"]:
		var header := Label.new()
		header.text = heading
		header.custom_minimum_size = Vector2(85 if heading != "Reason" else 180, 0)
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		_business_detail_employment_grid.add_child(header)

	var shown := 0
	for event in _simulation.get_business_employment_events(_selected_business_id, _business_employment_filter, BUSINESS_EMPLOYMENT_VISIBLE_EVENTS):
		var event_type: String = event["type"]
		var reason := ""
		if event_type == "fired":
			match event["reason"]:
				"low_revenue":
					reason = "Revenue/worker %.3f below reference %.3f" % [event["average_revenue_per_worker"], event["reference_wage_per_worker"]]
				"cash_runway":
					reason = "Cash runway %.1fd below required %.1fd" % [event["cash_runway_days"], event["required_runway_days"]]
				_:
					reason = "Target capacity %d to %d" % [event["old_capacity"], event["new_capacity"]]
		var values := [
			str(event["day"]),
			"Hired" if event_type == "job" else "Fired",
			str(event["household_id"]),
			str(event["workers"]),
			reason,
		]
		for i in values.size():
			var value := Label.new()
			value.text = values[i]
			if i == 1:
				value.add_theme_color_override("font_color", Color(0.55, 0.85, 0.8) if event_type == "job" else Color(0.9, 0.6, 0.55))
			_business_detail_employment_grid.add_child(value)
		shown += 1
	_business_detail_employment_empty.visible = shown == 0
	_business_detail_employment_grid.visible = shown > 0

## Every household currently employed at the selected business -- there's no
## query on HESimulation for "who works here" specifically, so this filters
## get_household_ids()/get_household_summary() by employer_business_id the
## same way a caller outside this file would have to. Rebuilt (not
## re-labeled) every call since who's employed here changes as households
## are hired, die, split, or move on.
func _refresh_business_detail_employees() -> void:
	for child in _business_detail_employee_grid.get_children():
		_business_detail_employee_grid.remove_child(child)
		child.queue_free()

	for col_label in ["Household", "Workers", "Dependents", "Balance", "Food stress"]:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		_business_detail_employee_grid.add_child(header)

	var employee_count := 0
	for household_id in _simulation.get_household_ids():
		var h := _simulation.get_household_summary(household_id)
		if h["employer_business_id"] != _selected_business_id:
			continue
		employee_count += 1
		_add_employee_cell(str(household_id))
		_add_employee_cell(str(h["worker_capacity"]))
		_add_employee_cell(str(h["dependents"]))
		_add_employee_cell("%.1f" % h["balance"])
		_add_employee_cell("%.2f" % h["food_stress"])

	if employee_count == 0:
		var empty_label := Label.new()
		empty_label.text = "No households currently employed here."
		empty_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		_business_detail_employee_grid.add_child(empty_label)

func _add_employee_cell(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(70, 0)
	_business_detail_employee_grid.add_child(label)

## Rebuilt (not just re-labeled) whenever the ACTIVE commodity set changes
## -- see _refresh()'s _known_market_commodities check -- since
## HESimulation.get_market_summary() now only returns commodities with a
## real buyer or seller (a good like iron ore/iron simply isn't in the
## dictionary at all in a scenario with no Bloomery to trade it, rather
## than being present and reading all zeroes forever).
func _rebuild_market_grid() -> void:
	for child in _market_grid.get_children():
		_market_grid.remove_child(child)
		child.queue_free()
	_market_labels.clear()

	for col_label in ["Good", "Price", "Offered", "Affordable request", "Traded"]:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		_market_grid.add_child(header)

	for name in _simulation.get_market_summary().keys():
		var name_button := Button.new()
		name_button.text = name
		name_button.flat = true
		name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_button.custom_minimum_size = Vector2(90, 20)
		var commodity := Commodity.type_from_name(name)
		if commodity != -1:
			name_button.pressed.connect(_on_market_row_selected.bind(commodity))
			name_button.icon = Commodity.icon_of(commodity)
			name_button.expand_icon = true
			name_button.add_theme_constant_override("icon_max_width", 18)
		_market_grid.add_child(name_button)

		var labels := {}
		for key in ["price", "offered", "funded", "traded"]:
			var value_label := Label.new()
			value_label.custom_minimum_size = Vector2(110, 0)
			value_label.add_theme_color_override("font_color", Color(0.6, 0.75, 0.9))
			_market_grid.add_child(value_label)
			labels[key] = value_label
		_market_labels[name] = labels

func _rebuild_business_rows() -> void:
	for child in _business_list.get_children():
		_business_list.remove_child(child)
		child.queue_free()
	_business_rows.clear()

	# The field-model columns (Land, Next harvest, Cash runway, Wage
	# shortfall) push this grid's natural width well past the window. The
	# Businesses tab's ScrollContainer (see _build_ui) scrolls both axes, so
	# the grid can just be a plain child here -- a second, nested horizontal
	# ScrollContainer would eat the mouse wheel for sideways scrolling before
	# handing it to the outer one for vertical.
	var grid := GridContainer.new()
	grid.columns = 14
	_business_list.add_child(grid)
	for col_label in ["Name", "Target", "Max", "Employed", "Land (ac)", "Status", "Revenue/worker (avg)", "Reference wage", "Stock", "Cash", "Cash runway", "Wage shortfall", "Wages", "Cash Δ"]:
		var header := Label.new()
		header.text = col_label
		if col_label == "Status":
			header.custom_minimum_size = Vector2(BUSINESS_STATUS_COLUMN_WIDTH, 0)
			header.clip_text = true
		if col_label == "Revenue/worker (avg)":
			header.mouse_filter = Control.MOUSE_FILTER_STOP
			header.mouse_default_cursor_shape = Control.CURSOR_HELP
			header.tooltip_text = WAGE_TOOLTIP
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)

	for report in _simulation.get_business_reports():
		var business_id: int = report["business_id"]
		var labels := {}
		for key in ["name", "capacity", "max_capacity", "employed", "land", "status", "revenue_per_worker", "reference", "stock", "balance", "runway", "shortfall", "wages", "cash_change"]:
			if key == "name":
				# The only clickable cell in the row -- opens this business's
				# detail panel (see _on_business_row_selected). `flat` keeps
				# it looking like the plain Label every other cell is.
				var name_button := Button.new()
				name_button.custom_minimum_size = Vector2(90, 0)
				name_button.flat = true
				name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
				name_button.pressed.connect(_on_business_row_selected.bind(business_id))
				grid.add_child(name_button)
				labels[key] = name_button
				continue
			var label := Label.new()
			label.custom_minimum_size = Vector2(BUSINESS_STATUS_COLUMN_WIDTH if key == "status" else 90, 0)
			if key == "status":
				label.clip_text = true
				label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				label.mouse_filter = Control.MOUSE_FILTER_STOP
				label.mouse_default_cursor_shape = Control.CURSOR_HELP
			if key == "revenue_per_worker":
				label.mouse_filter = Control.MOUSE_FILTER_STOP
				label.mouse_default_cursor_shape = Control.CURSOR_HELP
				label.tooltip_text = WAGE_TOOLTIP
			grid.add_child(label)
			labels[key] = label
		_business_rows[business_id] = labels

func _rebuild_household_rows() -> void:
	_known_household_ids = _simulation.get_household_ids()
	for child in _household_list.get_children():
		_household_list.remove_child(child)
		child.queue_free()
	_household_rows.clear()

	var grid := GridContainer.new()
	# One stock column per good that satisfies a household need (HENeeds), so a
	# new satisfier gets its column without a dashboard edit.
	var goods_columns: Array[String] = []
	for c in HESimulation.SUBSISTENCE_COMMODITIES:
		goods_columns.append(Commodity.name_of(c))
	var col_labels: Array[String] = ["ID", "Employer", "Workers", "Dependents"]
	col_labels.append_array(goods_columns)
	col_labels.append_array(["Balance", "Stress", "Unmet (scarce)", "Unmet (unfunded)"])
	grid.columns = col_labels.size()
	_household_list.add_child(grid)
	for col_label in col_labels:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)

	for household_id in _simulation.get_household_ids():
		var id_label := Button.new()
		id_label.flat = true
		id_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
		id_label.custom_minimum_size = Vector2(30, 0)
		id_label.tooltip_text = "Open household detail"
		id_label.pressed.connect(_on_household_row_selected.bind(household_id))
		grid.add_child(id_label)

		var employer_label := Label.new()
		employer_label.custom_minimum_size = Vector2(80, 0)
		grid.add_child(employer_label)

		var workers_label := Label.new()
		workers_label.custom_minimum_size = Vector2(50, 0)
		workers_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		grid.add_child(workers_label)

		var dependents_label := Label.new()
		dependents_label.custom_minimum_size = Vector2(90, 0)
		dependents_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6))
		dependents_label.tooltip_text = "Age (in days) of each dependent still in this household; the oldest is next to come of age and split off on its own."
		grid.add_child(dependents_label)

		var goods_labels := {}
		for c in HESimulation.SUBSISTENCE_COMMODITIES:
			var goods_label := Label.new()
			goods_label.custom_minimum_size = Vector2(70, 0)
			grid.add_child(goods_label)
			goods_labels[c] = goods_label

		var balance_label := Label.new()
		balance_label.custom_minimum_size = Vector2(70, 0)
		grid.add_child(balance_label)

		var stress_label := Label.new()
		stress_label.custom_minimum_size = Vector2(60, 0)
		grid.add_child(stress_label)

		var scarcity_label := Label.new()
		scarcity_label.custom_minimum_size = Vector2(90, 0)
		scarcity_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		grid.add_child(scarcity_label)

		var unaffordable_label := Label.new()
		unaffordable_label.custom_minimum_size = Vector2(90, 0)
		unaffordable_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4))
		grid.add_child(unaffordable_label)

		_household_rows[household_id] = {
			"id": id_label, "employer": employer_label, "workers": workers_label, "dependents": dependents_label,
			"goods": goods_labels, "balance": balance_label,
			"stress": stress_label, "scarcity": scarcity_label, "unaffordable": unaffordable_label,
		}

func _refresh() -> void:
	var clock := _simulation.get_clock_summary()
	_day_label.text = "Day %d" % clock["day"]

	var city := _simulation.get_city_summary()
	_city_stats_label.text = "households=%d  population=%d  unemployed households=%d  avg stress=%.2f  short of goods=%d  short of funds=%d  total money=%.1f  emigrations (lifetime)=%d  old age deaths (lifetime)=%d  births (lifetime)=%d  worker promotions (lifetime)=%d  money written off=%.1f  export revenue (lifetime)=%.1f  import cost (lifetime)=%.1f" % [
		city["household_count"], city["population"], city["unemployed_household_count"], city["avg_food_stress"],
		city["households_short_of_goods"], city["households_short_of_funds"], city["total_money"],
		city["emigrations_total"], city["old_age_deaths_total"], city["births_total"], city["worker_promotions_total"], city["money_written_off_total"], city["export_revenue_total"], city["import_cost_total"]]

	var market := _simulation.get_market_summary()
	var current_market_commodities := market.keys()
	if current_market_commodities != _known_market_commodities:
		_rebuild_market_grid()
		_known_market_commodities = current_market_commodities
	for commodity_name in _market_labels.keys():
		var labels: Dictionary = _market_labels[commodity_name]
		var entry: Dictionary = market[commodity_name]
		var clearing: Dictionary = entry["last_clearing"]
		(labels["price"] as Label).text = "%.2f" % entry["price"]
		(labels["offered"] as Label).text = "%.1f" % clearing.get("total_offered", 0.0)
		(labels["funded"] as Label).text = "%.1f" % clearing.get("total_requested_funded", 0.0)
		(labels["traded"] as Label).text = "%.1f" % clearing.get("quantity_traded", 0.0)
	_refresh_market_detail()

	for report in _simulation.get_business_reports():
		var row: Dictionary = _business_rows.get(report["business_id"], {})
		if row.is_empty():
			continue
		var name_button := row["name"] as Button
		if report.has("herd_size"):
			name_button.text = "%s (herd: %.0f)" % [report["name"], report["herd_size"]]
			name_button.tooltip_text = "Wool in stock: %.1f" % report["wool_stock"] if report.get("wool_stock", 0.0) > 0.0 else ""
		else:
			name_button.text = report["name"]
			name_button.tooltip_text = ""
		(row["capacity"] as Label).text = str(report["capacity"])
		(row["max_capacity"] as Label).text = str(report["max_capacity"])
		(row["employed"] as Label).text = "%d workers / %d hh" % [report["employed_workers"], report["employed_household_count"]]
		var land: float = report["land_area_acres"]
		(row["land"] as Label).text = ("%.0f" % land) if land > 0.0 else "-"
		var status_label := row["status"] as Label
		if report.has("herd_size"):
			var herd_text := "Herd %.0f · next review in %dd · culled %.1f %s" % [report["herd_size"], maxi(report["days_to_next_harvest"], 0), report["last_actual_units"], report["output_commodity"]]
			if report.get("last_wool_produced", 0.0) > 0.0:
				herd_text += " · +%.2f wool" % report["last_wool_produced"]
			status_label.text = herd_text
			status_label.tooltip_text = herd_text
		elif land > 0.0:
			var next_harvest: int = report["days_to_next_harvest"]
			var expected: float = report["next_harvest_expected_units"]
			var yield_percent: float = report["next_harvest_yield_fraction"] * 100.0
			var status_text := "Growing · harvest in %dd · %.1f %s expected · %.0f%% projected yield" % [next_harvest, expected, report["output_commodity"], yield_percent]
			status_label.text = status_text
			status_label.tooltip_text = "%s\n\nProjected from labor already applied plus the current crew continuing until harvest." % status_text
		elif report["kind"] == "trader":
			status_label.text = "Moved %.1f / %.1f units" % [report["last_actual_units"], report["last_planned_units"]]
			status_label.tooltip_text = report["output_commodity"]
		else:
			status_label.text = "Producing %.1f / %.1f %s" % [report["last_actual_units"], report["last_planned_units"], report["output_commodity"]]
			status_label.tooltip_text = "Actual output / labor-planned output for the current day."
		var revenue_per_worker: float = report["rolling_average_revenue_per_worker"]
		var reference: float = report["reference_wage_per_worker"]
		var revenue_label := row["revenue_per_worker"] as Label
		revenue_label.text = "%.3f" % revenue_per_worker
		revenue_label.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6) if revenue_per_worker > reference else Color(0.9, 0.5, 0.5))
		(row["reference"] as Label).text = "%.3f" % reference
		(row["stock"] as Label).text = "%.1f" % report["stock"]
		(row["balance"] as Label).text = "%.1f" % report["balance"]
		var runway: float = report["cash_runway_days"]
		var runway_label := row["runway"] as Label
		runway_label.text = "inf" if is_inf(runway) else ("%.0fd" % runway)
		runway_label.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5) if runway < 0.0 else Color(0.75, 0.75, 0.8))
		var shortfall: float = report["wage_shortfall"]
		var shortfall_label := row["shortfall"] as Label
		shortfall_label.text = ("%.1f" % shortfall) if shortfall > 0.01 else ""
		(row["wages"] as Label).text = "%.1f" % report["last_wages_paid"]
		var cash_change: float = report["last_cash_change"]
		var cash_change_label := row["cash_change"] as Label
		cash_change_label.text = "%+.1f" % cash_change
		cash_change_label.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6) if cash_change >= 0.0 else Color(0.9, 0.5, 0.5))

	if _selected_business_id != -1:
		_refresh_business_detail()

	var current_ids := _simulation.get_household_ids()
	if current_ids != _known_household_ids:
		# A household died (or, later, split) since the rows were built --
		# rebuild the table to match exactly who's actually still alive,
		# rather than leaving a dead household's row frozen forever on
		# whatever it last displayed (which is how this previously made a
		# starved-out city look like it still had all its original
		# households, just stuck at 1/1).
		_known_household_ids = current_ids
		_rebuild_household_rows()

	for household_id in _household_rows.keys():
		var h := _simulation.get_household_summary(household_id)
		var row: Dictionary = _household_rows[household_id]
		(row["id"] as Button).text = str(household_id)
		(row["employer"] as Label).text = _business_names.get(h["employer_business_id"], "Unemployed")
		var worker_ages: Array = h["worker_ages"]
		var workers_label := row["workers"] as Label
		if worker_ages.is_empty():
			workers_label.text = "0"
		else:
			var oldest_worker: int = worker_ages.max()
			workers_label.text = "%d (oldest: %dd)" % [worker_ages.size(), oldest_worker]

		var dependent_ages: Array = h["dependent_ages"]
		var dependents_label := row["dependents"] as Label
		if dependent_ages.is_empty():
			dependents_label.text = "0"
		else:
			var oldest: int = dependent_ages.max()
			dependents_label.text = "%d (oldest: %dd)" % [dependent_ages.size(), oldest]
		for c in HESimulation.SUBSISTENCE_COMMODITIES:
			(row["goods"][c] as Label).text = "%.1f" % h["inventory"][Commodity.name_of(c)]
		(row["balance"] as Label).text = "%.1f" % h["balance"]
		(row["stress"] as Label).text = "%.2f" % h["food_stress"]

		var scarcity_total := 0.0
		for v in h["unmet_scarcity_today"].values():
			scarcity_total += v
		var unaffordable_total := 0.0
		for v in h["unmet_unaffordable_today"].values():
			unaffordable_total += v
		(row["scarcity"] as Label).text = ("%.2f" % scarcity_total) if scarcity_total > 0.01 else ""
		(row["unaffordable"] as Label).text = ("%.2f" % unaffordable_total) if unaffordable_total > 0.01 else ""

	_refresh_household_detail()
	_refresh_blotter()

## Newest event first, since that's what a player checking in on the city
## cares about seeing without scrolling.
func _refresh_blotter() -> void:
	var events := _simulation.get_event_log_days(BLOTTER_HISTORY_DAYS)
	var lines: Array[String] = []
	for i in range(events.size() - 1, -1, -1):
		if not _blotter_filter_enabled.get(events[i]["type"], true):
			continue
		lines.append(_format_event(events[i]))
	if lines.is_empty():
		_blotter_display.text = "[i]No events match the active filters.[/i]"
		return
	_blotter_display.text = "\n".join(lines)

func _format_event(event: Dictionary) -> String:
	var day: int = event["day"]
	match event["type"]:
		"birth":
			return "[color=#8fd98f]Day %d - Household %d: birth[/color]" % [day, event["household_id"]]
		"emigrate":
			var suffix := " - household ended" if event["household_ended"] else ""
			return "[color=#e08d8d]Day %d - Household %d: %s emigrated (starvation)%s[/color]" % [day, event["household_id"], event["member_type"], suffix]
		"old_age":
			var count: int = event["count"]
			var plural := "s" if count != 1 else ""
			return "[color=#a0a0a0]Day %d - Household %d: %d worker%s died of old age[/color]" % [day, event["household_id"], count, plural]
		"adopted":
			var dep_count: int = event["dependents"]
			var dep_plural := "s" if dep_count != 1 else ""
			return "[color=#a0a0a0]Day %d - Household %d dissolved: %d dependent%s adopted by Household %d[/color]" % [day, event["household_id"], dep_count, dep_plural, event["adopting_household_id"]]
		"split":
			return "[color=#8db4e0]Day %d - Household %d split: Household %d founded[/color]" % [day, event["parent_household_id"], event["new_household_id"]]
		"coming_of_age":
			return "[color=#d9c98f]Day %d - Household %d: member came of age[/color]" % [day, event["household_id"]]
		"job":
			var employer: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			return "[color=#8fd9d0]Day %d - Household %d: hired by %s[/color]" % [day, event["household_id"], employer]
		"herd_birth":
			var ranch: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			var condition := "" if event["fed"] else " (overgrazed)"
			return "[color=#8fd98f]Day %d - %s: %.1f born, %.1f died%s, %.0f%% care (herd now %.0f)[/color]" % [day, ranch, event["born"], event["died"], condition, event["care"] * 100.0, event["herd_after"]]
		"herd_cull":
			var culling_ranch: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			return "[color=#d9c98f]Day %d - %s: culled %.1f head for sale (herd now %.0f)[/color]" % [day, culling_ranch, event["head"], event["herd_after"]]
		"hardship_butcher":
			var owner_name: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			return "[color=#e0b080]Day %d - %s: hardship butchering, sold %.1f head for %.1f to cover a %.1f wage shortfall (herd now %.0f)[/color]" % [
				day, owner_name, event["head"], event["proceeds"], event["shortfall"], event["herd_after"]]
		"fired":
			var employer: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			var reason: String
			match event["reason"]:
				"low_revenue":
					reason = "revenue/worker %.3f below reference %.3f" % [event["average_revenue_per_worker"], event["reference_wage_per_worker"]]
				"cash_runway":
					reason = "cash runway %.1fd below required %.1fd" % [event["cash_runway_days"], event["required_runway_days"]]
				_:
					reason = "target reduced to %d workers" % event["new_capacity"]
			return "[color=#e09a8d]Day %d - Household %d: laid off by %s (%s; target %d→%d)[/color]" % [day, event["household_id"], employer, reason, event["old_capacity"], event["new_capacity"]]
		_:
			return "Day %d - %s" % [day, event["type"]]
