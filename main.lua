--[[
	CompanionNPC.server.lua
	Utility-based AI companion for a wave-based survival game (mobile base / bus defense).

	PLACEMENT: a Script (RunContext = Server) parented inside the companion's rig Model.
	The rig needs a Humanoid and HumanoidRootPart. Give it a Tool to enable combat.

	THIS IS A SERVER-SIDE NPC. It controls only its own rig, never a player's character.

	EXPECTED GAME-SIDE CONVENTIONS (set these up in your own game):
	  workspace attribute  "WavePhase"       : "Calm" | "Assault"
	  Tag "Hostile"                          : on every enemy Model (has a Humanoid)
	  Tag "BaseVehicle"                      : on the bus Model; attributes Health, MaxHealth
	  Tag "Lootable"                         : fuel containers / parts; attribute Looted (bool),
	                                           optional HoldDuration (number)
	  Tag "RepairStation"                    : part/model the NPC walks to when the bus is damaged
	  Tag "AttachPoint"                      : furnace / wheel mounts; attribute Needed (bool)
	  Any Lootable / RepairStation / AttachPoint contains a BindableEvent named "NPCInteract".
	  Your game's server code listens to it and performs the real action (grant fuel, mount
	  wheel, repair). NPCs cannot trigger ProximityPrompts (those are player-input driven),
	  so this event is the explicit, developer-owned hook.
	  Tool attributes (optional): Range (studs), Cooldown (seconds)

	STATE MACHINE:
	  IDLE -> SCAVENGING -> RETURNING -> IDLE
	  Any state can be preempted by DEFENDING or REPAIRING when their utility wins.
]]

local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")

local npc = script.Parent
local humanoid = npc:WaitForChild("Humanoid") :: Humanoid
local rootPart = npc:WaitForChild("HumanoidRootPart") :: BasePart

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local CONFIG = {
	HostileTag = "Hostile",
	VehicleTag = "BaseVehicle",
	LootTag = "Lootable",
	RepairTag = "RepairStation",
	AttachTag = "AttachPoint",

	DecisionInterval = 0.15,   -- how often the brain re-evaluates utilities
	VehiclePollInterval = 0.5, -- attribute polling rate for the bus
	ThreatScanInterval = 0.5,  -- GetDescendants is expensive; cache between scans
	ThreatScanRadius = 80,

	RepairThreshold = 0.3,     -- Health/MaxHealth below this triggers repair workflow
	DefaultWeaponRange = 8,
	DefaultWeaponCooldown = 0.6,

	-- Fairness model: gaussian reaction delay before engaging a NEW target.
	-- Keeps the companion from feeling like an instant-aim turret.
	ReactionMeanSec = 0.150,
	ReactionStdSec = 0.050,
	ReactionMinSec = 0.050,

	MinStateDwell = 1.0,       -- seconds; prevents state flapping
	HysteresisBonus = 0.08,    -- current state gets a small utility bonus
	WaypointTimeout = 4,
	BaseStopDistance = 10,

	Agent = {
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = false,
	},

	-- Utility weights for threat priority (sum ~1). Tune per game.
	Weights = {
		Proximity = 0.45,   -- closer enemies matter more
		LineOfSight = 0.20, -- visible enemies are actionable
		Weakness = 0.15,    -- finish low-health enemies
		BusThreat = 0.20,   -- enemies near the bus are prioritised
	},
}

---------------------------------------------------------------------
-- UTILITIES
---------------------------------------------------------------------
local rng = Random.new()

-- Box-Muller transform: gaussian sample, clamped.
local function gaussian(mu: number, sigma: number, minValue: number): number
	local u1 = 1 - rng:NextNumber() -- (0,1]
	local u2 = rng:NextNumber()
	local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
	return math.max(minValue, mu + sigma * z)
end

local function clamp01(x: number): number
	return math.clamp(x, 0, 1)
end

