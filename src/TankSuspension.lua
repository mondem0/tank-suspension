--!strict
--[[
    TankSuspension.lua
    -------------------
    Raycast-based tank suspension and traction controller. Each wheel is defined by a
    single Attachment on the hull. The module casts a ray from the attachment toward the
    ground, applies a spring/damper force, and adds planar forces for traction and
    steering. All tuning happens through the settings table passed into `new` or by
    editing the defaults below.

    Usage:
        local TankSuspension = require(path.to.TankSuspension)
        local controller = TankSuspension.new(tankModel, settings?)
        controller:Bind()
        controller:SetThrottle(0.5)
        controller:SetSteer(-0.25)
        controller:SetHandBrake(false)

    See README.md for the required attachment names and how to orient them.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type SuspensionSettings = {
    RestLength: number,
    SpringStiffness: number,
    DamperCoefficient: number,
    RaycastLength: number,
    WheelRadius: number,
    MaxForce: number,
    AirDamping: number,
}

export type TractionSettings = {
    LateralStiffness: number,
    LongitudinalStiffness: number,
    RollingFriction: number,
    MaxTractionForce: number,
}

export type DriveSettings = {
    MaxForwardSpeed: number,
    MaxReverseSpeed: number,
    TurnRate: number,
    DriveForce: number,
    BrakeForce: number,
}

export type TankSettings = {
    Suspension: SuspensionSettings,
    Traction: TractionSettings,
    Drive: DriveSettings,
}

export type WheelConfig = {
    name: string,
    side: string,
    index: number,
    attachment: Attachment,
    force: VectorForce,
    command: number,
    compression: number,
    inContact: boolean,
}

export type TankSuspension = {
    Model: Model,
    Hull: BasePart,
    Settings: TankSettings,
    Wheels: {WheelConfig},
    throttle: number,
    steer: number,
    handBrake: boolean,
    _raycastParams: RaycastParams,
    _connection: RBXScriptConnection?,
    _destroyed: boolean,
}

local TankSuspension = {}
TankSuspension.__index = TankSuspension

local DEFAULT_SETTINGS: TankSettings = {
    Suspension = {
        RestLength = 2,
        SpringStiffness = 12000,
        DamperCoefficient = 2500,
        RaycastLength = 4,
        WheelRadius = 1.5,
        MaxForce = 60000,
        AirDamping = 0,
    },
    Traction = {
        LateralStiffness = 6500,
        LongitudinalStiffness = 5500,
        RollingFriction = 350,
        MaxTractionForce = 20000,
    },
    Drive = {
        MaxForwardSpeed = 24,
        MaxReverseSpeed = 12,
        TurnRate = 0.5,
        DriveForce = 12000,
        BrakeForce = 16000,
    },
}

local function cloneTable<T>(source: { [any]: T }): { [any]: T }
    local target: { [any]: T } = {}
    for key, value in pairs(source) do
        if type(value) == "table" then
            target[key] = cloneTable(value :: any)
        else
            target[key] = value
        end
    end
    return target
end

local function mergeTables(into: any, overrides: any)
    if type(overrides) ~= "table" then
        return into
    end

    for key, value in pairs(overrides) do
        if type(value) == "table" and type(into[key]) == "table" then
            mergeTables(into[key], value)
        else
            into[key] = value
        end
    end

    return into
end

local function parseWheelName(name: string): (string, number)
    local side, index = string.match(name, "^Wheel_([LR])(%d+)$")
    if not side or not index then
        error(string.format("Wheel attachment '%s' must be named 'Wheel_<Side><Index>' (for example Wheel_L1)", name), 2)
    end
    return side, tonumber(index)
end

local function expectPrimaryPart(model: Model): BasePart
    local primary = model.PrimaryPart
    if not primary then
        error(string.format("Model %s is missing a PrimaryPart. Set the hull as the PrimaryPart before using TankSuspension.", model:GetFullName()), 2)
    end
    return primary
end

local function buildRaycastParams(model: Model): RaycastParams
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { model }
    params.RespectCanCollide = true
    return params
end

local function createForce(attachment: Attachment): VectorForce
    local force = Instance.new("VectorForce")
    force.Name = attachment.Name .. "_Force"
    force.Attachment0 = attachment
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.ApplyAtCenterOfMass = false
    force.Force = Vector3.zero
    force.Parent = attachment.Parent
    return force
end

local function compareWheels(a: WheelConfig, b: WheelConfig): boolean
    if a.side == b.side then
        return a.index < b.index
    end
    return a.side < b.side
end

function TankSuspension.new(model: Model, overrides: TankSettings?): TankSuspension
    local hull = expectPrimaryPart(model)
    local settings = cloneTable(DEFAULT_SETTINGS)
    mergeTables(settings, overrides)

    local attachments: {Attachment} = {}
    for _, child in ipairs(hull:GetChildren()) do
        if child:IsA("Attachment") then
            if string.match(child.Name, "^Wheel_[LR]%d+$") then
                table.insert(attachments, child)
            end
        end
    end

    if #attachments == 0 then
        error(string.format("No wheel attachments found on %s. Add attachments named 'Wheel_L1', 'Wheel_R1', etc.", hull:GetFullName()), 2)
    end

    local wheels: {WheelConfig} = {}
    for _, attachment in ipairs(attachments) do
        local side, index = parseWheelName(attachment.Name)
        local force = createForce(attachment)
        table.insert(wheels, {
            name = attachment.Name,
            side = side,
            index = index,
            attachment = attachment,
            force = force,
            command = 0,
            compression = 0,
            inContact = false,
        })
    end

    table.sort(wheels, compareWheels)

    local self: TankSuspension = setmetatable({
        Model = model,
        Hull = hull,
        Settings = settings,
        Wheels = wheels,
        throttle = 0,
        steer = 0,
        handBrake = false,
        _raycastParams = buildRaycastParams(model),
        _connection = nil,
        _destroyed = false,
    }, TankSuspension)

    return self
end

local function clamp01(value: number): number
    if value < -1 then
        return -1
    elseif value > 1 then
        return 1
    end
    return value
end

function TankSuspension:SetThrottle(value: number)
    self.throttle = clamp01(value)
end

function TankSuspension:SetSteer(value: number)
    self.steer = clamp01(value)
end

function TankSuspension:SetHandBrake(enabled: boolean)
    self.handBrake = enabled
end

function TankSuspension:Bind()
    if self._connection then
        return
    end

    self._connection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

function TankSuspension:Unbind()
    if self._connection then
        self._connection:Disconnect()
        self._connection = nil
    end
end

function TankSuspension:Destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    self:Unbind()

    for _, wheel in ipairs(self.Wheels) do
        wheel.force:Destroy()
    end

    table.clear(self.Wheels)
end

local function computeCommand(throttle: number, steer: number, turnRate: number): (number, number)
    local turn = steer * turnRate
    local left = math.clamp(throttle - turn, -1, 1)
    local right = math.clamp(throttle + turn, -1, 1)
    return left, right
end

local function sign(value: number): number
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

local function springForce(settings: SuspensionSettings, compression: number, speed: number): number
    local force = compression * settings.SpringStiffness - speed * settings.DamperCoefficient
    return math.clamp(force, -settings.MaxForce, settings.MaxForce)
end

local function computeDriveForce(settings: TankSettings, handBrake: boolean, command: number, forwardSpeed: number): number
    local drive = 0
    if not handBrake then
        local maxSpeed = command >= 0 and settings.Drive.MaxForwardSpeed or settings.Drive.MaxReverseSpeed
        local desiredSpeed = command * maxSpeed
        local speedError = desiredSpeed - forwardSpeed
        drive = math.clamp(speedError * settings.Drive.DriveForce, -settings.Drive.DriveForce, settings.Drive.DriveForce)
    end

    local braking = 0
    if handBrake or math.abs(command) < 0.05 then
        braking = math.clamp(-forwardSpeed * settings.Drive.BrakeForce, -settings.Drive.BrakeForce, settings.Drive.BrakeForce)
    end

    return drive + braking
end

local function applyAirDamping(hull: BasePart, wheel: WheelConfig, settings: TankSettings)
    local damping = settings.Suspension.AirDamping
    if damping <= 0 then
        wheel.force.Force = Vector3.zero
        wheel.force.Enabled = false
        wheel.inContact = false
        wheel.compression = 0
        return
    end

    local velocity = hull:GetVelocityAtPosition(wheel.attachment.WorldPosition)
    wheel.force.Force = -velocity * damping
    wheel.force.Enabled = true
    wheel.inContact = false
    wheel.compression = 0
end

function TankSuspension:_step()
    if self._destroyed then
        return
    end

    local settings = self.Settings
    local leftCommand, rightCommand = computeCommand(self.handBrake and 0 or self.throttle, self.steer, settings.Drive.TurnRate)

    local hull = self.Hull
    local hullCFrame = hull.CFrame
    local up = hullCFrame.UpVector
    local down = -up
    local forward = hullCFrame.LookVector
    local right = hullCFrame.RightVector

    for _, wheel in ipairs(self.Wheels) do
        wheel.command = wheel.side == "L" and leftCommand or rightCommand

        local attachment = wheel.attachment
        local origin = attachment.WorldPosition
        local rayDirection = down * settings.Suspension.RaycastLength
        local result = Workspace:Raycast(origin, rayDirection, self._raycastParams)

        if result then
            local distance = result.Distance - settings.Suspension.WheelRadius
            local suspensionLength = math.max(distance, 0)
            local compression = math.clamp(settings.Suspension.RestLength - suspensionLength, 0, settings.Suspension.RestLength)
            local velocity = hull:GetVelocityAtPosition(origin)
            local verticalSpeed = velocity:Dot(up)
            local verticalForceMag = springForce(settings.Suspension, compression, verticalSpeed)
            local verticalForce = up * verticalForceMag

            local forwardSpeed = velocity:Dot(forward)
            local lateralSpeed = velocity:Dot(right)

            local driveForceMag = computeDriveForce(settings, self.handBrake, wheel.command, forwardSpeed)
            local longitudinal = forward * driveForceMag
            local lateral = -right * (lateralSpeed * settings.Traction.LateralStiffness)
            local rolling = Vector3.zero
            if forwardSpeed ~= 0 then
                rolling = -forward * settings.Traction.RollingFriction * sign(forwardSpeed)
            end
            local drag = -forward * (forwardSpeed * settings.Traction.LongitudinalStiffness) + rolling

            local planar = longitudinal + lateral + drag
            if planar.Magnitude > settings.Traction.MaxTractionForce then
                planar = planar.Unit * settings.Traction.MaxTractionForce
            end

            wheel.force.Force = verticalForce + planar
            wheel.force.Enabled = true
            wheel.inContact = true
            if settings.Suspension.RestLength > 0 then
                wheel.compression = compression / settings.Suspension.RestLength
            else
                wheel.compression = 0
            end
        else
            applyAirDamping(hull, wheel, settings)
        end
    end
end

return TankSuspension
