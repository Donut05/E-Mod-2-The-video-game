---@diagnostic disable: undefined-global, undefined-field, deprecated, param-type-mismatch, lowercase-global, inject-field
dofile("$SURVIVAL_DATA/Scripts/game/worlds/BaseWorld.lua")
dofile("$CONTENT_DATA/Scripts/terrain/terrain_overworld.lua")
dofile("$CONTENT_DATA/Scripts/SurvivalGame.lua")
dofile("$CONTENT_DATA/Scripts/managers/WaterManager.lua")
dofile("$SURVIVAL_DATA/Scripts/game/managers/PackingStationManager.lua")

---@class Overworld : WorldClass
Overworld = class(BaseWorld)

Overworld.terrainScript = "$CONTENT_DATA/Scripts/terrain/terrain_overworld.lua"
Overworld.groundMaterialSet = "$GAME_DATA/Terrain/Materials/gnd_standard_materialset.json"
Overworld.enableSurface = true
Overworld.enableAssets = true
Overworld.enableClutter = true
Overworld.enableNodes = true
Overworld.isStatic = false -- !for testing, disable before release!
Overworld.enableCreations = true
Overworld.enableHarvestables = true
Overworld.enableKinematics = true
Overworld.renderMode = "outdoor"
Overworld.cellMinX = -64
Overworld.cellMaxX = 63
Overworld.cellMinY = -48
Overworld.cellMaxY = 47
-- cellMin is (cellMax * (-1)) - 1 and cellMax is (cellMin * (-1)) - 1

function Overworld.server_onCreate(self)
	self.sob = sm.scriptableObject.createScriptableObject(sm.uuid.new("9a078eef-36f4-4c47-96cf-287723f3c1bc"), {},
		self.world)
	BaseWorld.server_onCreate(self)
	print("Overworld.server_onCreate")

	self.packingStationManager = PackingStationManager()
	self.packingStationManager:sv_onCreate(self)

	-- self.waypointWaitingList = sm.storage.load( STORAGE_CHANNEL_WAYPOINT_WAITLIST )
	-- if self.waypointWaitingList == nil then
	-- 	self.waypointWaitingList = {}
	-- end

	self.foreignConnections = sm.storage.load(STORAGE_CHANNEL_FOREIGN_CONNECTIONS)
	if self.foreignConnections == nil then
		self.foreignConnections = {}
	end
end

function Overworld.client_onCreate(self)
	BaseWorld.client_onCreate(self)
	print("Overworld.client_onCreate")

	g_slam_position = sm.vec3.zero()
	g_slam_velocity = 0
	self.pipeCooldown = false
	self.pipeCooldownTick = sm.game.getCurrentTick()
	self.collisionDestructionSwitch = true

	self.ambienceEffect = sm.effect.createEffect("OutdoorAmbience")
	self.ambienceEffect:start()
	self.birdAmbienceTimer = Timer()
	self.birdAmbienceTimer:start(40)
	self.birdAmbience = { near = {}, far = {} }
end

function Overworld.client_onDestroy(self)
	if sm.exists(self.ambienceEffect) then
		self.ambienceEffect:destroy()
		self.ambienceEffect = nil
	end
	if sm.exists(self.birdAmbience.near.effect) then
		self.birdAmbience.near.effect:destroy()
		self.birdAmbience.near.effect = nil
	end
	self.birdAmbience.near = {}
	if sm.exists(self.birdAmbience.far.effect) then
		self.birdAmbience.far.effect:destroy()
		self.birdAmbience.far.effect = nil
	end
	self.birdAmbience.far = {}
end

function Overworld.server_onRefresh(self)
end

function Overworld.client_onRefresh(self)
	Overworld.client_onCreate(self)
end

function Overworld.server_onFixedUpdate(self)
	BaseWorld.server_onFixedUpdate(self)

	g_unitManager:sv_onWorldFixedUpdate(self)
end

function Overworld.client_onFixedUpdate(self)
	BaseWorld.client_onFixedUpdate(self)

	-- Update ambient birds
	self.birdAmbienceTimer:tick()
	if self.birdAmbienceTimer:done() then
		self.birdAmbienceTimer:reset()
		local myCharacter = sm.localPlayer.getPlayer().character
		if sm.exists(myCharacter) then
			local nearbyTree = sm.ai.getClosestTree(myCharacter.worldPosition, self.world)
			if sm.exists(nearbyTree) then
				if self.birdAmbience.near.harvestable ~= nearbyTree then
					if nearbyTree.clientPublicData and nearbyTree.clientPublicData.crownPosition then
						-- Remove far bird
						if sm.exists(self.birdAmbience.far.effect) then
							self.birdAmbience.far.effect:destroy()
						end
						self.birdAmbience.far = {}

						-- Move previous near bird to far
						self.birdAmbience.far.effect = self.birdAmbience.near.effect
						self.birdAmbience.far.harvestable = self.birdAmbience.near.harvestable

						-- Setup new near bird
						self.birdAmbience.near.harvestable = nearbyTree
						self.birdAmbience.near.effect = sm.effect.createEffect("Tree - Ambient Birds")
						self.birdAmbience.near.effect:setPosition(nearbyTree.clientPublicData.crownPosition)
						self.birdAmbience.near.effect:start()
					end
				end
			end
		end
	end

	if sm.game.getCurrentTick() >= self.pipeCooldownTick + 200 then
		self.pipeCooldown = false
		self.pipeCooldownTick = sm.game.getCurrentTick()
	end
