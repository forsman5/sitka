class_name HEPresenter
extends RefCounted

## Decides WHEN the household dashboard presents and WHICH groups need it.
## Pure bookkeeping -- no nodes, no simulation access -- so the cadence and
## visibility policy can be tested and changed without touching the UI.
##
## Model:
## - Simulating days raises `revision`. The dashboard presents when a
##   revision has not yet been presented AND at least `interval_seconds` of
##   wall time has passed since the last presentation. Skipped intermediate
##   revisions are never queued; one presentation shows the latest state.
## - Every revision (and every explicit request) marks all groups dirty.
##   Presenting takes only the groups the view says are visible
##   (take_visible); a hidden group stays dirty, costs nothing, and refreshes
##   once the first time it is visible again.
## - Pause, player commands, and selection changes call request_immediate(),
##   which makes the next due() true regardless of the interval.
##
## interval_seconds == 0.0 presents on every revision, matching the
## dashboard's behavior from before the presenter existed.

## Refresh groups, in the dashboard's presentation order. Each is owned by one
## view that can be hidden independently: a top-level tab page, a list tab
## page, a detail panel, the town map, or the blotter. The BUSINESS_DETAIL_*
## groups are the tabs of the business detail page.
enum Group {
	HEADER,
	TOWN_STATS,
	HOUSING,
	MARKET,
	MARKET_DETAIL,
	NEEDS,
	NEED_DETAIL,
	TOWN_VIEW,
	BUSINESS_ROWS,
	JOBS,
	BUSINESS_DETAIL_HEADER,
	BUSINESS_DETAIL_CASH,
	BUSINESS_DETAIL_STOCKS,
	BUSINESS_DETAIL_PRODUCTIVITY,
	BUSINESS_DETAIL_EVENTS,
	HOUSEHOLDS,
	HOUSEHOLD_DETAIL,
	PERSON_DETAIL,
	BLOTTER,
}

var interval_seconds := 0.0
var revision := 0
var presented_revision := 0

var _elapsed := 0.0
var _force := false
var _dirty: Dictionary = {}

func _init(p_interval_seconds: float = 0.0) -> void:
	interval_seconds = p_interval_seconds
	_mark_all_dirty()

## Authoritative state advanced by `days` simulated days.
func note_simulated(days: int = 1) -> void:
	if days <= 0:
		return
	revision += 1
	_mark_all_dirty()

## Something the player did (or a pause) needs to show on the next frame.
func request_immediate() -> void:
	_force = true
	_mark_all_dirty()

func mark_dirty(group: Group) -> void:
	_dirty[group] = true

## Call once per frame with the wall-clock frame time. True when the dashboard
## should present now.
func due(delta: float) -> bool:
	_elapsed += delta
	if _force:
		return true
	if revision == presented_revision:
		return false
	return _elapsed >= interval_seconds

## Consumes and returns every dirty group; records the presentation.
func take_dirty() -> Array:
	return take_visible(func(_group: int) -> bool: return true)

## Consumes and returns only the dirty groups for which `is_visible(group)` is
## true, in presentation order. Hidden groups stay dirty. Records the
## presentation either way, so a hidden group never keeps the dashboard
## "behind".
func take_visible(is_visible: Callable) -> Array:
	var groups := _dirty.keys()
	groups.sort()
	var taken: Array = []
	for group in groups:
		if is_visible.call(group):
			taken.append(group)
			_dirty.erase(group)
	presented_revision = revision
	_force = false
	_elapsed = 0.0
	return taken

## Groups still waiting for their view to become visible.
func pending_groups() -> Array:
	var groups := _dirty.keys()
	groups.sort()
	return groups

func _mark_all_dirty() -> void:
	for group in Group.values():
		_dirty[group] = true
