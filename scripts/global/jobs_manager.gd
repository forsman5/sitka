extends Node

signal job_assigned(person: Node3D, job: Job)
signal job_completed(person: Node3D, old_job: Job)
signal job_cancelled(person: Node3D, old_job: Job)
signal assignments_changed()

var _assignments: Dictionary = {}  # Node3D -> Job
var _island: Node = null

func _ready() -> void:
	_island = get_parent()

# --- Lifecycle ---

func register_person(person: Node3D) -> void:
	if not _assignments.has(person):
		_assignments[person] = Job.make_idle()

func unregister_person(person: Node3D) -> void:
	_assignments.erase(person)

# --- Low-level assignment ---

func assign_job(person: Node3D, job: Job) -> void:
	_assignments[person] = job
	_apply_to_person(person, job)
	job_assigned.emit(person, job)

func assign_gather(persons: Array, resource: Node3D) -> void:
	for p: Node3D in persons:
		assign_job(p, Job.make_gather(resource))

func assign_gather_by_type(persons: Array, rtype: int) -> void:
	for p: Node3D in persons:
		var resource := _find_nearest_resource(p, rtype)
		var j: Job = Job.make_gather(resource) if resource != null else Job.make_gather_type(rtype)
		assign_job(p, j)

func assign_build(persons: Array, foundation: Node3D) -> void:
	for p: Node3D in persons:
		assign_job(p, Job.make_build(foundation))

func assign_move(persons: Array, pos: Vector3) -> void:
	for p: Node3D in persons:
		assign_job(p, Job.make_move(pos))

func assign_deposit(persons: Array) -> void:
	for p: Node3D in persons:
		assign_job(p, Job.make_deposit())

func assign_idle(persons: Array) -> void:
	for p: Node3D in persons:
		var old := get_job(p)
		_assignments[p] = Job.make_idle()
		p.set_idle()
		job_cancelled.emit(p, old)

# --- +/- UI controls ---

func increment_gather(rtype: int) -> bool:
	var idle := get_idle_persons()
	if idle.is_empty():
		return false
	var person: Node3D = idle[0]
	var resource := _find_nearest_resource(person, rtype)
	var j: Job = Job.make_gather(resource) if resource != null else Job.make_gather_type(rtype)
	assign_job(person, j)
	return true

func increment_build(preferred: Node3D = null) -> bool:
	var idle := get_idle_persons()
	if idle.is_empty():
		return false
	var person: Node3D = idle[0]
	var foundation: Node3D = preferred if (preferred != null and is_instance_valid(preferred)) else _find_nearest_foundation(person)
	if foundation == null:
		return false
	assign_job(person, Job.make_build(foundation))
	return true

func increment_deposit() -> bool:
	var idle := get_idle_persons()
	if idle.is_empty():
		return false
	assign_job(idle[0], Job.make_deposit())
	return true

func decrement_gather(rtype: int) -> bool:
	for person in _assignments.keys():
		var j: Job = _assignments[person]
		if j.type == Job.Type.GATHER and j.gather_resource_type == rtype:
			assign_idle([person])
			return true
	return false

func decrement_build() -> bool:
	for person in _assignments.keys():
		if (_assignments[person] as Job).type == Job.Type.BUILD:
			assign_idle([person])
			return true
	return false

func decrement_deposit() -> bool:
	for person in _assignments.keys():
		if (_assignments[person] as Job).type == Job.Type.DEPOSIT:
			assign_idle([person])
			return true
	return false

# --- Queries ---

func get_job(person: Node3D) -> Job:
	return _assignments.get(person, Job.make_idle())

func get_job_label(person: Node3D) -> String:
	return get_job(person).get_label()

func get_all_assignments() -> Dictionary:
	return _assignments.duplicate()

func get_persons_with_type(type: Job.Type) -> Array[Node3D]:
	var result: Array[Node3D] = []
	for person in _assignments.keys():
		if (_assignments[person] as Job).type == type:
			result.append(person)
	return result

func get_idle_persons() -> Array[Node3D]:
	return get_persons_with_type(Job.Type.IDLE)

func get_gather_count(rtype: int) -> int:
	var count := 0
	for person in _assignments.keys():
		var j: Job = _assignments[person]
		if j.type == Job.Type.GATHER and j.gather_resource_type == rtype:
			count += 1
	return count

func get_build_count() -> int:
	return get_persons_with_type(Job.Type.BUILD).size()

func get_deposit_count() -> int:
	return get_persons_with_type(Job.Type.DEPOSIT).size()

func get_move_count() -> int:
	return get_persons_with_type(Job.Type.MOVE).size()

func get_idle_count() -> int:
	return get_idle_persons().size()

# Called by person.gd when a MOVE completes naturally
func notify_task_completed(person: Node3D) -> void:
	var old := get_job(person)
	_assignments[person] = Job.make_idle()
	job_completed.emit(person, old)

# Called by person.gd after restore_from_save to re-sync job state
func resync_from_state(person: Node3D) -> void:
	_assignments[person] = _infer_job_from_state(person)
	assignments_changed.emit()

# --- Internal ---

func _apply_to_person(person: Node3D, job: Job) -> void:
	match job.type:
		Job.Type.IDLE:
			person.set_idle()
		Job.Type.MOVE:
			person.set_move_objective(job.target_pos)
		Job.Type.GATHER:
			if job.target_node != null and is_instance_valid(job.target_node):
				person.set_objective(job.target_node)
			elif job.gather_resource_type >= 0:
				person.set_gather_retarget(job.gather_resource_type)
			else:
				person.set_idle()
		Job.Type.BUILD:
			if job.target_node != null and is_instance_valid(job.target_node):
				person.set_build_objective(job.target_node)
		Job.Type.DEPOSIT:
			person.set_deposit_objective()

func _find_nearest_resource(from: Node3D, rtype: int) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist := INF
	for n in from.get_tree().get_nodes_in_group("resource_nodes"):
		if not is_instance_valid(n):
			continue
		if _island != null and not _island.is_ancestor_of(n):
			continue
		if int(n.get("resource_type")) != rtype:
			continue
		var d: float = from.global_position.distance_to((n as Node3D).global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = n as Node3D
	return nearest

func _find_nearest_foundation(from: Node3D) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist := INF
	for n in from.get_tree().get_nodes_in_group("foundations"):
		if not is_instance_valid(n):
			continue
		if _island != null and not _island.is_ancestor_of(n):
			continue
		var d: float = from.global_position.distance_to((n as Node3D).global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = n as Node3D
	return nearest

func _infer_job_from_state(person: Node3D) -> Job:
	var move_target = person.get("_move_target")
	if move_target != null and move_target != Vector3.INF:
		return Job.make_move(move_target)
	if person.get("_deposit_queued"):
		return Job.make_deposit()
	var build_target: Node3D = person.get("_build_target")
	if build_target != null and is_instance_valid(build_target):
		return Job.make_build(build_target)
	var objective: Node3D = person.get("_objective_node")
	if objective != null and is_instance_valid(objective):
		return Job.make_gather(objective)
	var last_rtype: int = person.get("_last_resource_type") if person.get("_last_resource_type") != null else -1
	if last_rtype >= 0:
		return Job.make_gather_type(last_rtype)
	return Job.make_idle()
