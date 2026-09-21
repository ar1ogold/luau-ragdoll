-- Connected Discord-GitHub
--!strict -- Strict type checking so every table shape and nil path below is verified by the Luau analyzer before runtime.
-- Ragdoll.luau | Server ModuleScript from "Cross the Road for Eggs" (ServerScriptService.Server.Characters.Ragdoll)
-- Turns a live character rig into a physics ragdoll when a car hits it, then rebuilds the rig and stands the player back up.
-- Tunables live in ReplicatedStorage.Shared.Config.Roads.RoadConfig.Ragdoll so designers can tweak without touching this file.

local Players = game:GetService("Players") -- Needed to map a character Model back to its Player for network ownership hand-back.
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Shared modules (config + signal) are replicated here so both sides agree on values.
local PhysicsService = game:GetService("PhysicsService") -- Collision groups are the only way to stop ragdoll limbs colliding with each other.

local RoadConfig = require(ReplicatedStorage.Shared.Config.Roads.RoadConfig) -- Config-driven: angles, durations, probe distances all come from here.
local Signal = require(ReplicatedStorage.Shared.Util.Signal) -- Lightweight custom event so other services can react to "ragdoll applied" without coupling.

local FOLDER_NAME = RoadConfig.Ragdoll.FolderName -- Every constraint we create lives in one named Folder so cleanup is a single Destroy.

type SocketSettings = { -- Snapshot of a BallSocketConstraint's limits so a pre-existing socket can be restored exactly, not guessed.
	LimitsEnabled: boolean,
	UpperAngle: number,
	TwistLimitsEnabled: boolean,
	TwistLowerAngle: number,
	TwistUpperAngle: number,
}

type State = { -- Everything Enable() changes is recorded here so Disable() can undo it in reverse (undo-log pattern).
	Character: Model,
	Humanoid: Humanoid,
	Folder: Folder, -- Holds the sockets/colliders we spawned.
	Motors: { Motor6D }, -- Rig joints we disabled; re-enabling them re-animates the rig.
	AnimationConstraints: { AnimationConstraint }, -- R15 rigs may use these instead of Motor6Ds; handled the same way.
	Sockets: { [BallSocketConstraint]: SocketSettings }, -- Sockets that already existed in the rig, keyed by instance for O(1) restore.
	Collisions: { [BasePart]: boolean }, -- Original CanCollide per part; limbs normally don't collide, ragdolls must.
	Groups: { [BasePart]: string }, -- Original CollisionGroup per part so the character returns to its normal group.
	OwnerRestored: boolean,
	RestoreThread: thread?, -- The scheduled "stand up" coroutine; kept so it can be cancelled on re-hit or death.
	DiedConnection: RBXScriptConnection?, -- Disconnected on cleanup to avoid leaking a listener per hit.
}

local Ragdoll = {}

Ragdoll.Applied = Signal.new() -- Public event: (character, duration). Camera shake / SFX / analytics subscribe to this.
local states: { [Model]: State } = {} -- Character -> State. Model keys are weak in practice because Forget() clears them on removal.
local groupReady = false -- Collision group registration is global and must only run once per server.

local function ensureCollisionGroup(): string? -- Registers the ragdoll collision group lazily on first use and returns its name.
	local settings = RoadConfig.Ragdoll.Colliders
	if not settings.Enabled then -- Feature flag: colliders can be turned off entirely from config.
		return nil
	end
	local group = settings.CollisionGroup
	if not groupReady then
		if not PhysicsService:IsCollisionGroupRegistered(group) then -- Guard against a duplicate-registration error after a script reload.
			PhysicsService:RegisterCollisionGroup(group)
		end
		PhysicsService:CollisionGroupSetCollidable(group, group, false) -- Ragdoll parts ignore each other so limbs never jitter or explode.
		groupReady = true
	end
	return group
end

