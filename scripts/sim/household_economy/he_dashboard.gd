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

const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")

## Row order of the Needs tab.
const NEEDS_TAB_ORDER := [HENeed.Id.HEAT, HENeed.Id.FOOD, HENeed.Id.CLOTHING]
const NEED_UNMET_COLOR := Color(0.9, 0.35, 0.35)
## Offered by the Businesses tab's "Create business" menu: every kind in
## HEScenarioSeeds.business_types(), so a new kind shows up here by being
## registered there. Each kind is unique per town (matched by
## HEBusiness.type_key) and costs nothing -- both may change later.
const SEED := 4242
const SECONDS_PER_DAY_AT_1X := 1.0
const WAGE_TOOLTIP := "A business paying above the reference wage grows (green); one paying below shrinks (red)."
## Filters always rescan this complete simulated-time window. The view is
## scrollable, so no separate event-count cap can hide an enabled category.
## Household detail looks back as far as the sim retains events
## (HESimulation.EVENT_LOG_RETENTION_DAYS); the main blotter follows GameState.blotter_days.
const HOUSEHOLD_EVENT_HISTORY_DAYS := 360
const BUSINESS_STATUS_COLUMN_WIDTH := 430.0
const TRADER_TRANSACTION_HISTORY_DAYS := 30
## Window for the top-line treasury's hover change.
const TREASURY_TREND_DAYS := 30
const BUSINESS_EMPLOYMENT_VISIBLE_EVENTS := 50
## Views of the goods chart on a production business's detail tab, switched
## by tabs above it. Each series is [series id, legend suffix, dashed]: outputs
## solid, inputs dashed. "details" are [series id, label] pairs listed in the
## hover readout under each good's value without being drawn -- the inventory
## view shows that day's made/sold beside the stock, since stock is just the
## running total of those two. The Flows view shows made and sold (outputs),
## used and bought (inputs); the chart hides when nothing ever moved.
const FLOW_VIEWS := [
	{
		"label": "Inventory",
		"series": [[HEBusiness.LEVEL_STOCK, "in stock", false]],
		"details": [[HEBusiness.FLOW_PRODUCED, "made"], [HEBusiness.FLOW_SOLD, "sold"]],
	},
	{
		"label": "Flows",
		"series": [
			[HEBusiness.FLOW_PRODUCED, "made", false], [HEBusiness.FLOW_SOLD, "out", false],
			[HEBusiness.FLOW_CONSUMED, "used", true], [HEBusiness.FLOW_BOUGHT, "in", true],
		],
	},
]
## Town tab read-outs: [label, city-summary key, format].
const TOWN_STATS := [
	["Households", "household_count", "%d"],
	["Population", "population", "%d"],
	["Unemployed households", "unemployed_household_count", "%d"],
	["Avg stress", "avg_food_stress", "%.2f"],
	["Short of goods", "households_short_of_goods", "%d"],
	["Short of funds", "households_short_of_funds", "%d"],
	["Total money", "total_money", "%.1f"],
	["Emigrations (lifetime)", "emigrations_total", "%d"],
	["Old age deaths (lifetime)", "old_age_deaths_total", "%d"],
	["Births (lifetime)", "births_total", "%d"],
	["Worker promotions (lifetime)", "worker_promotions_total", "%d"],
	["Money written off", "money_written_off_total", "%.1f"],
	["Export revenue (lifetime)", "export_revenue_total", "%.1f"],
	["Import cost (lifetime)", "import_cost_total", "%.1f"],
]
## Births, emigrations and deaths are evaluated monthly, so the daily record is
## mostly zeros with a spike every 30 days; the flow chart plots a trailing
## sum over this many days instead so the lines are readable.
const TOWN_FLOW_WINDOW_DAYS := 30
## [series name, daily-record key]
const TOWN_POPULATION_SERIES := [
	["Population", "population"],
	["Households", "households"],
	["Unemployed households", "unemployed_households"],
]
const TOWN_FLOW_SERIES := [
	["Births", "births"],
	["Emigrations", "emigrations"],
	["Old-age deaths", "old_age_deaths"],
]

const BLOTTER_FILTERS := [
	{"type": "birth", "label": "Births"},
	{"type": "emigrate", "label": "Starvation emigration"},
	{"type": "old_age", "label": "Old-age deaths"},
	{"type": "adopted", "label": "Adoptions"},
	{"type": "split", "label": "Household founding"},
	{"type": "coming_of_age", "label": "Coming of age"},
	{"type": "job", "label": "Hiring"},
	{"type": "fired", "label": "Firing / layoffs"},
	{"type": "business_failed", "label": "Business closures"},
	{"type": "herd_birth", "label": "Herd births"},
	{"type": "herd_cull", "label": "Herd culls"},
	{"type": "hardship_butcher", "label": "Hardship butchering"},
]

## Set by the config page (he_config.gd) before it switches to this scene.
## Falls back to the evenly staffed preset if the scene is opened directly.
static var pending_builder: Callable = Callable()

var _simulation: HESimulation
var _speed_multiplier: float = 1.0
var _day_accumulator: float = 0.0

var _day_label: Label
var _treasury_margin: Control
var _population_label: Label
var _top_unemployed_label: Label
var _avg_health_label: Label
var _avg_morale_label: Label
var _population_box: HBoxContainer
var _population_tip: PanelContainer
var _population_tip_label: Label
var _treasury_box: HBoxContainer
var _treasury_label: Label
var _treasury_tip: PanelContainer
var _treasury_tip_label: Label
var _town_stat_labels: Dictionary = {} # city-summary key -> Label
var _town_population_chart: HESparkline
var _town_population_title: Label
var _cash_history_label: Label
var _goods_title_label: Label
var _town_flow_chart: HESparkline
var _market_grid: GridContainer
var _market_labels: Dictionary = {} # commodity_name -> {"price","offered","funded","traded"}
var _known_market_commodities: Array = [] # rebuild trigger -- see _refresh()
var _business_list: VBoxContainer
var _business_rows: Dictionary = {} # business_id -> {row labels...}
var _household_list: VBoxContainer
var _jobs_list: VBoxContainer
var _job_rows: Dictionary = {} # business_id -> {name, capacity, max_capacity, employed, open}
var _job_totals: Dictionary = {}
var _unemployed_label: Label
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
var _business_detail_flow_chart: Dictionary = {} # {"section", "legend", "chart"}, see _build_flow_chart
var _business_flow_view := 0 # index into FLOW_VIEWS; kept across business selections
var _business_flow_hidden: Dictionary = {} # series name -> true for lines toggled off in the legend
var _flow_series_names: Array = [] # names of the current view's lines, set by _refresh_business_flow_chart
var _flow_legend_key := "" # what the legend buttons were last built for
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
## Reopen callables for the detail views the player navigated through via
## links (market -> business -> household ...); closing a detail pops one.
## In memory only; empty means close back to the list. Opening a detail from
## a list row clears it.
var _return_stack: Array[Callable] = []
var _market_detail_panel: PanelContainer
var _market_detail_title: Label
var _market_detail_content: VBoxContainer
## User toggle for the market chart's "Requested" series -- see
## _add_market_detail_chart.
var _market_chart_export_appetite := false
## -1 means no need is selected; otherwise a HENeed.Id whose detail panel is
## stacked over the household list like the market and household panels.
var _selected_need_id: int = -1
var _need_detail_panel: PanelContainer
var _need_detail_title: Label
var _need_detail_content: VBoxContainer
var _need_labels: Dictionary = {} # HENeed.Id -> {"met","unmet","unmet_demand"} Labels on the Needs tab
var _selected_household_id: int = -1
var _household_detail_panel: PanelContainer
var _household_detail_title: Label
var _household_detail_content: VBoxContainer
var _person_detail_panel: PanelContainer
var _person_detail_title: Label
var _person_detail_content: VBoxContainer
var _selected_person_household_id: int = -1
var _selected_person_number: int = -1

func _ready() -> void:
	# The valley hosting an embedded view has its own menu. get() because
	# embedded_mode only exists once the valley integration lands.
	if not get("embedded_mode"):
		EscapeMenu.attach_to(self)
	for filter in BLOTTER_FILTERS:
		_blotter_filter_enabled[filter["type"]] = true
	_configure_tooltip_theme()
	GameState.settings_changed.connect(_on_history_settings_changed)
	_load_scenario()
	_build_ui()
	_update_history_titles()
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

