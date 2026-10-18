class_name HEBuilding
extends RefCounted

## Anything physically built in a settlement. HEBusiness (a productive site
## with workers, a recipe and a balance) and HEHouse (housing, nothing else)
## both extend it, so code that only cares "what stands here" -- the town
## layout, the government build menu -- can treat them alike without a business
## having to pretend to be a house or vice versa.
##
## ID namespaces are separate per kind: business ids live in
## HESimulation.businesses, house ids in HESimulation.dwellings, so a
## consumer that needs a stable key should use (type_key, id).

var id: int
var settlement_id: int
var name: String
## Which buildable kind this is ("farm", "trader", "house", ...), set by the
## HEScenarioSeeds make_* factories so a unique-building limit can be checked.
## Empty for businesses with no factory (Government, Bloomery, Iron Mine).
var type_key: String = ""