local function buildCollider(part: BasePart, folder: Folder, group: string) -- Invisible hitbox welded to a limb; gives the ragdoll volume without changing the visible mesh.
	local settings = RoadConfig.Ragdoll.Colliders
	local collider = Instance.new("Part")
	collider.Name = part.Name .. "Collider"
	collider.Size = part.Size * settings.Scale -- Slightly smaller/larger than the limb (config) so joints don't self-intersect.
	collider.CFrame = part.CFrame -- Spawn exactly on top of the limb so the weld captures a zero offset.
	collider.Transparency = 1 -- Physics only; the player never sees it.
	collider.CanCollide = true -- This is the part that actually hits the ground.
	collider.CanQuery = false -- Excluded from raycasts so our own ground probes don't hit it.
	collider.CanTouch = false -- No Touched events; avoids firing car-hit logic twice.
	collider.CastShadow = false -- Minor render saving since it's invisible anyway.
	collider.Massless = true -- Doesn't change the assembly's mass, so the fling force from the car stays predictable.
	collider.CollisionGroup = group
	local weld = Instance.new("WeldConstraint") -- WeldConstraint (not Weld) keeps current relative CFrame with no C0/C1 math.
	weld.Part0 = part
	weld.Part1 = collider
	weld.Parent = collider
	collider.Parent = folder -- Parented to our folder, not the limb, so destroyFolder() removes it in one pass.
end

local function getParts(character: Model): { BasePart } -- Flat list of every BasePart in the rig (limbs + accessories).
	local parts = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function setNetworkOwner(character: Model, owner: Player?) -- nil owner = server simulates; Player = that client simulates.
	for _, part in getParts(character) do
		if part.Anchored then -- SetNetworkOwner errors on anchored parts, so skip them.
			continue
		end
		pcall(part.SetNetworkOwner, part, owner) -- pcall because welded/massless parts can still reject ownership changes.
	end
end

local function isRootJoint(part0: BasePart?, root: BasePart): boolean -- The RootJoint links HumanoidRootPart to the torso; it must stay so the Humanoid keeps tracking the body.
	return part0 == root
end

local function isAccessoryPart(part: BasePart): boolean -- Hats/tools are cosmetic; whether they collide is a config choice.
	return part:FindFirstAncestorOfClass("Accessory") ~= nil or part:FindFirstAncestorOfClass("Tool") ~= nil
end

local function captureSocket(socket: BallSocketConstraint): SocketSettings -- Copy current limits before we loosen them.
	return {
		LimitsEnabled = socket.LimitsEnabled,
		UpperAngle = socket.UpperAngle,
		TwistLimitsEnabled = socket.TwistLimitsEnabled,
		TwistLowerAngle = socket.TwistLowerAngle,
		TwistUpperAngle = socket.TwistUpperAngle,
	}
end

local function loosenSocket(socket: BallSocketConstraint) -- Applies the "floppy" joint profile from config.
	local settings = RoadConfig.Ragdoll
	socket.LimitsEnabled = settings.LimitsEnabled -- Cone limit keeps elbows/knees from bending backwards.
	socket.UpperAngle = settings.UpperAngle -- Half-angle of that cone in degrees.
	socket.TwistLimitsEnabled = settings.LimitsEnabled
	socket.TwistLowerAngle = -settings.TwistAngle -- Symmetric twist range around the joint axis.
	socket.TwistUpperAngle = settings.TwistAngle
	socket.MaxFrictionTorque = 0 -- No joint friction, so the body flops instead of freezing mid-air.
	socket.Restitution = 0 -- No bounce when a limit is hit; avoids the twitchy "vibrating ragdoll" look.
end

local function unstuck(character: Model, humanoid: Humanoid) -- After standing up, lift the character if the ragdoll ended half inside the floor.
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local settings = RoadConfig.Ragdoll
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character } -- Ignore our own limbs or the ray would hit the torso immediately.
	local origin = root.Position + Vector3.new(0, settings.UnstuckProbeHeight, 0) -- Start above the head so a sunken root still finds the floor.
	local hit = workspace:Raycast(origin, Vector3.new(0, -(settings.UnstuckProbeHeight + settings.UnstuckProbeDepth), 0), params) -- Straight down past the feet.
	if not hit then -- Mid-air (fell off the map / on a ramp edge): let gravity handle it.
		return
	end
	local standingHeight = hit.Position.Y + humanoid.HipHeight + root.Size.Y / 2 -- Where the root's centre sits when the Humanoid is standing normally.
	if root.Position.Y >= standingHeight - settings.UnstuckTolerance then -- Already at (or above) standing height: nothing to fix.
		return
	end
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z) -- Drop the pitch so the character is placed upright, keeping only its yaw.
	local yaw = if flat.Magnitude > 0.001 then flat.Unit else Vector3.zAxis -- If the body was facing straight down, fall back to a safe forward vector.
	local target = Vector3.new(root.Position.X, standingHeight + settings.UnstuckLift, root.Position.Z) -- Same XZ, corrected Y (+ small lift to clear the surface).
	character:PivotTo(CFrame.lookAt(target, target + yaw)) -- PivotTo moves the whole assembly; lookAt rebuilds an upright rotation from the yaw only.
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = Vector3.zero -- Kill leftover fling velocity so the teleport doesn't launch the player.
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function restoreSocket(socket: BallSocketConstraint, settings: SocketSettings) -- Inverse of loosenSocket using the captured snapshot.
	socket.LimitsEnabled = settings.LimitsEnabled
	socket.UpperAngle = settings.UpperAngle
	socket.TwistLimitsEnabled = settings.TwistLimitsEnabled
	socket.TwistLowerAngle = settings.TwistLowerAngle
	socket.TwistUpperAngle = settings.TwistUpperAngle