func _load_scenario() -> void:
	var builder := pending_builder
	if not builder.is_valid():
		builder = Callable(HEScenarioSeeds, "build_three_business_economy")
	_simulation = HESimulation.new(SEED, builder)
	_business_names.clear()
	for report in _simulation.get_business_reports():
		_business_names[report["business_id"]] = report["name"]
	_day_accumulator = 0.0
	# A business_id selected in the PREVIOUS scenario has no meaning here --
	# guarded null check because this runs once before _build_ui() ever
	# creates the panel (see _ready()).
	_selected_business_id = -1
	_return_stack.clear()
	_trader_settings_open = false
	if _business_detail_panel != null:
		_business_detail_panel.visible = false
	_selected_market_commodity = -1
	if _market_detail_panel != null:
		_market_detail_panel.visible = false
	_selected_need_id = -1
	if _need_detail_panel != null:
		_need_detail_panel.visible = false
	_selected_household_id = -1
	if _household_detail_panel != null:
		_household_detail_panel.visible = false
		_clear_person_detail()

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

	# Government treasury: "<gold icon> 99 gold", hover for the 30-day change.
	# Hidden when the scenario has no government.
	_treasury_box = HBoxContainer.new()
	_treasury_box.add_theme_constant_override("separation", 4)
	_treasury_box.mouse_filter = Control.MOUSE_FILTER_STOP
	var treasury_icon := TextureRect.new()
	treasury_icon.texture = Commodity.gold_icon()
	treasury_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	treasury_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	treasury_icon.custom_minimum_size = Vector2(24, 24)
	treasury_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	treasury_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_treasury_box.add_child(treasury_icon)
	_treasury_label = Label.new()
	_treasury_label.add_theme_font_size_override("font_size", 22)
	_treasury_label.add_theme_color_override("font_color", Commodity.GOLD_COLOR)
	_treasury_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_treasury_box.add_child(_treasury_label)
	var treasury_margin := MarginContainer.new()
	treasury_margin.add_theme_constant_override("margin_left", 16)
	treasury_margin.add_child(_treasury_box)
	top_bar.add_child(treasury_margin)
	_treasury_margin = treasury_margin

	# A built-in tooltip is frozen once shown, so the 30-day change would stop
	# updating while hovered (sim speed can be 100x). This popup is refreshed
	# by _refresh_treasury() every tick instead.
	_treasury_tip = PanelContainer.new()
	_treasury_tip.top_level = true
	_treasury_tip.visible = false
	_treasury_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_treasury_tip_label = Label.new()
	_treasury_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_treasury_tip.add_child(_treasury_tip_label)
	add_child(_treasury_tip)
	_treasury_box.mouse_entered.connect(_on_treasury_hover.bind(true))
	_treasury_box.mouse_exited.connect(_on_treasury_hover.bind(false))

	top_bar.add_child(_build_population_summary())

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	top_bar.add_child(_make_settings_button())
	top_bar.add_child(_make_speed_button("Pause", 0.0))
	top_bar.add_child(_make_speed_button("1x", 1.0))
	top_bar.add_child(_make_speed_button("10x", 10.0))
	top_bar.add_child(_make_speed_button("100x", 100.0))

	# Town, Businesses and Goods share one fixed-height tabbed area. Stacked, the
	# business list grew with every new business and crowded out the
	# households/detail row below; each tab scrolls internally instead.
	var top_tabs := TabContainer.new()
	top_tabs.custom_minimum_size = Vector2(0, 250)
	vbox.add_child(top_tabs)

	_build_town_tab(top_tabs)

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

	_build_needs_tab(top_tabs)

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

	# Jobs (index 0) is a collapsed one-row-per-business view; Households
	# (index 1) is the per-household table. The detail panels added below sit
	# over the whole tab container, so they still override whichever is showing.
	var list_tabs := TabContainer.new()
	list_tabs.set_anchors_preset(Control.PRESET_FULL_RECT)
	content_area.add_child(list_tabs)

	var jobs_scroll := ScrollContainer.new()
	jobs_scroll.name = "Jobs"
	list_tabs.add_child(jobs_scroll)
	_jobs_list = VBoxContainer.new()
	_jobs_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jobs_scroll.add_child(_jobs_list)

	var scroll := ScrollContainer.new()
	scroll.name = "Households"
	list_tabs.add_child(scroll)

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
	_cash_history_label = cash_history_label
	cash_history_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	detail_content.add_child(cash_history_label)

	_business_detail_sparkline = HESparkline.new()
	_business_detail_sparkline.custom_minimum_size = Vector2(0, 60)
	detail_content.add_child(_business_detail_sparkline)

	_business_detail_flow_chart = _build_flow_chart(detail_content)

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
	# Outside _market_detail_content on purpose: that content is rebuilt on
	# every refresh, and recreating a checkbox mid-click would swallow it.
	var export_toggle := CheckBox.new()
	export_toggle.text = "Count Trader export capacity as demand"
	export_toggle.tooltip_text = "Off: exports count only what the Trader actually shipped.\nOn: exports count the Trader's remaining capacity, i.e. what it would take if the seller had the stock."
	export_toggle.button_pressed = _market_chart_export_appetite
	export_toggle.toggled.connect(_on_market_export_appetite_toggled)
	market_detail_box.add_child(export_toggle)
	var market_scroll := ScrollContainer.new()
	market_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	market_detail_box.add_child(market_scroll)
	_market_detail_content = VBoxContainer.new()
	_market_detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_market_detail_content.add_theme_constant_override("separation", 6)
	market_scroll.add_child(_market_detail_content)

	_need_detail_panel = PanelContainer.new()
	_need_detail_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_need_detail_panel.add_theme_stylebox_override("panel", detail_panel_style.duplicate())
	_need_detail_panel.visible = false
	content_area.add_child(_need_detail_panel)
	var need_detail_box := VBoxContainer.new()
	_need_detail_panel.add_child(need_detail_box)
	var need_title_bar := HBoxContainer.new()
	need_detail_box.add_child(need_title_bar)
	_need_detail_title = Label.new()
	_need_detail_title.add_theme_font_size_override("font_size", 16)
	need_title_bar.add_child(_need_detail_title)
	var need_title_spacer := Control.new()
	need_title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	need_title_bar.add_child(need_title_spacer)
	var need_close := Button.new()
	need_close.text = "X"
	need_close.tooltip_text = "Close (back to household list)"
	need_close.pressed.connect(_on_need_detail_close_pressed)
	need_title_bar.add_child(need_close)
	var need_scroll := ScrollContainer.new()
	need_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	need_detail_box.add_child(need_scroll)
	_need_detail_content = VBoxContainer.new()
	_need_detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_need_detail_content.add_theme_constant_override("separation", 6)
	need_scroll.add_child(_need_detail_content)

	_household_detail_panel = PanelContainer.new()
	_household_detail_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_household_detail_panel.add_theme_stylebox_override("panel", detail_panel_style.duplicate())
	_household_detail_panel.visible = false
	_clear_person_detail()
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

	_person_detail_panel = PanelContainer.new()
	_person_detail_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_person_detail_panel.add_theme_stylebox_override("panel", detail_panel_style.duplicate())
	_person_detail_panel.visible = false
	content_area.add_child(_person_detail_panel)
	var person_detail_box := VBoxContainer.new()
	_person_detail_panel.add_child(person_detail_box)
	var person_title_bar := HBoxContainer.new()
	person_detail_box.add_child(person_title_bar)
	_person_detail_title = Label.new()
	_person_detail_title.add_theme_font_size_override("font_size", 16)
	person_title_bar.add_child(_person_detail_title)
	var person_title_spacer := Control.new()
	person_title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	person_title_bar.add_child(person_title_spacer)
	var person_close := Button.new()
	person_close.text = "X"
	person_close.tooltip_text = "Close (back to previous view)"
	person_close.pressed.connect(_on_person_detail_close_pressed)
	person_title_bar.add_child(person_close)
	var person_scroll := ScrollContainer.new()
	person_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	person_detail_box.add_child(person_scroll)
	_person_detail_content = VBoxContainer.new()
	_person_detail_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_person_detail_content.add_theme_constant_override("separation", 6)
	person_scroll.add_child(_person_detail_content)

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
	# Keep the menu open so several filters can be toggled in one visit.
	blotter_filter_popup.hide_on_checkable_item_selection = false
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

