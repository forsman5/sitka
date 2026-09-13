class_name Commodity
extends RefCounted

enum Type { GRAIN, CATTLE, SHEEP, WOOL, TIMBER, CHARCOAL, IRON, TOOLS }

const ALL: Array[Type] = [
	Type.GRAIN, Type.CATTLE, Type.SHEEP, Type.WOOL,
	Type.TIMBER, Type.CHARCOAL, Type.IRON, Type.TOOLS,
]

static func name_of(t: Type) -> String:
	match t:
		Type.GRAIN: return "Grain"
		Type.CATTLE: return "Cattle"
		Type.SHEEP: return "Sheep"
		Type.WOOL: return "Wool"
		Type.TIMBER: return "Timber"
		Type.CHARCOAL: return "Charcoal"
		Type.IRON: return "Iron"
		Type.TOOLS: return "Tools"
	return "Unknown"
