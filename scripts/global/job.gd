class_name Job
extends RefCounted

const ResourceNode = preload("res://scripts/entities/resource_node.gd")

enum Type { IDLE, MOVE, GATHER, BUILD, DEPOSIT }

var type: Type = Type.IDLE
var target_node: Node3D = null
var target_pos: Vector3 = Vector3.INF
var gather_resource_type: int = -1

static func make_idle() -> Job:
	return Job.new()

static func make_move(pos: Vector3) -> Job:
	var j := Job.new()
	j.type = Type.MOVE
	j.target_pos = pos
	return j

static func make_gather(resource: Node3D) -> Job:
	var j := Job.new()
	j.type = Type.GATHER
	j.target_node = resource
	if resource != null:
		var rt = resource.get("resource_type")
		if rt != null:
			j.gather_resource_type = int(rt)
	return j

static func make_gather_type(rtype: int) -> Job:
	var j := Job.new()
	j.type = Type.GATHER
	j.gather_resource_type = rtype
	return j

static func make_build(foundation: Node3D) -> Job:
	var j := Job.new()
	j.type = Type.BUILD
	j.target_node = foundation
	return j

static func make_deposit() -> Job:
	var j := Job.new()
	j.type = Type.DEPOSIT
	return j

func get_label() -> String:
	match type:
		Type.MOVE:    return "Moving"
		Type.GATHER:
			match gather_resource_type:
				ResourceNode.Type.WOOD:  return "Gathering Wood"
				ResourceNode.Type.STONE: return "Gathering Stone"
				ResourceNode.Type.FOOD:  return "Gathering Food"
				ResourceNode.Type.GOLD:  return "Gathering Gold"
			return "Gathering"
		Type.BUILD:   return "Building"
		Type.DEPOSIT: return "Depositing"
	return "Idle"