local function getModelRoot(inst: Instance?): BasePart?
	if not inst then return nil end
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- Server-side NPC network ownership avoids client physics ownership hitches.
pcall(function() rootPart:SetNetworkOwner(nil) end)

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
type Threat = { model: Model, humanoid: Humanoid, root: BasePart, dist: number, priority: number }

local state = "IDLE"
local stateEnteredAt = os.clock()
local carrying = false              -- true after a successful loot, until delivered
local currentLoot: Instance? = nil
local vehicleRatio = 1
local vehicle: Model? = nil
local threats: { Threat } = {}
local bestThreat: Threat? = nil
local lastThreatScan = 0
local lastAttack = 0
local lockedTarget: Model? = nil

local function setState(newState: string)
	if newState == state then return end
	state = newState
	stateEnteredAt = os.clock()
	npc:SetAttribute("AIState", newState) -- handy for debugging / thesis logging
end

---------------------------------------------------------------------
-- 1. THREAT RESPONSE
---------------------------------------------------------------------
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.FilterDescendantsInstances = { npc }

local function hasLineOfSight(target: Model, targetRoot: BasePart): boolean
	local origin = rootPart.Position + Vector3.new(0, 1.5, 0)
	local result = workspace:Raycast(origin, targetRoot.Position - origin, losParams)
	return result == nil or result.Instance:IsDescendantOf(target)
end

local function scanThreats()
	local now = os.clock()
	if now - lastThreatScan < CONFIG.ThreatScanInterval then return end
	lastThreatScan = now

	local found: { Threat } = {}
	local vehicleRoot = getModelRoot(vehicle)

	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Humanoid") and d.Health > 0 and d ~= humanoid then
			local model = d.Parent
			if model and model:IsA("Model") and CollectionService:HasTag(model, CONFIG.HostileTag) then
				local root = model:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					local dist = (root.Position - rootPart.Position).Magnitude
					if dist <= CONFIG.ThreatScanRadius then
						-- Priority: weighted sum of normalised factors (each 0..1).
						local w = CONFIG.Weights
						local proximity = 1 - clamp01(dist / CONFIG.ThreatScanRadius)
						local los = hasLineOfSight(model, root) and 1 or 0
						local weakness = 1 - clamp01(d.Health / math.max(d.MaxHealth, 1))
						local busThreat = 0
						if vehicleRoot then
							busThreat = 1 - clamp01((root.Position - vehicleRoot.Position).Magnitude / 40)
						end
						local priority = w.Proximity * proximity + w.LineOfSight * los
							+ w.Weakness * weakness + w.BusThreat * busThreat
						table.insert(found, {
							model = model, humanoid = d, root = root, dist = dist, priority = priority,
						})
					end
				end
			end
		end
	end

	table.sort(found, function(a, b) return a.priority > b.priority end)
	threats = found
	bestThreat = found[1]
end

local function getTool(): Tool?
	return npc:FindFirstChildOfClass("Tool")
end

local function faceTowards(pos: Vector3)
	-- Smoothed turn on the NPC's own root (yaw only).
	local flat = Vector3.new(pos.X - rootPart.Position.X, 0, pos.Z - rootPart.Position.Z)
	if flat.Magnitude < 0.1 then return end
	local goal = CFrame.lookAt(rootPart.Position, rootPart.Position + flat)
	rootPart.CFrame = rootPart.CFrame:Lerp(goal, 0.35)
end