## "<person icon> 123 (12 unemployed)    Health 82%    Morale 64%" -- town-wide headcount and
## per-person averages, colored by _wellbeing_color().
func _build_population_summary() -> Control:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.mouse_entered.connect(_on_population_hover.bind(true))
	box.mouse_exited.connect(_on_population_hover.bind(false))
	margin.add_child(box)
	_population_box = box

	# Same live-refreshing popup approach as the treasury tip: a built-in
	# tooltip would freeze its text while hovered.
	_population_tip = PanelContainer.new()
	_population_tip.top_level = true
	_population_tip.visible = false
	_population_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_population_tip_label = Label.new()
	_population_tip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_population_tip.add_child(_population_tip_label)
	add_child(_population_tip)

	var icon := TextureRect.new()
	icon.texture = _person_icon()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(24, 24)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(icon)
	_population_label = Label.new()
	_population_label.add_theme_font_size_override("font_size", 22)
	box.add_child(_population_label)
	_top_unemployed_label = Label.new()
	_top_unemployed_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_top_unemployed_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_child(_top_unemployed_label)

	var health_caption := Label.new()
	health_caption.text = "Health"
	health_caption.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	var health_margin := MarginContainer.new()
	health_margin.add_theme_constant_override("margin_left", 16)
	health_margin.add_child(health_caption)
	box.add_child(health_margin)
	_avg_health_label = Label.new()
	_avg_health_label.add_theme_font_size_override("font_size", 22)
	box.add_child(_avg_health_label)

	var morale_caption := Label.new()
	morale_caption.text = "Morale"
	morale_caption.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	var morale_margin := MarginContainer.new()
	morale_margin.add_theme_constant_override("margin_left", 16)
	morale_margin.add_child(morale_caption)
	box.add_child(morale_margin)
	_avg_morale_label = Label.new()
	_avg_morale_label.add_theme_font_size_override("font_size", 22)
	box.add_child(_avg_morale_label)
	return margin

## A simple head-and-shoulders silhouette, rasterized from inline SVG so it
## needs no asset file.
static func _person_icon() -> Texture2D:
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 48 48"><circle cx="24" cy="15" r="9" fill="#d8d8e0"/><path d="M6 44 C6 31 14 26 24 26 C34 26 42 31 42 44 Z" fill="#d8d8e0"/></svg>'
	var image := Image.new()
	image.load_svg_from_string(svg)
	return ImageTexture.create_from_image(image)

## Red below 50%, yellow up to 80%, green above.
static func _wellbeing_color(value: float) -> Color:
	if value < 0.5:
		return Color(0.85, 0.35, 0.3)
	if value <= 0.8:
		return Color(0.9, 0.7, 0.3)
	return Color(0.4, 0.75, 0.45)

func _refresh_population_summary() -> void:
	var w := _simulation.get_population_wellbeing()
	_population_label.text = "%d" % w["population"]
	_top_unemployed_label.text = "(%d unemployed)" % w["unemployed"]
	_avg_health_label.text = "%.0f%%" % (w["avg_health"] * 100.0)
	_avg_health_label.add_theme_color_override("font_color", _wellbeing_color(w["avg_health"]))
	_avg_morale_label.text = "%.0f%%" % (w["avg_morale"] * 100.0)
	_avg_morale_label.add_theme_color_override("font_color", _wellbeing_color(w["avg_morale"]))
	var tip := "%d people. Averages are per person." % w["population"]
	tip += _factor_tip_section("Health", w["avg_health"], w["health_factors"], w["population"])
	tip += _factor_tip_section("Morale", w["avg_morale"], w["morale_factors"], w["population"])
	_population_tip_label.text = tip
	_population_tip.reset_size()

## "\nHealth 82%\n  Food shortfall: -10 pts (affects 40 of 120 people)" -- or a
## note that nothing is dragging it down.
func _factor_tip_section(caption: String, average: float, factors: Array, population: int) -> String:
	var text := "\n\n%s %.0f%%" % [caption, average * 100.0]
	if factors.is_empty():
		return text + "\n  Nothing is lowering it."
	for factor in factors:
		text += "\n  %s: -%.1f pts (affects %d of %d people)" % [factor["label"], factor["avg_loss"] * 100.0, factor["people"], population]
	return text

func _on_population_hover(hovering: bool) -> void:
	_population_tip.visible = hovering
	if hovering:
		_refresh_population_summary()
		_population_tip.global_position = _population_box.global_position + Vector2(0, _population_box.size.y + 6)

## Town tab (index 0): the city-wide indicators on the left, and two charts on
## the right -- population levels, and births/emigrations/deaths.
func _build_town_tab(top_tabs: TabContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "Town"
	row.add_theme_constant_override("separation", 16)
	top_tabs.add_child(row)

	var stats_scroll := ScrollContainer.new()
	stats_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_scroll.size_flags_stretch_ratio = 1.0
	stats_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(stats_scroll)
	var stats_grid := GridContainer.new()
	stats_grid.columns = 2
	stats_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_scroll.add_child(stats_grid)
	for stat in TOWN_STATS:
		var name_label := Label.new()
		name_label.text = stat[0]
		name_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stats_grid.add_child(name_label)
		var value_label := Label.new()
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stats_grid.add_child(value_label)
		_town_stat_labels[stat[1]] = value_label

	var charts := VBoxContainer.new()
	charts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	charts.size_flags_stretch_ratio = 2.0
	row.add_child(charts)
	_town_population_chart = _add_town_chart(charts, "", TOWN_POPULATION_SERIES)
	_town_population_title = _town_population_chart.get_meta("title_label")
	_town_flow_chart = _add_town_chart(charts, "Births, emigrations and deaths (trailing %d-day total)" % TOWN_FLOW_WINDOW_DAYS, TOWN_FLOW_SERIES)

## A title row with a color-keyed legend above a hoverable chart.
func _add_town_chart(parent: Control, title_text: String, series_defs: Array) -> HESparkline:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	parent.add_child(header)
	var title := Label.new()
	title.text = title_text
	title.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	header.add_child(title)
	for i in series_defs.size():
		var legend := Label.new()
		legend.text = series_defs[i][0]
		legend.add_theme_color_override("font_color", HESparkline.color_for_series(i))
		header.add_child(legend)
	var chart := HESparkline.new()
	chart.set_meta("title_label", title)
	chart.custom_minimum_size = Vector2(0, 60)
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chart.show_max_label = true
	parent.add_child(chart)
	return chart

func _refresh_town() -> void:
	var city := _simulation.get_city_summary()
	for stat in TOWN_STATS:
		(_town_stat_labels[stat[1]] as Label).text = stat[2] % city[stat[1]]
	# Extra leading days so the trailing flow sums are full from the first point.
	var history := _simulation.get_daily_history(GameState.sparkline_days + TOWN_FLOW_WINDOW_DAYS - 1)
	var shown_from := maxi(0, history.size() - GameState.sparkline_days)
	var population_series: Array = []
	for i in TOWN_POPULATION_SERIES.size():
		var values: Array[float] = []
		for d in range(shown_from, history.size()):
			values.append(float(history[d][TOWN_POPULATION_SERIES[i][1]]))
		population_series.append({"name": TOWN_POPULATION_SERIES[i][0], "values": values, "color": HESparkline.color_for_series(i)})
	_town_population_chart.set_series(population_series)
	var flow_series: Array = []
	for i in TOWN_FLOW_SERIES.size():
		var values: Array[float] = []
		for d in range(shown_from, history.size()):
			var total := 0.0
			for k in range(maxi(0, d - TOWN_FLOW_WINDOW_DAYS + 1), d + 1):
				total += float(history[k][TOWN_FLOW_SERIES[i][1]])
			values.append(total)
		flow_series.append({"name": TOWN_FLOW_SERIES[i][0], "values": values, "color": HESparkline.color_for_series(i)})
	_town_flow_chart.set_series(flow_series)

## Settings button left of Pause: one popup holding the history-length settings.
func _make_settings_button() -> Button:
	var btn := Button.new()
	btn.text = "Settings"
	btn.pressed.connect(_open_settings_dialog)
	return btn

func _open_settings_dialog() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Settings"
	dialog.ok_button_text = "Close"
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 8)
	dialog.add_child(grid)
	var sparkline_box := _add_days_setting(grid, "Sparkline history (days)", GameState.sparkline_days, GameState.MAX_SPARKLINE_DAYS)
	var blotter_box := _add_days_setting(grid, "Blotter history (days)", GameState.blotter_days, GameState.MAX_BLOTTER_DAYS)
	var apply := func(_value: float) -> void:
		GameState.set_history_settings(int(sparkline_box.value), int(blotter_box.value))
	sparkline_box.value_changed.connect(apply)
	blotter_box.value_changed.connect(apply)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()

func _add_days_setting(grid: GridContainer, label_text: String, value: int, max_value: int) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	grid.add_child(label)
	var box := SpinBox.new()
	box.min_value = 1
	box.max_value = max_value
	box.value = value
	grid.add_child(box)
	return box

## The last GameState.sparkline_days entries of a retained history.
func _tail(values: Array) -> Array:
	var keep := GameState.sparkline_days
	return values.slice(values.size() - keep) if values.size() > keep else values

