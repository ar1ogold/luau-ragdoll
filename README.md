# Ragdoll.luau — Cross the Road for Eggs

Server-side ragdoll system used in https://www.roblox.com/games/117222130419846/Cross-the-Road-for-Eggs

**Demo:** join the game and get hit by a car on any road. The character ragdolls
(BallSocketConstraints mirrored from the rig's Motor6Ds, collision group, server-owned physics),
recovers early once it stops moving, and is lifted out of the floor with a raycast + CFrame fix-up.

Tunables live in `ReplicatedStorage.Shared.Config.Roads.RoadConfig.Ragdoll`.
Requires the game's `Signal` util (small custom event class).