end

local function attachmentPart(attachment: Attachment?): BasePart? -- AnimationConstraints reference Attachments; we need the part that owns the attachment.
	local parent = if attachment then attachment.Parent else nil
	return if parent and parent:IsA("BasePart") then parent else nil
end

local function buildSocket(motor: Motor6D, folder: Folder) -- Mirrors one Motor6D as a BallSocketConstraint at the exact same pivot.
	local part0 = motor.Part0
	local part1 = motor.Part1
	if not part0 or not part1 then -- Half-built joint (e.g. accessory mid-load); skip rather than error.
		return
	end
	local attachment0 = Instance.new("Attachment")
	attachment0.Name = motor.Name .. "_A0"
	attachment0.CFrame = motor.C0 -- Motor6D.C0 is the joint offset in Part0 space; an Attachment's CFrame is also parent-part space, so it maps 1:1.
	attachment0.Parent = part0

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = motor.Name .. "_A1"
	attachment1.CFrame = motor.C1 -- Same for C1 in Part1 space; both attachments now coincide in world space, so the socket pivots exactly where the joint was.
	attachment1.Parent = part1

	local socket = Instance.new("BallSocketConstraint")
	socket.Name = motor.Name -- Keeping the joint name makes debugging in the Explorer trivial.
	socket.Attachment0 = attachment0
	socket.Attachment1 = attachment1
	loosenSocket(socket)
	socket.Parent = folder

	local noCollision = Instance.new("NoCollisionConstraint") -- Adjacent limbs overlap at the joint; without this they'd push each other apart violently.
	noCollision.Part0 = part0
	noCollision.Part1 = part1
	noCollision.Parent = folder

	local cleanup0 = Instance.new("ObjectValue") -- The attachments live inside the limbs, not our folder, so we store references to find them at cleanup.
	cleanup0.Name = "Attachment0"
	cleanup0.Value = attachment0
	cleanup0.Parent = socket
	local cleanup1 = Instance.new("ObjectValue")
	cleanup1.Name = "Attachment1"
	cleanup1.Value = attachment1
	cleanup1.Parent = socket
end

local function destroyFolder(folder: Folder) -- Removes sockets, colliders and the attachments they reference in one sweep.
	for _, socket in folder:GetChildren() do
		for _, ref in socket:GetChildren() do
			if ref:IsA("ObjectValue") and ref.Value then
				ref.Value:Destroy() -- Destroys the Attachment sitting inside the limb.
			end
		end
	end
	folder:Destroy() -- Destroy() also disconnects every constraint parented under it.
end

function Ragdoll.IsRagdolled(character: Model): boolean -- Cheap query other systems (car hits, tools) use to skip an already-downed player.
	return states[character] ~= nil
end