func _on_history_settings_changed() -> void:
	_update_history_titles()
	_set_blotter_minimized(_blotter_minimized)
	_refresh()
	_refresh_blotter()

func _update_history_titles() -> void:
	var days := GameState.sparkline_days
	_town_population_title.text = "Population (last %d days)" % days
	_cash_history_label.text = "Cash (last %d days)" % days
	_goods_title_label.text = "Goods (last %d days)" % days

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
		_blotter_toggle_button.text = "Blotter (%dd) ▸" % GameState.blotter_days
		_blotter_toggle_button.tooltip_text = "Minimize the blotter"
		_blotter_column.custom_minimum_size = Vector2(0, 0)
		_blotter_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_blotter_column.size_flags_stretch_ratio = 1.0

func _on_household_row_selected(household_id: int) -> void:
	_return_stack.clear()
	_clear_person_detail()
	_selected_business_id = -1
	_business_detail_panel.visible = false
	_selected_market_commodity = -1
	_market_detail_panel.visible = false
	_selected_need_id = -1
	_need_detail_panel.visible = false
	_selected_household_id = household_id
	_household_detail_panel.visible = true
	_refresh_household_detail()

func _on_household_detail_close_pressed() -> void:
	_selected_household_id = -1
	_household_detail_panel.visible = false
	_clear_person_detail()
	_return_to_previous_view()

## Rebuilt every refresh; the content is a handful of lines, so there's no
## fixed schema worth updating in place.
func _refresh_household_detail() -> void:
	if _selected_household_id == -1:
		return
	if not _simulation.get_household_ids().has(_selected_household_id):
		# The household died or the scenario reloaded.
		_selected_household_id = -1
		_household_detail_panel.visible = false
		_clear_person_detail()
		return
	var h := _simulation.get_household_summary(_selected_household_id)
	_household_detail_title.text = "Household %d" % _selected_household_id
	for child in _household_detail_content.get_children():
		_household_detail_content.remove_child(child)
		child.queue_free()

	var employer_id: int = h["employer_business_id"]
	var employer_row := HBoxContainer.new()
	var employer_caption := Label.new()
	employer_caption.text = "Employer:"
	employer_row.add_child(employer_caption)
	if _business_names.has(employer_id):
		var employer_link := Button.new()
		employer_link.text = _business_names[employer_id]
		employer_link.flat = true
		employer_link.tooltip_text = "Open employer detail"
		employer_link.pressed.connect(_on_linked_business_pressed.bind(employer_id))
		employer_row.add_child(employer_link)
	else:
		var unemployed := Label.new()
		unemployed.text = "Unemployed"
		employer_row.add_child(unemployed)
	_household_detail_content.add_child(employer_row)

	# TODO: pull names -- members are just numbered by index for now.
	_add_household_detail_heading("Members (%d)" % h["headcount"])
	var member_index := 1
	for age in h["worker_ages"]:
		_add_member_link(member_index, "worker", age)
		member_index += 1
	for age in h["dependent_ages"]:
		_add_member_link(member_index, "dependent", age)
		member_index += 1

	_add_household_detail_heading("Health and morale")
	_add_meter_row(_household_detail_content, "Health", h["health"])
	for loss in h["health_losses"]:
		if loss["loss"] > 0.001:
			_add_household_detail_line("    %s shortfall: -%.0f%% health" % [loss["label"], loss["loss"] * 100.0])
	_add_meter_row(_household_detail_content, "Morale", h["morale"])
	for penalty in h["morale_penalties"]:
		_add_household_detail_line("    %s: -%.0f%% morale" % [penalty["label"], penalty["penalty"] * 100.0])

	_add_household_detail_heading("Events (last %d days)" % HOUSEHOLD_EVENT_HISTORY_DAYS)
	var event_lines: Array[String] = []
	var events := _simulation.get_event_log_days(HOUSEHOLD_EVENT_HISTORY_DAYS)
	for i in range(events.size() - 1, -1, -1):
		if _is_household_event(events[i], _selected_household_id):
			event_lines.append(_format_event(events[i]))
	var events_display := RichTextLabel.new()
	events_display.bbcode_enabled = true
	events_display.fit_content = true
	events_display.scroll_active = false
	events_display.text = "\n".join(event_lines) if not event_lines.is_empty() else "[i]No events in this window.[/i]"
	_household_detail_content.add_child(events_display)

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
		_add_household_detail_line("%s: needs %.2f, met %.2f  |  stress %.2f" % [need["label"], need["required"], need["provided"], need["stress"]])
		for satisfier in need["satisfiers"]:
			if satisfier["consumed"] > 0.0001:
				_add_household_detail_line("    %s used: %.2f" % [satisfier["name"], satisfier["consumed"]])
		if need["stress"] > 0.001:
			var effect := Label.new()
			effect.text = "    " + need["effect"]
			effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			effect.add_theme_color_override("font_color", Color(0.95, 0.6, 0.3))
			_household_detail_content.add_child(effect)

func _add_member_link(member_number: int, role: String, age: int) -> void:
	var link := Button.new()
	link.text = "Member %d: %s, age %s" % [member_number, role, _format_age(age)]
	link.flat = true
	link.alignment = HORIZONTAL_ALIGNMENT_LEFT
	link.tooltip_text = "Open person detail"
	link.pressed.connect(_on_linked_person_pressed.bind(_selected_household_id, member_number))
	_household_detail_content.add_child(link)

## "Label  [bar]  72%" -- 0..1 meters, colored red/amber/green by level.
func _add_meter_row(parent: Control, caption: String, value: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var name_label := Label.new()
	name_label.text = caption
	name_label.custom_minimum_size = Vector2(70, 0)
	row.add_child(name_label)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = value
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(200, 16)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill := StyleBoxFlat.new()
	fill.bg_color = _wellbeing_color(value)
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)
	var value_label := Label.new()
	value_label.text = "%.0f%%" % (value * 100.0)
	row.add_child(value_label)

func _clear_person_detail() -> void:
	_selected_person_household_id = -1
	_selected_person_number = -1
	if _person_detail_panel != null:
		_person_detail_panel.visible = false

func _on_linked_person_pressed(household_id: int, member_number: int) -> void:
	_open_linked(_on_person_selected.bind(household_id, member_number))

func _on_person_selected(household_id: int, member_number: int) -> void:
	_return_stack.clear()
	_selected_business_id = -1
	_business_detail_panel.visible = false
	_selected_market_commodity = -1
	_market_detail_panel.visible = false
	_selected_need_id = -1
	_need_detail_panel.visible = false
	_selected_household_id = -1
	_household_detail_panel.visible = false
	_selected_person_household_id = household_id
	_selected_person_number = member_number
	_person_detail_panel.visible = true
	_refresh_person_detail()

func _on_person_detail_close_pressed() -> void:
	_clear_person_detail()
	_return_to_previous_view()

## Rebuilt every refresh. Everything is derived from the household (see
## HESimulation.get_person_summary) -- members have no identity of their own.
func _refresh_person_detail() -> void:
	if _selected_person_household_id == -1:
		return
	var p := _simulation.get_person_summary(_selected_person_household_id, _selected_person_number)
	if p.is_empty():
		# Household gone, or the member left/died and numbering shifted.
		_clear_person_detail()
		return
	_person_detail_title.text = "Household %d - Member %d" % [p["household_id"], p["member_number"]]
	for child in _person_detail_content.get_children():
		_person_detail_content.remove_child(child)
		child.queue_free()

	var household_row := HBoxContainer.new()
	var household_caption := Label.new()
	household_caption.text = "Household:"
	household_row.add_child(household_caption)
	var household_link := Button.new()
	household_link.text = "Household %d" % p["household_id"]
	household_link.flat = true
	household_link.tooltip_text = "Open household detail"
	household_link.pressed.connect(_on_linked_household_pressed.bind(p["household_id"]))
	household_row.add_child(household_link)
	_person_detail_content.add_child(household_row)

	_add_person_line("%s, %s, age %s" % [p["role"], p["life_stage"].to_lower(), _format_age(p["age_days"])])
	_add_person_line(p["note"])
	if p["role"] == "Worker":
		var employer_id: int = p["employer_business_id"]
		if _business_names.has(employer_id):
			var employer_row := HBoxContainer.new()
			var employer_caption := Label.new()
			employer_caption.text = "Employer:"
			employer_row.add_child(employer_caption)
			var employer_link := Button.new()
			employer_link.text = _business_names[employer_id]
			employer_link.flat = true
			employer_link.tooltip_text = "Open employer detail"
			employer_link.pressed.connect(_on_linked_business_pressed.bind(employer_id))
			employer_row.add_child(employer_link)
			_person_detail_content.add_child(employer_row)
		else:
			_add_person_line("Employer: unemployed")
	if p["vulnerability"] > 1.0:
		_add_person_line("Vulnerable (%s): shortfalls hit %.0f%% harder." % [p["life_stage"].to_lower(), (p["vulnerability"] - 1.0) * 100.0])

	_add_person_heading("Health and morale")
	_add_meter_row(_person_detail_content, "Health", p["health"])
	_add_meter_row(_person_detail_content, "Morale", p["morale"])
	for penalty in p["morale_penalties"]:
		_add_person_line("    %s: -%.0f%% morale" % [penalty["label"], penalty["penalty"] * 100.0])

	_add_person_heading("Needs (today, equal share of the household's)")
	for need in p["needs"]:
		_add_person_line("%s: needs %.2f, met %.2f  |  stress %.2f  |  health -%.0f%%" % [
			need["label"], need["required"], need["provided"], need["stress"], need["health_loss"] * 100.0])
		if need["stress"] > 0.001:
			var effect := Label.new()
			effect.text = "    " + need["effect"]
			effect.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			effect.add_theme_color_override("font_color", Color(0.95, 0.6, 0.3))
			_person_detail_content.add_child(effect)

