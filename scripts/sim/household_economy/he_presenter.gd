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
##   Presenting consumes the dirty set. A policy that hides inactive tabs can
##   narrow which groups are *taken*; untaken groups stay dirty and refresh the
##   next time they are asked for.
## - Pause, player commands, and selection changes call request_immediate(),
##   which makes the next due() true regardless of the interval.
##
## interval_seconds == 0.0 presents on every revision, matching the
## dashboard's behavior from before the presenter existed.

## Refresh groups, in the dashboard's presentation order.
enum Group { HEADER, TOWN, MARKET_NEEDS, BUSINESSES, HOUSEHOLDS, DETAILS, BLOTTER }

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

## Consumes and returns the dirty groups; records the presentation.
func take_dirty() -> Array:
	var groups := _dirty.keys()
	groups.sort()
	_dirty.clear()
	presented_revision = revision
	_force = false
	_elapsed = 0.0
	return groups

func _mark_all_dirty() -> void:
	for group in Group.values():
		_dirty[group] = true