function Ragdoll.Enable(character: Model): boolean -- Converts the rig into a ragdoll; returns false if the character isn't usable yet.
	if states[character] then -- Idempotent: hitting a ragdolled player again must not double-build constraints.
		return true
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return false
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	local motors: { Motor6D } = {}
	local animationConstraints: { AnimationConstraint } = {}
	local sockets: { [BallSocketConstraint]: SocketSettings } = {}
	local collisions: { [BasePart]: boolean } = {}
	local groups: { [BasePart]: string } = {}
	local group = ensureCollisionGroup()

	humanoid.BreakJointsOnDeath = false -- If the player dies while flying, keep the joints so the ragdoll doesn't shatter into loose parts.
	humanoid.RequiresNeck = false -- Disabling the Neck motor would otherwise instantly kill the Humanoid.
	humanoid.AutoRotate = false -- Stops the Humanoid trying to yaw the torso upright while it's supposed to be limp.

	for _, descendant in character:GetDescendants() do -- Single pass classifies every relevant instance; avoids four separate GetDescendants calls.
		if descendant:IsA("Motor6D") then
			if not isRootJoint(descendant.Part0, root) then -- Keep RootJoint alive so HumanoidRootPart still follows the torso.
				buildSocket(descendant, folder)
				table.insert(motors, descendant)
			end
		elseif descendant:IsA("AnimationConstraint") then
			if not isRootJoint(attachmentPart(descendant.Attachment0), root) then
				table.insert(animationConstraints, descendant)
			end
		elseif descendant:IsA("BallSocketConstraint") then -- Rig already had sockets (custom avatars): remember their limits before loosening.
			sockets[descendant] = captureSocket(descendant)
		elseif descendant:IsA("BasePart") then
			if RoadConfig.Ragdoll.AccessoriesCollide or not isAccessoryPart(descendant) then
				collisions[descendant] = descendant.CanCollide
				if group then
					groups[descendant] = descendant.CollisionGroup
					descendant.CollisionGroup = group -- Move limb into the self-ignoring group.
					if descendant.Parent == character and not table.find(RoadConfig.Ragdoll.Colliders.Skip, descendant.Name) then -- Only direct body parts get hitboxes; config can skip e.g. the root.
						buildCollider(descendant, folder, group)
					end
				end
			end
		end
	end

	folder.Parent = character -- Parent last so constraints activate in one physics step instead of one at a time.
	if RoadConfig.Ragdoll.ServerOwnsPhysics then
		setNetworkOwner(character, nil) -- Server simulation stops exploiters from freezing/flying their own ragdoll and keeps the fling deterministic.
	end

	for _, motor in motors do
		motor.Enabled = false -- Disabling (not destroying) the Motor6D means the sockets take over and re-enabling later restores animation.
	end
	for _, constraint in animationConstraints do
		constraint.Enabled = false
	end
	for socket in sockets do
		loosenSocket(socket)
	end
	for part in collisions do
		part.CanCollide = part ~= root or RoadConfig.Ragdoll.RootCanCollide -- Limbs collide with the world; root usually doesn't, so it can't prop the body up.
	end

	humanoid.PlatformStand = true -- Disables the Humanoid's balance forces; without this it would fight the physics and stand back up.
	humanoid:ChangeState(Enum.HumanoidStateType.Physics) -- Physics state hands full control of the assembly to the solver.

	local state: State = {
		Character = character,
		Humanoid = humanoid,
		Folder = folder,
		Motors = motors,
		AnimationConstraints = animationConstraints,
		Sockets = sockets,
		Collisions = collisions,
		Groups = groups,
		OwnerRestored = false,
		RestoreThread = nil,
		DiedConnection = nil,
	}
	states[character] = state

	state.DiedConnection = humanoid.Died:Connect(function() -- Dead players stay ragdolled; cancel the pending stand-up so it never fights the respawn.
		if state.RestoreThread then
			task.cancel(state.RestoreThread)
			state.RestoreThread = nil
		end
	end)
	character.AncestryChanged:Connect(function(_, parent) -- Character removed (respawn/leave): drop the state so the table doesn't hold a dead Model.
		if parent == nil then
			Ragdoll.Forget(character)
		end
	end)
	return true
end