func _add_person_heading(value: String) -> void:
	var heading := Label.new()
	heading.text = value
	heading.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_person_detail_content.add_child(heading)

func _add_person_line(value: String) -> void:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_person_detail_content.add_child(label)

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
	_return_stack.clear()
	_selected_market_commodity = -1
	_market_detail_panel.visible = false
	_selected_need_id = -1
	_need_detail_panel.visible = false
	_selected_household_id = -1
	_household_detail_panel.visible = false
	_clear_person_detail()
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

## Link handlers: open a detail view from inside another one, remembering the
## current view so closing returns to it (no visual stacking).
func _on_linked_business_pressed(business_id: int) -> void:
	_open_linked(_on_business_row_selected.bind(business_id))

func _on_linked_household_pressed(household_id: int) -> void:
	_open_linked(_on_household_row_selected.bind(household_id))

func _open_linked(open_view: Callable) -> void:
	var stack := _return_stack.duplicate()
	if _market_detail_panel.visible:
		stack.append(_on_market_row_selected.bind(_selected_market_commodity))
	elif _business_detail_panel.visible:
		stack.append(_on_business_row_selected.bind(_selected_business_id))
	elif _household_detail_panel.visible:
		stack.append(_on_household_row_selected.bind(_selected_household_id))
	elif _person_detail_panel.visible:
		stack.append(_on_person_selected.bind(_selected_person_household_id, _selected_person_number))
	elif _need_detail_panel.visible:
		stack.append(_on_need_row_selected.bind(_selected_need_id))
	open_view.call()
	_return_stack.assign(stack)

## After a detail panel closes: reopen the view it was linked from, if any.
func _return_to_previous_view() -> void:
	if _return_stack.is_empty():
		return
	var back: Callable = _return_stack.pop_back()
	var rest := _return_stack.duplicate()
	back.call()
	_return_stack.assign(rest)

func _on_business_detail_close_pressed() -> void:
	_selected_business_id = -1
	_business_detail_panel.visible = false
	_return_to_previous_view()

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