end

function Overworld.client_onUpdate(self, deltaTime)
	BaseWorld.client_onUpdate(self, deltaTime)

	g_unitManager:cl_onWorldUpdate(self, deltaTime)

	local night = 1.0 - getDayCycleFraction()
	self.ambienceEffect:setParameter("amb_day_night", night)

	local player = sm.localPlayer.getPlayer()
	local character = player:getCharacter()
	if character and character:getWorld() == self.world then
		if g_survivalMusicWorld ~= self.world then
			g_survivalMusicWorld = self.world
			g_survivalMusic:stop()
		end
		if not g_survivalMusic:isPlaying() then
			g_survivalMusic:start()
		end

		local time = sm.game.getTimeOfDay()

		if time > 0.21 and time < 0.5 then -- dawn
			g_survivalMusic:setParameter("music", 2)
		elseif time > 0.5 and time < 0.875 then -- daynoon
			g_survivalMusic:setParameter("music", 3)
		else                              -- night
			g_survivalMusic:setParameter("music", 4)
		end
	end
	--print(sm.localPlayer.getPlayer().character.worldPosition)
end

function Overworld.client_onCollision(self, objectA, objectB, position, pointVelocityA, pointVelocityB, normal)
	--=ALL STUFF THAT HAS TO DO WITH SHAPES=--
	if sm.exists(objectA) and sm.exists(objectB) and (type(objectA) == "Shape" or type(objectB) == "Shape") then
		local AisShape = type(objectA) == "Shape"
		local BisShape = type(objectB) == "Shape"
		--=MAKE PETER BLOCK BOUNCY=--
		local upScale = 200
		local function reflectVector(vector, normal2)
			local generalLimiter = 300
			local result = vector - (normal2 * 2 * normal2:dot(vector))
			if result:length() > generalLimiter then
				print("limited")
				result = result:normalize() * generalLimiter
			end
			return result
		end
		local function amplifyUp(vector, normal2, scale)
			return vector + normal2 * scale
		end
		local function horizontalSpeedIsGreater(vector, normal2)
			local horizontalProj = vector - normal2 * vector:dot(normal2)
			local verticalProj = normal2 * vector:dot(normal2)

			return horizontalProj:length() >= verticalProj:length()
		end
		if AisShape then
			if objectA.uuid == sm.uuid.new("828bc42c-1f4a-4417-9d47-8fdcb67ff80e") then
				local vector = pointVelocityB * objectB.mass
				if horizontalSpeedIsGreater(vector, normal) then
					sm.physics.applyImpulse(objectB, reflectVector(vector, normal), true)
				else
					sm.physics.applyImpulse(objectB, amplifyUp(reflectVector(vector, normal), normal, upScale), true)
				end
			end
		end
		if BisShape then
			if objectB.uuid == sm.uuid.new("828bc42c-1f4a-4417-9d47-8fdcb67ff80e") then
				local vector = pointVelocityA * objectA.mass
				if horizontalSpeedIsGreater(vector, normal) then
					sm.physics.applyImpulse(objectA, reflectVector(vector, normal), true)
				else
					sm.physics.applyImpulse(objectA, amplifyUp(reflectVector(vector, normal), normal, upScale), true)
				end
			end
		end
		--=METAL PIPE SOUND EFFECT=--
		if sm.cae_injected and not self.pipeCooldown then
			local canPlay = false
			local successfulRoll = math.random(0, 250) == 0
			if AisShape then
				if successfulRoll and
				(objectA.material == "Metal" or objectA.material == "Mechanical") and
				objectA.uuid ~= sm.uuid.new("69e362c3-32aa-4cd1-adc0-dcfc47b92c0d") and
				objectA.uuid ~= sm.uuid.new("db66f0b1-0c50-4b74-bdc7-771374204b1f") then
					canPlay = true
				end
			else
				if successfulRoll and
				(objectB.material == "Metal" or objectB.material == "Mechanical") and
				objectB.uuid ~= sm.uuid.new("69e362c3-32aa-4cd1-adc0-dcfc47b92c0d") and
				objectB.uuid ~= sm.uuid.new("db66f0b1-0c50-4b74-bdc7-771374204b1f") then
					canPlay = true
				end
			end

			if type(objectA) == "Character" then -- BECAUSE IT'S A MECHANIC, HE HAS A MECHANICAL MATERIAL GET IT???
				if objectA:isPlayer() then
					canPlay = false
				end
			end

			if canPlay then
				--local pitch = 3.0 - math.min(objectA.mass / 200, 2.5)		THIS WILL NEVER GET ADDED BACK, BUT I WANT TO KEEP THE SCALING FORMULA, IT IS TOO GOOD
				sm.effect.playEffect("Sounds - Metal_pipe", position)
				self.pipeCooldown = true
				canPlay = false
			end
		end
	end

	--=COLLISION DESTRUCTION=--
	if self.collisionDestructionSwitch then
		if sm.exists(objectB) and type(objectB) == "Shape" then
			print("bonk!")
			if (pointVelocityA + pointVelocityB):length() > (sm.item.getQualityLevel(objectB.uuid) * 5) and math.random(0, sm.item.getQualityLevel(objectB.uuid)) == 0
			and objectB.uuid ~= sm.uuid.new("69e362c3-32aa-4cd1-adc0-dcfc47b92c0d") and objectB.uuid ~= sm.uuid.new("db66f0b1-0c50-4b74-bdc7-771374204b1f") then
				print("destroy")
				sm.melee.meleeAttack(sm.uuid.new("38fe8287-d408-492f-a3a0-996f5f13ecda"), 1, position, sm.vec3.new(2, 2, 2), sm.localPlayer.getPlayer(), 0, 0)
			end
		end
		if sm.exists(objectA) and type(objectA) == "Shape" then
			print("bonk!")
			if (pointVelocityA + pointVelocityB):length() > (sm.item.getQualityLevel(objectA.uuid) * 2) and math.random(0, sm.item.getQualityLevel(objectA.uuid)) == 0
			and objectA.uuid ~= sm.uuid.new("69e362c3-32aa-4cd1-adc0-dcfc47b92c0d") and objectA.uuid ~= sm.uuid.new("db66f0b1-0c50-4b74-bdc7-771374204b1f") then
				print("destroy")
				sm.melee.meleeAttack(sm.uuid.new("38fe8287-d408-492f-a3a0-996f5f13ecda"), 1, position, sm.vec3.new(2, 2, 2), sm.localPlayer.getPlayer(), 0, 0)
			end
		end
	end

	--=SLAM EFFECT=--
	if type(objectA) == "Character" then
		if sm.exists(objectA) and objectA:isPlayer() and math.abs(pointVelocityA.z) > 20 then
			sm.effect.playEffect("Player - Slam", objectA.worldPosition)
		end
	end
