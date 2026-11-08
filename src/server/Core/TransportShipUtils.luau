-- Port of OpenFrontIO src/core/game/TransportShipUtils.ts.

local GameTypes = require(script.Parent.GameTypes)
local SpatialQuery = require(script.Parent.Pathfinding.SpatialQuery)

local UnitType = GameTypes.UnitType

local TransportShipUtils = {}

-- Landing shore near `tile` the attacker can actually reach by water.
function TransportShipUtils.targetTransportTile(gm, attacker, tile: number): number?
	return SpatialQuery.new(gm):closestReachableShore(gm:owner(tile), attacker, tile)
end

-- Launch shore for a boat to `tile`, or false.
function TransportShipUtils.canBuildTransportShip(game, player, tile: number): number | false
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return false
	end
	local dst = TransportShipUtils.targetTransportTile(game, player, tile)
	if dst == nil then
		return false
	end
	local other = game:owner(tile)
	if other == player then
		return false
	end
	if other:isPlayer() and not player:canAttackPlayer(other) then
		return false
	end
	return SpatialQuery.new(game):closestShoreByWater(player, dst) or false
end

function TransportShipUtils.bestShoreDeploymentSource(gm, player, dst: number): number?
	return SpatialQuery.new(gm):closestShoreByWater(player, dst)
end

return TransportShipUtils