## Needs tab (just before Goods): one row per household need, in the order
## the player thinks of them. Clicking a name opens that need's detail panel.
func _build_needs_tab(top_tabs: TabContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Needs"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	top_tabs.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for col_label in ["Need", "Households met", "Households unmet", "Demand unmet"]:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)
	for need_id in NEEDS_TAB_ORDER:
		var need := HENeeds.get_need(need_id)
		var name_button := Button.new()
		name_button.text = need.label
		name_button.flat = true
		name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_button.custom_minimum_size = Vector2(90, 20)
		name_button.pressed.connect(_on_need_row_selected.bind(need_id))
		grid.add_child(name_button)
		var labels := {}
		for key in ["met", "unmet", "unmet_demand"]:
			var value_label := Label.new()
			value_label.custom_minimum_size = Vector2(130, 0)
			value_label.add_theme_color_override("font_color", Color(0.6, 0.75, 0.9))
			grid.add_child(value_label)
			labels[key] = value_label
		_need_labels[need_id] = labels

func _refresh_needs_tab() -> void:
	for need_id in _need_labels.keys():
		var detail := _simulation.get_need_detail(need_id, 0)
		var labels: Dictionary = _need_labels[need_id]
		(labels["met"] as Label).text = "%d" % detail["households_met"]
		(labels["unmet"] as Label).text = "%d" % detail["households_unmet"]
		(labels["unmet_demand"] as Label).text = "%.1f" % detail["unmet"]

func _on_need_row_selected(need_id: int) -> void:
	_return_stack.clear()
	_selected_business_id = -1
	_business_detail_panel.visible = false
	_selected_market_commodity = -1
	_market_detail_panel.visible = false
	_selected_household_id = -1
	_household_detail_panel.visible = false
	_clear_person_detail()
	_selected_need_id = need_id
	_need_detail_panel.visible = true
	_refresh_need_detail()

func _on_need_detail_close_pressed() -> void:
	_selected_need_id = -1
	_need_detail_panel.visible = false
	_return_to_previous_view()

## Rebuilt every refresh, like the market detail. Reports households meeting
## vs missing the need, the stress/emigration risk (food only -- the other
## needs don't feed the lifecycle engine yet), and a chart of demand met per
## satisfier against demand left unmet.
func _refresh_need_detail() -> void:
	if _selected_need_id == -1:
		return
	var detail := _simulation.get_need_detail(_selected_need_id, GameState.sparkline_days)
	_need_detail_title.text = "%s need" % detail["label"]
	for child in _need_detail_content.get_children():
		_need_detail_content.remove_child(child)
		child.queue_free()

	var household_count: int = detail["households_met"] + detail["households_unmet"]
	_add_need_detail_line("Households satisfying this need: %d of %d  |  unable to: %d" % [
		detail["households_met"], household_count, detail["households_unmet"]])
	if detail["drives_lifecycle"]:
		_add_need_detail_line("Stress among unsatisfied households: %.2f (0-1)  |  with migration pressure: %d  |  at risk of emigrating: %d (%.0f%% of households)" % [
			detail["avg_stress_unmet"], detail["households_with_migration_pressure"],
			detail["households_emigration_candidates"], detail["emigration_likelihood"] * 100.0])
	else:
		_add_need_detail_line("Stress and emigration: only food shortfalls cause emigration. Unmet %s still builds stress, which lowers health and morale (see household and person pages)." % detail["label"].to_lower())

	var required: float = detail["required"]
	_add_need_detail_line("Demand today: %.2f need units" % required)
	for name in detail["met_by"].keys():
		_add_need_met_by_line(name, "%.2f (%s)" % [detail["met_by"][name], _percent_of(detail["met_by"][name], required)])
	_add_need_detail_line("   Unmet: %.2f (%s)" % [detail["unmet"], _percent_of(detail["unmet"], required)])

	var series: Array = []
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	_need_detail_content.add_child(header)
	var title := Label.new()
	title.text = "Demand met and unmet (last %d days)" % GameState.sparkline_days
	title.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	header.add_child(title)
	var index := 0
	for name in detail["met_history"].keys():
		series.append({"name": name, "values": detail["met_history"][name], "color": HESparkline.color_for_series(index)})
		index += 1
	series.append({"name": "Unmet", "values": detail["unmet_history"], "color": NEED_UNMET_COLOR})
	for entry in series:
		var legend := Label.new()
		legend.text = entry["name"]
		legend.add_theme_color_override("font_color", entry["color"])
		header.add_child(legend)
	var chart := HESparkline.new()
	chart.custom_minimum_size = Vector2(0, 80)
	chart.show_max_label = true
	chart.set_series(series)
	_need_detail_content.add_child(chart)

## "Met by <good>: ..." with the good's name opening its market detail when it
## has one.
func _add_need_met_by_line(good_name: String, amount_text: String) -> void:
	var commodity := Commodity.type_from_name(good_name)
	if commodity == -1 or not _known_market_commodities.has(good_name):
		_add_need_detail_line("   Met by %s: %s" % [good_name, amount_text])
		return
	var line := HBoxContainer.new()
	var prefix := Label.new()
	prefix.text = "   Met by"
	line.add_child(prefix)
	var link := Button.new()
	link.text = good_name
	link.flat = true
	link.tooltip_text = "Open %s market" % good_name
	link.pressed.connect(_on_linked_market_pressed.bind(commodity))
	line.add_child(link)
	var rest := Label.new()
	rest.text = ": " + amount_text
	line.add_child(rest)
	_need_detail_content.add_child(line)

func _percent_of(part: float, whole: float) -> String:
	return "%.0f%%" % (part / whole * 100.0) if whole > 0.0 else "-"

func _add_need_detail_line(value: String) -> void:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_need_detail_content.add_child(label)

func _on_market_row_selected(commodity: int) -> void:
	_return_stack.clear()
	_selected_business_id = -1
	_business_detail_panel.visible = false
	_selected_need_id = -1
	_need_detail_panel.visible = false
	_selected_household_id = -1
	_household_detail_panel.visible = false
	_clear_person_detail()
	_selected_need_id = -1
	_need_detail_panel.visible = false
	_selected_market_commodity = commodity
	_market_detail_panel.visible = true
	_refresh_market_detail()

func _on_market_detail_close_pressed() -> void:
	_selected_market_commodity = -1
	_market_detail_panel.visible = false
	_return_to_previous_view()

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
	_add_market_detail_line("Posted price %.2f  |  Last clearing (all buyers): offered %.1f, affordable requests %.1f, traded %.1f" % [
		report["price"], clearing.get("total_offered", 0.0),
		clearing.get("total_requested_funded", 0.0), clearing.get("quantity_traded", 0.0)])
	var household: Dictionary = report["household_demand"]
	_add_market_detail_line("Households: %.1f wanted for stock  |  %.1f affordable  |  %.1f bought" % [
		household["wanted"], household["funded"], household["bought"]])
	var need: Dictionary = report["need"]
	if not need.is_empty() and not (need["required_history"] as Array).is_empty():
		_add_market_detail_line("%s need (all %s, counted once): %.1f required, %.1f provided (latest day)" % [
			need["label"], "/".join(need["satisfiers"]), need["required_history"].back(), need["provided_history"].back()])
	_add_market_detail_chart(report)
	_add_market_detail_line("Potential buyers: %d  |  Potential sellers: %d" % [report["buyers"].size(), report["sellers"].size()])
	_add_market_detail_line("Requests and offers estimate the next clearing; affordable does not mean purchased.")
	_add_market_detail_section("Buyers", report["buyers"], "requested", "funded")
	_add_market_detail_section("Sellers", report["sellers"], "offered", "stock")
	_add_market_detail_section("Stored quantities", report["holdings"], "quantity", "")

## Last 90 days of supplied (offered) vs. requested (affordable) quantity on
## one shared axis, with a color-keyed legend. Rebuilt with the rest of the
## detail content each refresh.
func _add_market_detail_chart(report: Dictionary) -> void:
	var supplied_color := HESparkline.color_for_series(0)
	var requested_color := HESparkline.color_for_series(1)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	_market_detail_content.add_child(header)
	var title := Label.new()
	title.text = "Supply and demand (last %d days)" % GameState.sparkline_days
	title.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	header.add_child(title)
	var wanted_color := HESparkline.color_for_series(2)
	var bought_color := HESparkline.color_for_series(3)
	var requested_name := "Affordable requests (incl. export capacity)" if _market_chart_export_appetite else "Affordable requests"
	var requested_history: Array = report["demanded_with_export_history"] if _market_chart_export_appetite else report["demanded_history"]
	for entry in [["Supplied", supplied_color], [requested_name, requested_color],
			["Households wanted", wanted_color], ["Households bought", bought_color]]:
		var legend := Label.new()
		legend.text = entry[0]
		legend.add_theme_color_override("font_color", entry[1])
		header.add_child(legend)
	var chart := HESparkline.new()
	chart.custom_minimum_size = Vector2(0, 60)
	chart.show_max_label = true
	chart.set_series([
		{"name": "Supplied", "values": _tail(report["supplied_history"]), "color": supplied_color},
		{"name": "Affordable requests", "values": _tail(requested_history), "color": requested_color},
		{"name": "Households wanted", "values": _tail(report["household_wanted_history"]), "color": wanted_color},
		{"name": "Households bought", "values": _tail(report["household_bought_history"]), "color": bought_color},
	])
	_market_detail_content.add_child(chart)

func _on_market_export_appetite_toggled(enabled: bool) -> void:
	_market_chart_export_appetite = enabled
	_refresh_market_detail()

func _add_market_detail_line(value: String) -> void:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_market_detail_content.add_child(label)

## A name that opens the business's detail pane when the row has a business_id,
## otherwise plain text.
func _add_market_owner_line(row: Dictionary, text_after_owner: String) -> void:
	if not row.has("business_id"):
		_add_market_detail_line("%s%s" % [row["owner"], text_after_owner])
		return
	var line := HBoxContainer.new()
	var link := Button.new()
	link.text = row["owner"]
	link.flat = true
	link.tooltip_text = "Open this business's detail"
	link.pressed.connect(_on_linked_business_pressed.bind(row["business_id"]))
	line.add_child(link)
	var rest := Label.new()
	rest.text = text_after_owner
	line.add_child(rest)
	_market_detail_content.add_child(line)

func _add_market_detail_section(title: String, rows: Array, quantity_key: String, secondary_key: String) -> void:
	var heading := Label.new()
	heading.text = "%s (%d)" % [title, rows.size()]
	heading.add_theme_font_size_override("font_size", 14)
	_market_detail_content.add_child(heading)
	if rows.is_empty():
		_add_market_detail_line("None")
		return
	var household_rows: Array = rows.filter(func(r): return r.get("kind", "") == "household")
	if not household_rows.is_empty():
		_add_market_detail_line(_household_summary_line(household_rows, quantity_key, secondary_key))
	for row in rows:
		if row.get("kind", "") == "household":
			continue
		if row.get("kind", "") == "export":
			_add_market_owner_line(row, ": up to %.1f shared export capacity  |  %.1f exportable from this seller now" % [
				row["capacity"], row["available"]])
			continue
		if row.get("kind", "") == "import":
			_add_market_owner_line(row, ": up to %.1f shared import capacity  |  no stored stock" % row["capacity"])
			continue
		var line := ": %.1f %s" % [row[quantity_key], quantity_key]
		if secondary_key != "":
			var secondary_label := "affordable" if secondary_key == "funded" else secondary_key
			line += "  |  %.1f %s" % [row[secondary_key], secondary_label]
		_add_market_owner_line(row, line)

## One line standing in for every household row: count, average quantity, and
## (for buyers) average affordable plus how many can't afford their full request.
func _household_summary_line(rows: Array, quantity_key: String, secondary_key: String) -> String:
	var count := rows.size()
	var total := 0.0
	var total_secondary := 0.0
	var unaffordable := 0
	for row in rows:
		total += row[quantity_key]
		if secondary_key != "":
			total_secondary += row[secondary_key]
			if secondary_key == "funded" and row[secondary_key] < row[quantity_key] - 0.0001:
				unaffordable += 1
	var line := "%d households: avg %.1f %s" % [count, total / count, quantity_key]
	if secondary_key == "funded":
		line += "  |  avg %.1f affordable  |  %d cannot afford full request" % [total_secondary / count, unaffordable]
	elif secondary_key != "":
		line += "  |  avg %.1f %s" % [total_secondary / count, secondary_key]
	return line

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
	_business_detail_sparkline.set_data(_tail(report["balance_history"]))
	_refresh_business_flow_chart(report)

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

## Built once (not per refresh) so the tab buttons stay clickable.
func _build_flow_chart(parent: Control) -> Dictionary:
	var section := VBoxContainer.new()
	parent.add_child(section)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	section.add_child(header)
	var title_label := Label.new()
	_goods_title_label = title_label
	title_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	header.add_child(title_label)
	var tab_group := ButtonGroup.new()
	for view_index in FLOW_VIEWS.size():
		var tab := Button.new()
		tab.text = FLOW_VIEWS[view_index]["label"]
		tab.toggle_mode = true
		tab.button_group = tab_group
		tab.button_pressed = view_index == _business_flow_view
		tab.pressed.connect(_on_business_flow_view_pressed.bind(view_index))
		header.add_child(tab)
	var legend := HFlowContainer.new()
	legend.add_theme_constant_override("h_separation", 12)
	legend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(legend)
	var chart := HESparkline.new()
	chart.custom_minimum_size = Vector2(0, 60)
	chart.show_max_label = true
	section.add_child(chart)
	return {"section": section, "legend": legend, "chart": chart}

func _on_business_flow_view_pressed(view_index: int) -> void:
	_business_flow_view = view_index
	_refresh_business_detail()

## Only PRODUCTION businesses report flow_history (traders and herds produce
## nothing through a recipe), so the chart hides for the rest. One line per
## good on a shared axis. The legend entries are buttons that hide or show
## their line; colors are assigned over ALL of a view's lines so hiding one
## never recolors the rest.
func _refresh_business_flow_chart(report: Dictionary) -> void:
	var flow_history: Dictionary = report.get("flow_history", {})
	var view: Dictionary = FLOW_VIEWS[_business_flow_view]
	var all_series: Array = []
	_flow_series_names = []
	for series_def in view["series"]:
		for entry in flow_history.get(series_def[0], []):
			var series_name := "%s %s" % [entry["commodity"], series_def[1]]
			var details: Array = []
			for detail_def in view.get("details", []):
				for detail_entry in flow_history.get(detail_def[0], []):
					if detail_entry["commodity"] == entry["commodity"]:
						details.append({"name": detail_def[1], "values": _tail(detail_entry["values"])})
			all_series.append({"name": series_name, "values": _tail(entry["values"]), "color": HESparkline.color_for_series(all_series.size()), "dashed": series_def[2], "details": details})
			_flow_series_names.append(series_name)

	var hidden := _effective_hidden_flow_series()
	var shown: Array = []
	for s in all_series:
		if not hidden.has(s["name"]):
			shown.append(s)

	# The legend is only rebuilt when it would actually change, never on a
	# plain daily refresh -- recreating buttons mid-click would split the
	# mouse-down and mouse-up across different instances (see the building
	# upgrade buttons in hud.gd).
	var legend: Container = _business_detail_flow_chart["legend"]
	var legend_key := "|".join(_flow_series_names) + "#" + "|".join(hidden.keys())
	if legend_key != _flow_legend_key:
		_flow_legend_key = legend_key
		for child in legend.get_children():
			legend.remove_child(child)
			child.queue_free()
		for s in all_series:
			var is_hidden: bool = hidden.has(s["name"])
			var color: Color = s["color"]
			var shown_color := color if not is_hidden else Color(color, 0.35)
			var toggle := Button.new()
			toggle.text = s["name"]
			toggle.flat = true
			toggle.tooltip_text = "Click to %s this line" % ("show" if is_hidden else "hide")
			for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
				toggle.add_theme_color_override(color_name, shown_color)
			# The only visible line can't be hidden: no empty chart.
			if not is_hidden and shown.size() == 1:
				toggle.disabled = true
				toggle.tooltip_text = "At least one line stays visible"
			toggle.pressed.connect(_on_business_flow_series_toggled.bind(s["name"]))
			legend.add_child(toggle)

	(_business_detail_flow_chart["section"] as Control).visible = not flow_history.is_empty() and not all_series.is_empty()
	(_business_detail_flow_chart["chart"] as HESparkline).set_series(shown)

## Names hidden in the current view. Hidden choices are remembered by series
## name across business selections, but if they would hide every line of the
## business being shown they're ignored, so the chart is never empty.
func _effective_hidden_flow_series() -> Dictionary:
	var hidden := {}
	for series_name in _flow_series_names:
		if _business_flow_hidden.has(series_name):
			hidden[series_name] = true
	if hidden.size() >= _flow_series_names.size():
		return {}
	return hidden

func _on_business_flow_series_toggled(series_name: String) -> void:
	var hidden := _effective_hidden_flow_series()
	if hidden.has(series_name):
		_business_flow_hidden.erase(series_name)
	elif _flow_series_names.size() - hidden.size() > 1:
		_business_flow_hidden[series_name] = true
	_refresh_business_detail()

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
			box.add_child(_inline_goods_cell(part[1]) if part.size() > 2 and part[2] else _goods_cell(part[0], part[1], 0.0, true))
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
## link_to_market makes the text a button opening that good's market detail
## (only when the good actually has a market).
func _goods_cell(commodity_name: String, text: String, min_width: float = 0.0, link_to_market: bool = false) -> HBoxContainer:
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
	if link_to_market and commodity != -1 and _known_market_commodities.has(commodity_name):
		var link := Button.new()
		link.text = text
		link.flat = true
		link.alignment = HORIZONTAL_ALIGNMENT_LEFT
		link.tooltip_text = "Open %s market" % commodity_name
		link.pressed.connect(_on_linked_market_pressed.bind(commodity))
		box.add_child(link)
		return box
	var label := Label.new()
	label.text = text
	box.add_child(label)
	return box

func _on_linked_market_pressed(commodity: int) -> void:
	_open_linked(_on_market_row_selected.bind(commodity))

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
			_format_day(transaction["day"]),
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
			_format_day(event["day"]),
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
		var household_link := Button.new()
		household_link.text = str(household_id)
		household_link.flat = true
		household_link.alignment = HORIZONTAL_ALIGNMENT_LEFT
		household_link.tooltip_text = "Open household detail"
		household_link.pressed.connect(_on_linked_household_pressed.bind(household_id))
		_business_detail_employee_grid.add_child(household_link)
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

	var create_button := MenuButton.new()
	create_button.text = "Create business ▾"
	create_button.flat = false
	create_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	create_button.tooltip_text = "Build a new business in the town. Free and instant; each kind can only be built once."
	var create_popup := create_button.get_popup()
	var buildable := HEScenarioSeeds.business_types()
	for i in buildable.size():
		var option: Dictionary = buildable[i]
		var already_built := _simulation.has_business_of_type(_town_settlement_id(), option["type_key"])
		create_popup.add_item("%s (already built)" % option["label"] if already_built else option["label"], i)
		create_popup.set_item_disabled(i, already_built)
	create_popup.id_pressed.connect(_on_create_business_pressed)
	_business_list.add_child(create_button)
	_rebuild_job_rows()

func _town_settlement_id() -> int:
	return _simulation.get_settlement_ids()[0]

func _on_create_business_pressed(index: int) -> void:
	var option: Dictionary = HEScenarioSeeds.business_types()[index]
	var settlement_id := _town_settlement_id()
	if _simulation.has_business_of_type(settlement_id, option["type_key"]):
		return
	var business: HEBusiness = option["make"].call(_simulation.next_business_id(), settlement_id)
	_simulation.add_new_business(business)
	_business_names[business.id] = business.name
	_rebuild_business_rows()
	_refresh()

## One row per business (not per household): target capacity, max capacity and
## how many workers are employed. Filled in by _refresh_job_rows.
func _rebuild_job_rows() -> void:
	for child in _jobs_list.get_children():
		_jobs_list.remove_child(child)
		child.queue_free()
	_job_rows.clear()
	_job_totals.clear()

	var grid := GridContainer.new()
	grid.columns = 5
	_jobs_list.add_child(grid)
	for col_label in ["Business", "Employed", "Target", "Max capacity", "Open (vs max)"]:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)

	for report in _simulation.get_business_reports():
		var business_id: int = report["business_id"]
		var name_button := Button.new()
		name_button.custom_minimum_size = Vector2(110, 0)
		name_button.flat = true
		name_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_button.pressed.connect(_on_business_row_selected.bind(business_id))
		grid.add_child(name_button)
		var labels := {"name": name_button}
		for key in ["employed", "capacity", "max_capacity", "open"]:
			var label := Label.new()
			label.custom_minimum_size = Vector2(90, 0)
			grid.add_child(label)
			labels[key] = label
		_job_rows[business_id] = labels

	var total_name := Label.new()
	total_name.text = "Total"
	total_name.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	grid.add_child(total_name)
	for key in ["employed", "capacity", "max_capacity", "open"]:
		var label := Label.new()
		label.custom_minimum_size = Vector2(90, 0)
		label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(label)
		_job_totals[key] = label

	_unemployed_label = Label.new()
	_unemployed_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_jobs_list.add_child(_unemployed_label)