end

function Overworld.cl_switchDestruction(self)
	self.collisionDestructionSwitch = not self.collisionDestructionSwitch
	sm.gui.chatMessage("COLLISION DESTRUCTION IS " .. (self.collisionDestructionSwitch and "ON" or "OFF"))
end

function Overworld.cl_playDigEffect(self, data)
	sm.effect.playEffect("Enemies - DrillSpawner", data.position, nil, sm.vec3.getRotation(sm.vec3.new(0, 0, 1), data.rotation))
end

function Overworld.cl_n_unitMsg(self, msg)
	g_unitManager[msg.fn](g_unitManager, msg)
end

function Overworld.sv_loadShipOrStationOnCell(self, x, y)
	local powerCoreSocketInteractables = sm.cell.getInteractablesByUuid(x, y, obj_survivalobject_powercoresocket)
	for _, powerCoreSocketInteractable in ipairs(powerCoreSocketInteractables) do
		local lightInteractables = sm.cell.getInteractablesByUuid(x, y, obj_spaceship_ceilinglight)
		local shipworkbenchInteractables = sm.cell.getInteractablesByUuid(x, y, obj_survivalobject_workbench)
		local noteterminalInteractables = sm.cell.getInteractablesByUuid(x, y, obj_survivalobject_terminal)
		local dispenserbotInteractables = sm.cell.getInteractablesByUuid(x, y, obj_survivalobject_dispenserbot)

		powerCoreSocketInteractable:setParams({
			lightInteractables = lightInteractables,
			shipworkbenchInteractables = shipworkbenchInteractables,
			noteterminalInteractables = noteterminalInteractables,
			dispenserbotInteractables = dispenserbotInteractables
		})

		assert(#dispenserbotInteractables <= 1)
		for _, dispenserbotInteractable in ipairs(dispenserbotInteractables) do
			local dispenserbotSpawnerInteractables = sm.cell.getInteractablesByUuid(x, y,
				obj_survivalobject_dispenserbot_spawner)
			assert(#dispenserbotSpawnerInteractables == 1)
			dispenserbotInteractable:setParams({ spawner = dispenserbotSpawnerInteractables[1] })
		end
	end
end

function Overworld.sv_loadHideoutOnCell(self, x, y)
	local questGiverInteractables = sm.cell.getInteractablesByUuid(x, y, obj_hideout_questgiver)
	if #questGiverInteractables > 0 then
		local questGiverInteractable = questGiverInteractables[1]
		local buttonInteractables = sm.cell.getInteractablesByUuid(x, y, obj_hideout_button)
		local vacuumInteractables = sm.cell.getInteractablesByUuid(x, y, obj_hideout_dropoff)
		local cameraNodes = sm.cell.getNodesByTag(x, y, "CAMERA")
		local dropzoneNodes = sm.cell.getNodesByTag(x, y, "HIDEOUT_DROPZONE")
		if #vacuumInteractables > 0 and #buttonInteractables > 0 and #cameraNodes > 0 and #dropzoneNodes > 0 then
			questGiverInteractable:setParams({
				vacuumInteractable = vacuumInteractables[1],
				buttonInteractable = buttonInteractables[1],
				cameraNode = cameraNodes[1],
				dropzoneNode = dropzoneNodes
					[1]
			})
		else
			print("Failed to load hideout: ", #vacuumInteractables, " vacuums, ", #buttonInteractables, " buttons, ",
				#cameraNodes > 0, " cameras, ", #dropzoneNodes > 0, " dropzones.")
		end
	end
end

local function GetWaitlistKey(id, x, y)
	return id .. "," .. x .. "," .. y
end

function Overworld.sv_loadPathNodesOnCell(self, x, y)
	local waypoints = sm.cell.getNodesByTag(x, y, "WAYPOINT")
	if #waypoints == 0 then
		return
	end

	local pathNodes = {}
	for _, waypoint in ipairs(waypoints) do
		assert(waypoint.params.connections, "Waypoint nodes expected to have the CONNECTION tag aswell")
		pathNodes[waypoint.params.connections.id] = sm.pathNode.createPathNode(waypoint.position, waypoint.scale.x)
	end

	local waypointCells = {}

	local shouldSaveForeign = false
	local shouldSaveCell = false

	local foreignCells = {}

	for _, waypoint in ipairs(waypoints) do
		local id = waypoint.params.connections.id
		assert(sm.exists(pathNodes[id]))
		-- For each other node connected to this node
		for _, other in ipairs(waypoint.params.connections.otherIds) do
			if (type(other) == "table") then
				if pathNodes[other.id] then -- Node exist in cell, connect
					assert(sm.exists(pathNodes[other.id]))
					pathNodes[id]:connect(pathNodes[other.id], other.actions, other.conditions)
				else -- Node dosent exist in this cell
					-- Add myself to the foreign connections
					local key = GetWaitlistKey(other.id, x + other.cell[1], y + other.cell[2])
					if self.foreignConnections[key] == nil then
						self.foreignConnections[key] = {}
					end

					table.insert(self.foreignConnections[key],
						{ pathnode = pathNodes[id], actions = other.actions, conditions = other.conditions })
					shouldSaveForeign = true

					-- Mark foreign cell
					foreignCells[CellKey(x + other.cell[1], y + other.cell[2])] = {
						x = x + other.cell[1],
						y = y + other.cell[2]
					}
				end
			else
				assert(pathNodes[other])
				pathNodes[id]:connect(pathNodes[other])
			end
		end

		-- If we still have foreign connections to us
		if waypoint.params.connections.ccount then
			local key = GetWaitlistKey(id, x, y)
			local foreignConnections = self.foreignConnections[key]
			if foreignConnections then
				for idx, connection in reverse_ipairs(foreignConnections) do
					if sm.exists(connection.pathnode) then
						connection.pathnode:connect(pathNodes[id], connection.actions, connection.conditions)
						waypoint.params.connections.ccount = waypoint.params.connections.ccount - 1
						table.remove(foreignConnections, idx)
						shouldSaveForeign = true
					end
				end
				if #foreignConnections == 0 then
					self.foreignConnections[key] = nil
					shouldSaveForeign = true
				end
			end

			if waypoint.params.connections.ccount > 0 then
				table.insert(waypointCells, { pathnode = pathNodes[id], connections = waypoint.params.connections })
				shouldSaveCell = true
			end
		end
	end

	if shouldSaveCell then
		sm.storage.save({ STORAGE_CHANNEL_WAYPOINT_CELLS, self.world.id, CellKey(x, y) }, waypointCells)
		shouldSaveCell = false
	end

	if shouldSaveForeign then
		sm.storage.save(STORAGE_CHANNEL_FOREIGN_CONNECTIONS, self.foreignConnections)
		shouldSaveForeign = false
	end

	for _, v in pairs(foreignCells) do
		self:sv_reloadPathNodesOnCell(v.x, v.y)
	end
end

function Overworld.sv_reloadPathNodesOnCell(self, x, y)
	local waypointCells = sm.storage.load({ STORAGE_CHANNEL_WAYPOINT_CELLS, self.world.id, CellKey(x, y) })
	if waypointCells == nil then
		return
	end

	-- print("CELLS:", x, y )
	-- print( waypointCells )
	-- print("FOREIGN CONNECTIONS:")
	-- print( self.foreignConnections )

	local shouldSaveForeign = false
	local shouldSaveCell = false

	for idx, node in reverse_ipairs(waypointCells) do
		if sm.exists(node.pathnode) then
			assert(node.connections.ccount > 0)
			local key = GetWaitlistKey(node.connections.id, x, y)
			local foreignConnections = self.foreignConnections[key]
			if foreignConnections then
				for foreignIdx, connection in reverse_ipairs(foreignConnections) do
					if sm.exists(connection.pathnode) then
						connection.pathnode:connect(node.pathnode, connection.actions, connection.conditions)
						node.connections.ccount = node.connections.ccount - 1
						shouldSaveCell = true

						table.remove(foreignConnections, foreignIdx)
						shouldSaveForeign = true
					end
				end
				if #foreignConnections == 0 then
					self.foreignConnections[key] = nil
					shouldSaveForeign = true
				end
			end
		end

		if node.connections.ccount == 0 then
			table.remove(waypointCells, idx)
			shouldSaveCell = true
		end
	end

	if shouldSaveCell then
		if #waypointCells == 0 then
			waypointCells = nil
		end
		sm.storage.save({ STORAGE_CHANNEL_WAYPOINT_CELLS, self.world.id, CellKey(x, y) }, waypointCells)
		shouldSaveCell = false
	end

	if shouldSaveForeign then
		sm.storage.save(STORAGE_CHANNEL_FOREIGN_CONNECTIONS, self.foreignConnections)
		shouldSaveForeign = false
	end
end

function Overworld.sv_loadSpawnersOnCell(self, x, y)
	local nodes = sm.cell.getNodesByTag(x, y, "PLAYER_SPAWN")
	g_respawnManager:sv_addSpawners(nodes)
	g_respawnManager:sv_setLatestSpawners(nodes)
end

function Overworld.sv_reloadSpawnersOnCell(self, x, y)
	local nodes = sm.cell.getNodesByTag(x, y, "PLAYER_SPAWN")
	g_respawnManager:sv_setLatestSpawners(nodes)
end

function Overworld.sv_spawnNewCharacter(self, params)
	local spawnPosition = sm.vec3.new(0, 0, 16)
	local yaw = 0
	local pitch = 0

	local nodes = sm.cell.getNodesByTag(params.x, params.y, "PLAYER_SPAWN")
	if #nodes > 0 then
		local spawnerIndex = ((params.player.id - 1) % #nodes) + 1
		local spawnNode = nodes[spawnerIndex]
		spawnPosition = spawnNode.position + sm.vec3.new(0, 0, 1) * 0.7

		local spawnDirection = spawnNode.rotation * sm.vec3.new(0, 0, 1)
		--pitch = math.asin( spawnDirection.z )
		yaw = math.atan2(spawnDirection.y, spawnDirection.x) - math.pi / 2
	else
		spawnPosition.z = SurvivalGame.sv_requestZ() + 0.5
	end

	local character = sm.character.createCharacter(params.player, self.world, spawnPosition, yaw, pitch)
	params.player:setCharacter(character)
end

local function selectHarvestableToPlace( keyword )
	if keyword == "stone" then
		local stones = {
			hvs_stone_small01, hvs_stone_small02, hvs_stone_small03
			--hvs_stone_medium01, hvs_stone_medium02, hvs_stone_medium03,
			--hvs_stone_large01, hvs_stone_large02, hvs_stone_large03
		}
		return stones[math.random( 1, #stones )]
	elseif keyword == "tree" then
		local trees = {
			hvs_tree_birch01, hvs_tree_birch02, hvs_tree_birch03,
			hvs_tree_leafy01, hvs_tree_leafy02, hvs_tree_leafy03,
			hvs_tree_spruce01, hvs_tree_spruce02, hvs_tree_spruce03,
			hvs_tree_pine01, hvs_tree_pine02, hvs_tree_pine03
		}
		return trees[math.random( 1, #trees )]
	elseif keyword == "birch" then
		local trees = { hvs_tree_birch01, hvs_tree_birch02, hvs_tree_birch03 }
		return trees[math.random( 1, #trees )]
	elseif keyword == "leafy" then
		local trees = { hvs_tree_leafy01, hvs_tree_leafy02, hvs_tree_leafy03 }
		return trees[math.random( 1, #trees )]
	elseif keyword == "spruce" then
		local trees = {	hvs_tree_spruce01, hvs_tree_spruce02, hvs_tree_spruce03 }
		return trees[math.random( 1, #trees )]
	elseif keyword == "pine" then
		local trees = { hvs_tree_pine01, hvs_tree_pine02, hvs_tree_pine03 }
		return trees[math.random( 1, #trees )]
	end
	return nil
end

function Overworld.sv_e_onChatCommand(self, params)
	BaseWorld.sv_e_onChatCommand(self, params)

	if params[1] == "/raid" then
		print("Starting raid level", params[2], "in, wave", params[3] or 1, " in", params[4] or (10 / 60), "hours")
		local position = params.player.character.worldPosition -
			sm.vec3.new(0, 0, params.player.character:getHeight() / 2)
		g_unitManager:sv_beginRaidCountdown(self, position, params[2], params[3] or 1,
			(params[4] or (10 / 60)) * 60 * 40)
	elseif params[1] == "/stopraid" then
		print("Cancelling all raid")
		g_unitManager:sv_cancelRaidCountdown(self)
	elseif params[1] == "/disableraids" then
		print("Disable raids set to", params[2])
		g_unitManager.disableRaids = params[2]
	elseif params[1] == "/clear" then
		for _, body in ipairs(sm.body.getAllBodies()) do
			for _, shape in ipairs(body:getShapes()) do
				shape:destroyShape()
			end
		end
	elseif params[1] == "/place" then
		local harvestableUuid = selectHarvestableToPlace( params[2] )
		if harvestableUuid and params.aimPosition then
			local from = params.aimPosition + sm.vec3.new( 0, 0, 16.0 )
			local to = params.aimPosition - sm.vec3.new( 0, 0, 16.0 )
			local success, result = sm.physics.raycast( from, to, nil, sm.physics.filter.default )
			if success and result.type == "terrainSurface" then
				local harvestableYZRotation = sm.vec3.getRotation( sm.vec3.new( 0, 1, 0 ), sm.vec3.new( 0, 0, 1 ) )
				local harvestableRotation = sm.quat.fromEuler( sm.vec3.new( 0, math.random( 0, 359 ), 0 ) )
				local placePosition = result.pointWorld
				if params[2] == "stone" then
					placePosition = placePosition + sm.vec3.new( 0, 0, 2.0 )
				end
				sm.harvestable.createHarvestable( harvestableUuid, placePosition, harvestableYZRotation * harvestableRotation )
			end
		end
	end
end

function Overworld:sv_spawnBlueprint(data)
	local bodies = sm.creation.importFromFile(nil, data.blueprint, data.pos, data.rot)
	for _, currentBody in ipairs(bodies) do
		local shapes = currentBody:getShapes()
		for _, currentShape in ipairs(shapes) do
			currentShape:setColor(data.color)
			if math.abs((currentShape.worldPosition - data.hitPos):length()) < 4 then
				currentShape.interactable:setParams({ inheritedDamage = 300, pristine = true })
			end
		end
	end
end

function Overworld.cl_teleportToSpace(self, position)
	self.network:sendToServer("sv_teleportToSpace", position)
end

function Overworld.sv_receieveWorld(self, world)
	print("RECEIEVING THE WORLD FROM GAME SCRIPT!")
	self.space = world
	self:sv_teleportToSpace(self.positionCache)
end

function Overworld.sv_teleportToSpace(self, position)
	self.positionCache = position
	if not self.space then
		sm.event.sendToGame("sv_createSpace", self.world)
		print("CREATING WORLD!")
		return
	end
	print("WORLD ALREADY EXISTS! CREATING OUR SIDE OF THE TELEPORT!")
	local portal = sm.portal.createPortal(sm.vec3.new(1000, 1000, 1000))
	portal:setOpeningA(position, sm.quat.identity())
	sm.portal.addWorldPortalHook(self.space, "space_hole", portal)
	print("CREATED OUR SIDE! SENDING DATA TO THE OTHER SIDE!")
	sm.event.sendToWorld(self.space, "sv_receievePosition", position)
end

-- World cell callbacks

function Overworld.server_onCellCreated(self, x, y)
	BaseWorld.server_onCellCreated(self, x, y)
	local tags = sm.cell.getTags(x, y)
	--print(  "cell", x..",", y, "tags:" )
	--for i,tag in ipairs( tags ) do
	--	print( "\t"..i, tag )
	--end

	self:sv_loadSpawnersOnCell(x, y)

	local cell = {
		x = x,
		y = y,
		worldId = self.world.id,
		isStartArea = valueExists(tags, "STARTAREA"),
		isPoi = valueExists(tags, "POI")
	}

	if not cell.isStartArea then
		SpawnFromNodeOnCellLoaded(cell, "TAPEBOT")
		if x > -8 or y > -8 or valueExists(tags, "SCRAPYARD") then
			SpawnFromNodeOnCellLoaded(cell, "FARMBOT")
		end
	end

	self:sv_loadHideoutOnCell(x, y)
	self:sv_loadShipOrStationOnCell(x, y)

	g_elevatorManager:sv_loadElevatorsOnOverworldCell(x, y, tags)





	g_unitManager:sv_onWorldCellLoaded(self, x, y)
	self.packingStationManager:sv_onCellLoaded(x, y)

	if getDayCycleFraction() == 0.0 then
		--g_unitManager:sv_requestTempUnitsOnCell( x, y )
	end

	local result, msg = pcall(function() self:sv_loadPathNodesOnCell(x, y) end)
	if not result then
		sm.log.error("Failed to load path nodes on cell: " .. msg)
	end
end

function Overworld.client_onCellLoaded(self, x, y)
	BaseWorld.client_onCellLoaded(self, x, y)
end

function Overworld.server_onCellLoaded(self, x, y)
	BaseWorld.server_onCellLoaded(self, x, y)

	local tags = sm.cell.getTags(x, y)
	local cell = {
		x = x,
		y = y,
		worldId = self.world.id,
		isStartArea = valueExists(tags, "STARTAREA"),
		isPoi = valueExists(tags, "POI")
	}






	g_unitManager:sv_onWorldCellReloaded(self, x, y)

	self:sv_reloadSpawnersOnCell(x, y)

	if not cell.isStartArea then
		RespawnFromNodeOnCellReloaded(cell, "TAPEBOT")
		if x > -8 or y > -8 or valueExists(tags, "SCRAPYARD") then
			RespawnFromNodeOnCellReloaded(cell, "FARMBOT")
		end
	end

	if getDayCycleFraction() == 0.0 then
		--g_unitManager:sv_requestTempUnitsOnCell( x, y )
	end

	local result, msg = pcall(function() self:sv_reloadPathNodesOnCell(x, y) end)
	if not result then
		sm.log.error("Failed to load path nodes on cell: " .. msg)
	end
end

function Overworld.server_onCellUnloaded(self, x, y)
	BaseWorld.server_onCellUnloaded(self, x, y)
	--print( "Overworld - cell ("..x..","..y..") unloaded" )
	g_unitManager:sv_onWorldCellUnloaded(self, x, y)
end

function Overworld.client_onCellUnloaded(self, x, y)
	BaseWorld.client_onCellUnloaded(self, x, y)
	--print( "Overworld - client cell ("..x..","..y..") unloaded" )
end

function Overworld.server_onProjectile(self, hitPos, hitTime, hitVelocity, _, attacker, damage, userData, hitNormal, target, projectileUuid)
	BaseWorld.server_onProjectile(self, hitPos, hitTime, hitVelocity, _, attacker, damage, userData, hitNormal, target, projectileUuid)

	if self.enablePathPotatoes and projectileUuid == projectile_potato then
		local node = sm.pathfinder.getSortedNodes(hitPos, 0, 2)[1]
		if node == nil then
			node = sm.pathNode.createPathNode(hitPos, 1.0)
		end
		print(self.prevPotatoNode)
		if self.prevPotatoNode and self.prevPotatoNode ~= node then
			self.prevPotatoNode:connect(node)
			node:connect(self.prevPotatoNode)
		end
		self.prevPotatoNode = node
	else
		self.prevPotatoNode = nil
	end
end

function Overworld.sv_ambush(self, params)
	print("Ambush - magnitude:", params.magnitude, "wave:", params.wave)
	local players = sm.player.getAllPlayers()

	for _, player in pairs(players) do
		if player.character and player.character:getWorld() == self.world then
			local incomingUnits = {}

			local playerPosition = player.character.worldPosition
			local playerDensity = g_unitManager:sv_getPlayerDensity(playerPosition)

			if params.wave then
				if playerDensity > 0.85 then
					incomingUnits[#incomingUnits + 1] = unit_haybot
					incomingUnits[#incomingUnits + 1] = unit_totebot_green
				elseif playerDensity > 0.5 then
					incomingUnits[#incomingUnits + 1] = unit_totebot_green
					incomingUnits[#incomingUnits + 1] = unit_totebot_green
				elseif playerDensity > 0.3 then
					incomingUnits[#incomingUnits + 1] = unit_totebot_green
				end
			end

			local minDistance = 64
			local maxDistance = 128 -- 128 is maximum guaranteed terrain distance
			local validNodes = sm.pathfinder.getSortedNodes(playerPosition, minDistance, maxDistance)
			local validNodesCount = table.maxn(validNodes)

			--local incomingUnits = g_unitManager:sv_getRandomUnits( unitCount, playerPosition )

			if validNodesCount > 0 then
				print(#incomingUnits .. " enemies are approaching!")
				for i = 1, #incomingUnits do
					local selectedNode = math.random(validNodesCount)
					local unitPos = validNodes[selectedNode]:getPosition()

					if validNodesCount >= #incomingUnits - i then
						table.remove(validNodes, selectedNode)
						validNodesCount = validNodesCount - 1
					end

					local playerDirection = playerPosition - unitPos
					local yaw = math.atan2(playerDirection.y, playerDirection.x) - math.pi / 2

					sm.unit.createUnit(incomingUnits[i], unitPos + sm.vec3.new(0, 0.1, 0), yaw,
						{ temporary = true, roaming = true, ambush = true, tetherPoint = playerPosition })
				end
			else
				local maxSpawnAttempts = 32
				for i = 1, #incomingUnits do
					local spawnAttempts = 0
					while spawnAttempts < maxSpawnAttempts do
						spawnAttempts = spawnAttempts + 1
						local distanceFromCenter = math.random(minDistance, maxDistance)
						local spawnDirection = sm.vec3.new(0, 1, 0)
						spawnDirection = spawnDirection:rotateZ(math.rad(math.random(359)))
						local spawnPosition = playerPosition + spawnDirection * distanceFromCenter

						local success, result = sm.physics.raycast(spawnPosition + sm.vec3.new(0, 0, 128),
							spawnPosition + sm.vec3.new(0, 0, -128), nil, -1)
						if success and (result.type == "limiter" or result.type == "terrainSurface") then
							local directionToPlayer = playerPosition - spawnPosition
							local yaw = math.atan2(directionToPlayer.y, directionToPlayer.x) - math.pi / 2
							spawnPosition = result.pointWorld
							sm.unit.createUnit(incomingUnits[i], spawnPosition, yaw,
								{ temporary = true, roaming = true, ambush = true, tetherPoint = playerPosition })
							break
						end
					end
				end
			end
		end
	end
end

function Overworld.sv_e_spawnRaiders(self, params)
	local attackPos = params.attackPos
	local raiders = params.raiders

	local minDistance = 50
	local maxDistance = 80 -- 128 is maximum guaranteed terrain distance

	local incomingUnits = {}
	for k, v in pairs(raiders) do
		for i = 1, v do
			table.insert(incomingUnits, k)
		end
	end

	print(#incomingUnits, "raiders incoming")

	local maxSpawnAttempts = 32
	for i = 1, #incomingUnits do
		local spawnAttempts = 0
		while spawnAttempts < maxSpawnAttempts do
			spawnAttempts = spawnAttempts + 1
			local distanceFromCenter = math.random(minDistance, maxDistance)
			local spawnDirection = sm.vec3.new(0, 1, 0)
			spawnDirection = spawnDirection:rotateZ(math.rad(math.random(359)))
			local unitPos = attackPos + spawnDirection * distanceFromCenter

			local success, result = sm.physics.raycast(unitPos + sm.vec3.new(0, 0, 128),
				unitPos + sm.vec3.new(0, 0, -128), nil, -1)
			if success and (result.type == "limiter" or result.type == "terrainSurface") then
				local direction = attackPos - unitPos
				local yaw = math.atan2(direction.y, direction.x) - math.pi / 2
				unitPos = result.pointWorld
				local deathTick = sm.game.getCurrentTick() + 40 * 60 * 5 -- Despawn after 5 minutes (flee after 4)
				sm.unit.createUnit(incomingUnits[i], unitPos, yaw,
					{ temporary = true, roaming = true, raider = true, tetherPoint = attackPos, deathTick = deathTick })
				break
			end
		end
	end

	-- self.network:sendToClients( "cl_n_unitMsg", {
	-- 	fn = "cl_n_waveMsg",
	-- 	wave = params.wave,
	-- } )
end

function Overworld.sv_e_spawnTempUnitsOnCell(self, params)
	local cellSize = 64.0
	local cellSteps = cellSize - 1
	local xCoordMin = params.x * cellSize + (params.x < 0 and (cellSteps) or 0)
	local yCoordMin = params.y * cellSize + (params.y < 0 and (cellSteps) or 0)
	local xCoordMax = xCoordMin + (params.x < 0 and cellSteps * -1 or cellSteps)
	local yCoordMax = yCoordMin + (params.y < 0 and cellSteps * -1 or cellSteps)

	local unitCount = 0
	local spawnMagnitude = math.random(0, 99)
	if spawnMagnitude > 98 then  -- ( 99 - 1 )
		unitCount = 3
	elseif spawnMagnitude > 93 then -- ( 99 - 1 - 5 )
		unitCount = 2
	elseif spawnMagnitude > 83 then -- ( 99 - 1 - 5 - 10 )
		unitCount = 1
	end
	if unitCount == 0 then
		return
	end

	local cellPosition = sm.vec3.new((xCoordMin + xCoordMax) * 0.5, (yCoordMin + yCoordMax) * 0.5, 0.0)
	local minDistance = 0.0
	local maxDistance = cellSize * 0.5
	local validNodes = sm.pathfinder.getSortedNodes(cellPosition, minDistance, maxDistance)
	local validNodesCount = table.maxn(validNodes)

	local incomingUnits = g_unitManager:sv_getRandomUnits(unitCount, nil)

	if validNodesCount > 0 then
		--print( unitCount .. " enemies are approaching!" )
		for i = 1, #incomingUnits do
			local selectedNode = math.random(validNodesCount)
			local unitPos = validNodes[selectedNode]:getPosition()

			if validNodesCount >= #incomingUnits - i then
				table.remove(validNodes, selectedNode)
				validNodesCount = validNodesCount - 1
			end

			sm.unit.createUnit(incomingUnits[i], unitPos + sm.vec3.new(0, 0.1, 0), yaw, { temporary = true })
		end
	else
		local maxSpawnAttempts = 32
		for i = 1, #incomingUnits do
			local spawnAttempts = 0
			while spawnAttempts < maxSpawnAttempts do
				spawnAttempts = spawnAttempts + 1
				local subdivisions = sm.construction.constants.subdivisions
				local subdivideRatio = sm.construction.constants.subdivideRatio
				local spawnPosition = sm.vec3.new(
					math.random(xCoordMin * subdivisions, xCoordMax * subdivisions) * subdivideRatio,
					math.random(yCoordMin * subdivisions, yCoordMax * subdivisions) * subdivideRatio,
					0.0)

				local success, result = sm.physics.raycast(spawnPosition + sm.vec3.new(0, 0, 128),
					spawnPosition + sm.vec3.new(0, 0, -128), nil, sm.physics.filter.all)
				if success and (result.type == "limiter" or result.type == "terrainSurface") then
					local direction = sm.vec3.new(0, 1, 0)
					local yaw = math.atan2(direction.y, direction.x) - math.pi / 2
					spawnPosition = result.pointWorld
					sm.unit.createUnit(incomingUnits[i], spawnPosition, yaw, { temporary = true })
					break
				end
			end
		end
	end
end