local function defendStep()
	local t = bestThreat
	if not t or t.humanoid.Health <= 0 then
		lockedTarget = nil
		return
	end

	-- New target? Apply a human-scale reaction delay (see CONFIG fairness model).
	if lockedTarget ~= t.model then
		lockedTarget = t.model
		task.wait(gaussian(CONFIG.ReactionMeanSec, CONFIG.ReactionStdSec, CONFIG.ReactionMinSec))
		if t.humanoid.Health <= 0 then return end
	end

	local tool = getTool()
	local range = (tool and tool:GetAttribute("Range")) or CONFIG.DefaultWeaponRange
	local cooldown = (tool and tool:GetAttribute("Cooldown")) or CONFIG.DefaultWeaponCooldown
	local dist = (t.root.Position - rootPart.Position).Magnitude

	if dist > range * 0.9 then
		humanoid:MoveTo(t.root.Position) -- close distance; MoveDirection drives animations naturally
	else
		humanoid:MoveTo(rootPart.Position) -- stop and fight
		faceTowards(t.root.Position)
		if tool and os.clock() - lastAttack >= cooldown then
			lastAttack = os.clock()
			tool:Activate() -- fires Tool.Activated for server-side weapon scripts
		end
	end
end

---------------------------------------------------------------------
-- NAVIGATION (PathfindingService + Humanoid:MoveTo; no CFrame teleporting)
---------------------------------------------------------------------
local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function pathTo(dest: Vector3, stopDist: number, shouldAbort: () -> boolean): boolean
	local path = PathfindingService:CreatePath(CONFIG.Agent)
	local ok = pcall(function() path:ComputeAsync(rootPart.Position, dest) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then return false end

	for _, wp in ipairs(path:GetWaypoints()) do
		if wp.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
		humanoid:MoveTo(wp.Position)
		local started = os.clock()
		while flatDist(rootPart.Position, wp.Position) > 3 do
			if shouldAbort() then return false end
			if (rootPart.Position - dest).Magnitude <= stopDist then return true end
			if os.clock() - started > CONFIG.WaypointTimeout then return false end -- stuck: replan
			task.wait(0.1)
		end
	end
	return (rootPart.Position - dest).Magnitude <= stopDist + 3
end

-- Developer-owned interaction hook (see header). Simulates a hold duration.
local function interact(target: Instance): boolean
	local ev = target:FindFirstChild("NPCInteract")
	if not (ev and ev:IsA("BindableEvent")) then return false end
	local hold = target:GetAttribute("HoldDuration") or 0.5
	task.wait(hold + gaussian(0.05, 0.02, 0))
	ev:Fire(npc)
	return true
end

---------------------------------------------------------------------
-- 2. RESOURCE PROCUREMENT: IDLE -> SCAVENGING -> RETURNING -> IDLE
---------------------------------------------------------------------
local function findNearestLoot(): Instance?
	local best, bestDist = nil, math.huge
	for _, inst in ipairs(CollectionService:GetTagged(CONFIG.LootTag)) do
		if not inst:GetAttribute("Looted") then
			local root = getModelRoot(inst)
			if root then
				local d = (root.Position - rootPart.Position).Magnitude
				if d < bestDist then best, bestDist = inst, d end
			end
		end
	end
	return best
end

local function scavengeStep(shouldAbort: () -> boolean)
	if not currentLoot or currentLoot:GetAttribute("Looted") then
		currentLoot = findNearestLoot()
	end
	local loot = currentLoot
	local root = getModelRoot(loot)
	if not (loot and root) then
		setState("IDLE")
		return
	end
	if pathTo(root.Position, 5, shouldAbort) then
		if interact(loot) then
			carrying = true
			currentLoot = nil
			setState("RETURNING")
		else
			loot:SetAttribute("Looted", true) -- unusable container; avoid retry loop
			currentLoot = nil
		end
	else
		currentLoot = nil -- unreachable or preempted; re-pick next tick
	end
end

local function returnStep(shouldAbort: () -> boolean)
	local root = getModelRoot(vehicle)
	if not root then
		carrying = false
		setState("IDLE")
		return
	end
	if pathTo(root.Position, CONFIG.BaseStopDistance, shouldAbort) then
		carrying = false
		setState("IDLE")
	end
end

---------------------------------------------------------------------
-- 3. MOBILE BASE MAINTENANCE
---------------------------------------------------------------------
local function repairStep(shouldAbort: () -> boolean)
	-- (a) visit a repair station
	local station = CollectionService:GetTagged(CONFIG.RepairTag)[1]
	local stationRoot = getModelRoot(station)
	if station and stationRoot and pathTo(stationRoot.Position, 5, shouldAbort) then
		interact(station)
	end
	-- (b) service any component mount that still needs something (fuel, wheel, ...)
	for _, point in ipairs(CollectionService:GetTagged(CONFIG.AttachTag)) do
		if shouldAbort() then return end
		if point:GetAttribute("Needed") then
			local pr = getModelRoot(point)
			if pr and pathTo(pr.Position, 5, shouldAbort) then
				interact(point)
			end
		end
	end
end

local function pollVehicle()
	while npc.Parent do
		vehicle = CollectionService:GetTagged(CONFIG.VehicleTag)[1] :: Model?
		if vehicle then
			local hp = vehicle:GetAttribute("Health") or 0
			local maxHp = vehicle:GetAttribute("MaxHealth") or 1
			vehicleRatio = hp / math.max(maxHp, 1)
		end
		task.wait(CONFIG.VehiclePollInterval)
	end
end

---------------------------------------------------------------------
-- 4. UTILITY BRAIN + WAVE AWARENESS
---------------------------------------------------------------------
-- Each candidate state gets a 0..1 score; highest wins. Rationale:
--  DEFENDING : best threat priority, amplified during Assault, damped in Calm.
--  REPAIRING : dominant when the bus is below threshold (scaled by how far below).
--  RETURNING : must deliver what it carries (medium-high, but defence can preempt).
--  SCAVENGING: only worthwhile in Calm and when loot exists.
--  IDLE      : small baseline so the NPC doesn't act without reason.
local function computeUtilities(): { [string]: number }
	local assault = workspace:GetAttribute("WavePhase") == "Assault"
	local u = {
		IDLE = 0.10,
		DEFENDING = 0,
		REPAIRING = 0,
		RETURNING = carrying and 0.55 or 0,
		SCAVENGING = 0,
	}
	if bestThreat then
		u.DEFENDING = clamp01(bestThreat.priority * (assault and 1.4 or 0.8))
	end
	if vehicleRatio < CONFIG.RepairThreshold then
		u.REPAIRING = 0.65 + (CONFIG.RepairThreshold - vehicleRatio)
	end
	if not assault and not carrying and findNearestLoot() then
		u.SCAVENGING = 0.5
	end
	-- Hysteresis: small bonus for the current state to avoid flapping.
	if u[state] ~= nil then u[state] += CONFIG.HysteresisBonus end
	return u
end

local function chooseState()
	if os.clock() - stateEnteredAt < CONFIG.MinStateDwell then return end
	local u = computeUtilities()
	local best, bestScore = state, -1
	for name, score in pairs(u) do
		if score > bestScore then best, bestScore = name, score end
	end
	setState(best)
end

---------------------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------------------
task.spawn(pollVehicle)
npc:SetAttribute("AIState", state)

while npc.Parent and humanoid.Health > 0 do
	scanThreats()
	chooseState()

	-- Long actions abort when a higher-priority state clearly takes over.
	local function shouldAbort(): boolean
		if humanoid.Health <= 0 then return true end
		scanThreats()
		local u = computeUtilities()
		return (u[state] or 0) < (math.max(u.DEFENDING, u.REPAIRING)) - 0.05 and state ~= "DEFENDING"
	end

	if state == "DEFENDING" then
		defendStep()
	elseif state == "REPAIRING" then
		repairStep(shouldAbort)
	elseif state == "SCAVENGING" then
		scavengeStep(shouldAbort)
	elseif state == "RETURNING" then
		returnStep(shouldAbort)
	else
		humanoid:MoveTo(rootPart.Position) -- IDLE: hold position
	end

	task.wait(CONFIG.DecisionInterval)
end