func _refresh_job_rows() -> void:
	var total_employed := 0
	var total_capacity := 0
	var total_max := 0
	for report in _simulation.get_business_reports():
		total_employed += report["employed_workers"]
		total_capacity += report["capacity"]
		total_max += report["max_capacity"]
		var row: Dictionary = _job_rows.get(report["business_id"], {})
		if row.is_empty():
			continue
		(row["name"] as Button).text = report["name"]
		(row["employed"] as Label).text = str(report["employed_workers"])
		(row["capacity"] as Label).text = str(report["capacity"])
		(row["max_capacity"] as Label).text = str(report["max_capacity"])
		(row["open"] as Label).text = str(maxi(report["max_capacity"] - report["employed_workers"], 0))
	if _job_totals.is_empty():
		return
	(_job_totals["employed"] as Label).text = str(total_employed)
	(_job_totals["capacity"] as Label).text = str(total_capacity)
	(_job_totals["max_capacity"] as Label).text = str(total_max)
	(_job_totals["open"] as Label).text = str(maxi(total_max - total_employed, 0))

	# Workers in households with no employer, against the jobs businesses are
	# currently trying to fill (target minus employed). Red when both exist at
	# once -- people without work while jobs sit open.
	var unemployed_workers := 0
	var unemployed_households := 0
	for household_id in _simulation.get_household_ids():
		var h := _simulation.get_household_summary(household_id)
		if _business_names.has(h["employer_business_id"]):
			continue
		unemployed_households += 1
		unemployed_workers += h["worker_capacity"]
	var open_targets := maxi(total_capacity - total_employed, 0)
	_unemployed_label.text = "Unemployed: %d workers (%d households)  |  %d openings at current targets" % [unemployed_workers, unemployed_households, open_targets]
	_unemployed_label.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5) if unemployed_workers > 0 and open_targets > 0 else Color(0.75, 0.75, 0.8))

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

		var employer_label := Button.new()
		employer_label.flat = true
		employer_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
		employer_label.custom_minimum_size = Vector2(80, 0)
		employer_label.pressed.connect(_on_household_employer_pressed.bind(household_id))
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