function Ragdoll.Disable(character: Model) -- Reverses everything Enable() recorded, then stands the player up.
	local state = states[character]
	if not state then
		return
	end
	if state.Humanoid.Health <= 0 then -- Never rebuild a dead rig; Roblox handles the corpse/respawn.
		return
	end
	Ragdoll.Forget(character) -- Clear bookkeeping first so a re-hit during this function starts a fresh Enable().

	for _, motor in state.Motors do
		if motor.Parent then -- Parent check: a limb may have been destroyed (e.g. accessory removed) mid-ragdoll.
			motor.Enabled = true
		end
	end
	for _, constraint in state.AnimationConstraints do
		if constraint.Parent then
			constraint.Enabled = true
		end
	end
	for socket, settings in state.Sockets do
		if socket.Parent then
			restoreSocket(socket, settings)
		end
	end
	for part, canCollide in state.Collisions do
		if part.Parent then
			part.CanCollide = canCollide
		end
	end
	for part, groupName in state.Groups do
		if part.Parent then
			part.CollisionGroup = groupName
		end
	end
	if state.Folder.Parent then
		destroyFolder(state.Folder)
	end

	state.Humanoid.PlatformStand = false -- Give balance control back to the Humanoid.
	state.Humanoid.AutoRotate = true
	state.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) -- Plays the built-in get-up transition instead of snapping to Running.
	task.defer(unstuck, character, state.Humanoid) -- Defer one frame so the re-enabled motors settle before we measure the root height.

	local player = Players:GetPlayerFromCharacter(character)
	if player and RoadConfig.Ragdoll.ServerOwnsPhysics then
		setNetworkOwner(character, player) -- Hand simulation back to the client so movement feels responsive again.
	end
end

function Ragdoll.Forget(character: Model) -- Drops state + cancels timers without touching the rig (used on removal and at the start of Disable).
	local state = states[character]
	if not state then
		return
	end
	states[character] = nil
	if state.RestoreThread then
		task.cancel(state.RestoreThread) -- Prevents an old timer from calling Disable() on a state that no longer exists.
		state.RestoreThread = nil
	end
	if state.DiedConnection then
		state.DiedConnection:Disconnect()
		state.DiedConnection = nil
	end
end

local function isResting(character: Model): boolean -- "Has the body stopped moving and is it on the ground?" used for early recovery.
	local settings = RoadConfig.Ragdoll.EarlyRecover
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	if root.AssemblyLinearVelocity.Magnitude > settings.RestSpeed then -- Still sliding/flying: not resting.
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.RespectCanCollide = true -- Ignore non-solid decor so a ragdoll draped over a bush isn't treated as grounded.
	return workspace:Raycast(root.Position, Vector3.new(0, -settings.GroundProbe, 0), params) ~= nil
end

local function watchRest(state: State, duration: number) -- Polls the body and ends the ragdoll early once it has been still long enough.
	local settings = RoadConfig.Ragdoll.EarlyRecover
	local character = state.Character
	local started = os.clock() -- os.clock() is monotonic and high-resolution; tick()/time() would drift with server load.
	local restingSince: number? = nil
	while states[character] == state do -- Identity check: if a new hit replaced the state, this loop must exit silently.
		task.wait(0.05) -- 20 Hz is plenty for a "has it stopped" check and far cheaper than Heartbeat.
		local elapsed = os.clock() - started
		if elapsed >= duration then -- Hard cap reached: stand up regardless.
			break
		end
		if elapsed < settings.MinDuration then -- Guarantee a minimum flop time so short hits still read as hits.
			continue
		end
		if isResting(character) then
			restingSince = restingSince or os.clock() -- Start the rest timer only on the first resting frame.
			if os.clock() - restingSince >= settings.RestTime then
				break
			end
		else
			restingSince = nil -- Moved again: reset the rest timer.
		end
	end
	if states[character] == state then
		state.RestoreThread = nil
		Ragdoll.Disable(character)
	end
end

function Ragdoll.Apply(character: Model, duration: number): boolean -- Public entry point: ragdoll for `duration` seconds (car hit calls this).
	if not Ragdoll.Enable(character) then
		return false
	end
	local state = states[character]
	if state.RestoreThread then
		task.cancel(state.RestoreThread) -- A second hit restarts the timer instead of stacking two stand-ups.
	end
	local maxDuration = RoadConfig.Ragdoll.MaxDuration
	if maxDuration > 0 then
		duration = math.min(duration, maxDuration) -- Config ceiling so no caller can leave a player down indefinitely.
	end
	if RoadConfig.Ragdoll.EarlyRecover.Enabled then
		state.RestoreThread = task.spawn(watchRest, state, duration) -- Coroutine handle kept so it can be cancelled.
	else
		state.RestoreThread = task.delay(duration, function() -- Simple fixed timer when early recovery is off.
			state.RestoreThread = nil
			Ragdoll.Disable(character)
		end)
	end
	Ragdoll.Applied:Fire(character, duration) -- Notify listeners (camera shake, SFX, analytics) after the physics is fully set up.
	return true
end

return Ragdoll
