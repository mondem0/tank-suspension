--!strict
--[[
    TankController.server.lua
    -------------------------
    Server Script intended to be parented under a tank Model. It resolves the
    TankSuspension module, constructs a controller, and mirrors VehicleSeat input
    into throttle/steer commands.

    Installation steps:
      1. Place this Script under your tank Model.
      2. Ensure a ModuleScript containing TankSuspension.lua is available. By default
         the script looks for:
             - A child ModuleScript named "TankSuspensionModule".
             - A sibling ModuleScript named "TankSuspension" inside the model.
             - `ServerScriptService.TankSuspension` as a fallback.
      3. Play the game; the script will wire up the suspension automatically.
]]

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

if RunService:IsClient() then
    warn("TankController.server.lua should only run on the server")
    return
end

local function resolveModule(): ModuleScript
    local moduleCandidate = script:FindFirstChild("TankSuspensionModule")
    if moduleCandidate and moduleCandidate:IsA("ModuleScript") then
        return moduleCandidate
    end

    local sibling = script.Parent:FindFirstChild("TankSuspension")
    if sibling and sibling:IsA("ModuleScript") then
        return sibling
    end

    local sharedModule = ServerScriptService:FindFirstChild("TankSuspension")
    if sharedModule and sharedModule:IsA("ModuleScript") then
        return sharedModule
    end

    error("TankSuspension module not found. Provide a ModuleScript named 'TankSuspensionModule' as a child of the controller script or place the module in ServerScriptService.")
end

local TankSuspension = require(resolveModule())

-- Change these numbers to tune how the suspension feels.
local SETTINGS = {
    Suspension = {
        RestLength = 1.8,
        SpringStiffness = 28000,
        Damping = 4200,
        PreloadForce = 2200,
        RaycastLength = 5,
        WheelRadius = 1.2,
        MaxForceMultiplier = 3,
        AntiRollStiffness = 4200,
        MassSmoothing = 6,
        AirDamping = 450,
        UseAttachmentUp = true,
    },
    Traction = {
        LongitudinalStiffness = 2400,
        LateralStiffness = 3100,
        RollingDrag = 160,
        GripCoefficient = 1.1,
    },
    Drive = {
        MaxForwardSpeed = 22,
        MaxReverseSpeed = 10,
        TurnRate = 0.4,
        DriveForce = 11000,
        IdleBrakeForce = 3200,
        HandBrakeForce = 18000,
    },
}

local tankModel = script.Parent
if not tankModel or not tankModel:IsA("Model") then
    error("TankController.server.lua must be parented under the tank Model")
end

local driverSeat = tankModel:FindFirstChild("DriverSeat")
if not driverSeat or not driverSeat:IsA("VehicleSeat") then
    error("Tank model is missing VehicleSeat 'DriverSeat'")
end

local controller = TankSuspension.new(tankModel, SETTINGS)
controller:Bind()
controller:SetHandBrake(true)
controller:SetThrottle(0)
controller:SetSteer(0)

local function updateInput()
    controller:SetThrottle(driverSeat.ThrottleFloat)
    controller:SetSteer(driverSeat.SteerFloat)
end

driverSeat:GetPropertyChangedSignal("ThrottleFloat"):Connect(updateInput)

driverSeat:GetPropertyChangedSignal("SteerFloat"):Connect(updateInput)

driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
    local humanoid = driverSeat.Occupant
    if humanoid then
        controller:SetHandBrake(false)
        updateInput()
    else
        controller:SetThrottle(0)
        controller:SetSteer(0)
        controller:SetHandBrake(true)
    end
end)

-- Ensure state is correct if someone is already seated when the script runs.
if driverSeat.Occupant then
    controller:SetHandBrake(false)
    updateInput()
end

script.Destroying:Connect(function()
    controller:Destroy()
end)