## Top-line government treasury and its 30-day movement (tooltip).
func _refresh_treasury() -> void:
	var summary := _simulation.get_treasury_summary(TREASURY_TREND_DAYS)
	_treasury_margin.visible = summary["has_government"]
	if not summary["has_government"]:
		_treasury_tip.visible = false
		return
	_treasury_label.text = "%.0f gold" % summary["treasury"]
	var covered: int = summary["days_covered"]
	var tip := "Government treasury"
	if covered <= 0:
		tip += "\nNo history yet."
	else:
		var change: float = summary["change"]
		tip += "\n%+.1f gold over the last %d days" % [change, covered]
		tip += "\n(%.1f -> %.1f)" % [summary["then"], summary["treasury"]]
	_treasury_tip_label.text = tip
	_treasury_tip.reset_size() # shrink back to fit when the text gets shorter

func _on_treasury_hover(hovering: bool) -> void:
	_treasury_tip.visible = hovering
	if hovering:
		_refresh_treasury()
		_treasury_tip.global_position = _treasury_box.global_position + Vector2(0, _treasury_box.size.y + 6)

func _on_household_employer_pressed(household_id: int) -> void:
	var employer_id: int = _simulation.get_household_summary(household_id)["employer_business_id"]
	if _business_names.has(employer_id):
		_on_business_row_selected(employer_id)

func _refresh() -> void:
	var clock := _simulation.get_clock_summary()
	_day_label.text = _format_day(clock["day"])
	_refresh_treasury()
	_refresh_population_summary()

	_refresh_town()

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
	# The detail panels below are rebuilt from scratch, link buttons included. At
	# high speed this runs nearly every frame, which would swap a button out
	# between mouse-down and mouse-up and eat the click, so hold off while a
	# mouse button is down; the next refresh catches up.
	var mouse_down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not mouse_down:
		_refresh_market_detail()
	_refresh_needs_tab()
	if not mouse_down:
		_refresh_need_detail()

	# A business that failed (or was created) changes the set of rows and the
	# Create business menu's "already built" state; rebuild rather than leave a
	# frozen row for a business that no longer exists.
	var reports := _simulation.get_business_reports()
	var rows_stale := reports.size() != _business_rows.size()
	for report in reports:
		if not _business_rows.has(report["business_id"]):
			rows_stale = true
	if rows_stale:
		_rebuild_business_rows()
	for report in reports:
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
		elif report["kind"] == "government":
			var gov_text := "Treasury %.1f · tax today %.2f (%.0f%% sales tax)" % [report["treasury"], report["last_tax_collected"], report["sales_tax_rate"] * 100.0]
			status_label.text = gov_text
			status_label.tooltip_text = "%s\n\nSales tax on every local sale pays the administrator; builder jobs are not modeled yet." % gov_text
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

	_refresh_job_rows()

	if _selected_business_id != -1 and not mouse_down:
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
		var employer_button := row["employer"] as Button
		employer_button.text = _business_names.get(h["employer_business_id"], "Unemployed")
		employer_button.disabled = not _business_names.has(h["employer_business_id"])
		employer_button.tooltip_text = "Open employer detail" if not employer_button.disabled else ""
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

	if not mouse_down:
		_refresh_household_detail()
		_refresh_person_detail()
	_refresh_blotter()

## Newest event first, since that's what a player checking in on the city
## cares about seeing without scrolling.
func _refresh_blotter() -> void:
	var events := _simulation.get_event_log_days(GameState.blotter_days)
	var lines: Array[String] = []
	for i in range(events.size() - 1, -1, -1):
		if not _blotter_filter_enabled.get(events[i]["type"], true):
			continue
		lines.append(_format_event(events[i]))
	if lines.is_empty():
		_blotter_display.text = "[i]No events match the active filters.[/i]"
		return
	_blotter_display.text = "\n".join(lines)

## Day 456 -> "Year 1, Day 91". Within the first year, just "Day N".
func _format_day(day: int) -> String:
	var year := day / 365
	if year <= 0:
		return "Day %d" % day
	return "Year %d, Day %d" % [year, day % 365]

## 456 days -> "1 years 91 days". Ages are durations, so unlike _format_day
## the year is always shown.
func _format_age(age_days: int) -> String:
	return "%d years %d days" % [age_days / 365, age_days % 365]

## Household-detail events: life events only (births, deaths, leaving, splits,
## adoptions); hiring/firing and herd events stay on the main blotter.
func _is_household_event(event: Dictionary, household_id: int) -> bool:
	match event["type"]:
		"birth", "old_age", "emigrate":
			return event["household_id"] == household_id
		"split":
			return event["parent_household_id"] == household_id or event["new_household_id"] == household_id
		"adopted":
			return event["household_id"] == household_id or event["adopting_household_id"] == household_id
	return false

func _format_event(event: Dictionary) -> String:
	var day: String = _format_day(event["day"])
	match event["type"]:
		"birth":
			return "[color=#8fd98f]%s - Household %d: birth[/color]" % [day, event["household_id"]]
		"emigrate":
			var suffix := " - household ended" if event["household_ended"] else ""
			return "[color=#e08d8d]%s - Household %d: %s emigrated (starvation)%s[/color]" % [day, event["household_id"], event["member_type"], suffix]
		"old_age":
			var count: int = event["count"]
			var plural := "s" if count != 1 else ""
			return "[color=#a0a0a0]%s - Household %d: %d worker%s died of old age[/color]" % [day, event["household_id"], count, plural]
		"adopted":
			var dep_count: int = event["dependents"]
			var dep_plural := "s" if dep_count != 1 else ""
			return "[color=#a0a0a0]%s - Household %d dissolved: %d dependent%s adopted by Household %d[/color]" % [day, event["household_id"], dep_count, dep_plural, event["adopting_household_id"]]
		"split":
			return "[color=#8db4e0]%s - Household %d split: Member %d left to found Household %d[/color]" % [day, event["parent_household_id"], event["member_number"], event["new_household_id"]]
		"coming_of_age":
			return "[color=#d9c98f]%s - Household %d: member came of age[/color]" % [day, event["household_id"]]
		"job":
			var employer: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			return "[color=#8fd9d0]%s - Household %d: hired by %s[/color]" % [day, event["household_id"], employer]
		"herd_birth":
			var ranch: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			var condition := "" if event["fed"] else " (overgrazed)"
			return "[color=#8fd98f]%s - %s: %.1f born, %.1f died%s, %.0f%% care (herd now %.0f)[/color]" % [day, ranch, event["born"], event["died"], condition, event["care"] * 100.0, event["herd_after"]]
		"herd_cull":
			var culling_ranch: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			return "[color=#d9c98f]%s - %s: culled %.1f head for sale (herd now %.0f)[/color]" % [day, culling_ranch, event["head"], event["herd_after"]]
		"hardship_butcher":
			var owner_name: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			return "[color=#e0b080]%s - %s: hardship butchering, sold %.1f head for %.1f to cover a %.1f wage shortfall (herd now %.0f)[/color]" % [
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
			return "[color=#e09a8d]%s - Household %d: laid off by %s (%s; target %d→%d)[/color]" % [day, event["household_id"], employer, reason, event["old_capacity"], event["new_capacity"]]
		"business_failed":
			var failed_plural := "s" if event["households_laid_off"] != 1 else ""
			return "[color=#e07070]%s - %s failed: credit limit reached, %.1f debt written off, %d household%s laid off[/color]" % [
				day, event["name"], event["debt"], event["households_laid_off"], failed_plural]
		_:
			return "%s - %s" % [day, event["type"]]
