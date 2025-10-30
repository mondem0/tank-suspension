--!strict
--[[
    TankSuspension.lua
    -------------------
    Raycast-based tank suspension and traction controller. Each wheel is defined by a
    single Attachment on the hull. The module casts a ray from the attachment toward the
    ground, applies a spring/damper force that rebalances itself against the tank's mass,
    and adds planar forces for traction and steering. All tuning happens through the
    settings table passed into `new` or by editing the defaults below.

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
    DampingRatio: number,
    Preload: number,
    RaycastLength: number,
    WheelRadius: number,
    MaxForceMultiplier: number,
    AntiRollStiffness: number,
    AirDamping: number,
}

export type TractionSettings = {
    LateralStiffness: number,
    LongitudinalStiffness: number,
    RollingDrag: number,
    MaxPlanarForceMultiplier: number,
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
    _pairs: {[number]: {L: WheelConfig?, R: WheelConfig?}},
}

local TankSuspension = {}
TankSuspension.__index = TankSuspension

local DEFAULT_SETTINGS: TankSettings = {
    Suspension = {
        RestLength = 2,
        SpringStiffness = 30000,
        DampingRatio = 1.15,
        Preload = 0.2,
        RaycastLength = 5,
        WheelRadius = 1.5,
        MaxForceMultiplier = 2.6,
        AntiRollStiffness = 3500,
        AirDamping = 1200,
    },
    Traction = {
        LateralStiffness = 2200,
        LongitudinalStiffness = 1800,
        RollingDrag = 140,
        MaxPlanarForceMultiplier = 1.15,
    },
    Drive = {
        MaxForwardSpeed = 24,
        MaxReverseSpeed = 12,
        TurnRate = 0.45,
        DriveForce = 11000,
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

local function normalizeSide(value: string?): string?
    if not value then
        return nil
    end

    local lower = string.lower(value)
    if lower == "l" or lower == "left" then
        return "L"
    elseif lower == "r" or lower == "right" then
        return "R"
    end

    return nil
end

local function extractWheelPlacement(attachment: Attachment): (string?, number?)
    local attrSide = attachment:GetAttribute("WheelSide")
    local attrIndex = attachment:GetAttribute("WheelIndex")

    local side = nil
    local index = nil

    if typeof(attrSide) == "string" and (typeof(attrIndex) == "number" or typeof(attrIndex) == "string") then
        side = normalizeSide(attrSide)
        local parsedIndex = tonumber(attrIndex)
        if parsedIndex then
            index = math.floor(parsedIndex + 0.5)
        end
    end

    if not side or not index then
        local name = attachment.Name
        local sideToken, numberToken = string.match(name, "([LRlr])%D*(%d+)")
        if sideToken and numberToken then
            side = normalizeSide(sideToken)
            index = tonumber(numberToken)
        end
    end

    if side and index and index > 0 then
        return side, index
    end

    return nil, nil
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
            table.insert(attachments, child)
        end
    end

    if #attachments == 0 then
        error(string.format("No attachments found on %s. Add attachments where the wheels should connect to the hull.", hull:GetFullName()), 2)
    end

    local wheels: {WheelConfig} = {}
    local seen: {[string]: boolean} = {}
    for _, attachment in ipairs(attachments) do
        local side, index = extractWheelPlacement(attachment)
        if side and index then
            local key = side .. tostring(index)
            if seen[key] then
                warn(string.format("Duplicate wheel placement detected for side %s index %d at attachment %s.%s. Only the first attachment with that combination will be used.", side, index, attachment.Parent:GetFullName(), attachment.Name))
            else
                seen[key] = true
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
        else
            warn(string.format("Ignoring attachment %s.%s – unable to determine wheel side/index. Set WheelSide/WheelIndex attributes or include L/R and a number in the name.", attachment.Parent:GetFullName(), attachment.Name))
        end
    end

    table.sort(wheels, compareWheels)

    if #wheels == 0 then
        error(string.format("No wheel attachments detected on %s. Add attachments with WheelSide/WheelIndex attributes or include 'L'/'R' and an index in their names.", hull:GetFullName()), 2)
    end

    local pairsByIndex: {[number]: {L: WheelConfig?, R: WheelConfig?}} = {}
    for _, wheel in ipairs(wheels) do
        local entry = pairsByIndex[wheel.index]
        if not entry then
            entry = {}
            pairsByIndex[wheel.index] = entry
        end
        entry[wheel.side] = wheel
    end

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
        _pairs = pairsByIndex,
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

    self._connection = RunService.Heartbeat:Connect(function(dt)
        self:_step(dt)
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

function TankSuspension:_step(dt: number)
    if self._destroyed then
        return
    end

    if not dt or dt <= 0 then
        dt = 1 / 60
    end

    local settings = self.Settings
    local suspension = settings.Suspension
    local traction = settings.Traction
    local driveSettings = settings.Drive

    local wheelCount = #self.Wheels
    if wheelCount == 0 then
        return
    end

    local leftCommand, rightCommand = computeCommand(self.handBrake and 0 or self.throttle, self.steer, driveSettings.TurnRate)

    local hull = self.Hull
    local hullCFrame = hull.CFrame
    local up = hullCFrame.UpVector
    local down = -up
    local forward = hullCFrame.LookVector
    local right = hullCFrame.RightVector

    local gravity = Workspace.Gravity
    local totalMass = hull.AssemblyMass
    local massPerWheel = totalMass / wheelCount
    local weightPerWheel = massPerWheel * gravity
    local preloadCompression = math.clamp(suspension.Preload, 0, suspension.RestLength)
    local stiffness = math.max(suspension.SpringStiffness, 0)
    local criticalDamping = 0
    if stiffness > 0 then
        criticalDamping = 2 * math.sqrt(stiffness * massPerWheel)
    end
    local damperCoefficient = criticalDamping * suspension.DampingRatio
    local maxVerticalForce = weightPerWheel * suspension.MaxForceMultiplier
    local maxPlanarForce = weightPerWheel * traction.MaxPlanarForceMultiplier

    local wheelResults: {[WheelConfig]: {vertical: number, planar: Vector3, compression: number, contact: boolean, normal: Vector3?}} = {}

    for _, wheel in ipairs(self.Wheels) do
        wheel.command = wheel.side == "L" and leftCommand or rightCommand

        local attachment = wheel.attachment
        local origin = attachment.WorldPosition
        local rayDirection = down * suspension.RaycastLength
        local result = Workspace:Raycast(origin, rayDirection, self._raycastParams)

        if result then
            local normal = result.Normal.Unit
            local distance = result.Distance - suspension.WheelRadius
            local suspensionLength = math.max(distance, 0)
            local compression = math.max(suspension.RestLength - suspensionLength, 0)

            local relativeVelocity = hull:GetVelocityAtPosition(result.Position)
            if result.Instance and result.Instance:IsA("BasePart") then
                relativeVelocity -= result.Instance:GetVelocityAtPosition(result.Position)
            end

            local normalSpeed = relativeVelocity:Dot(normal)
            local springForce = (compression + preloadCompression) * stiffness
            if springForce < 0 then
                springForce = 0
            end
            local dampingForce = -normalSpeed * damperCoefficient
            local verticalForceMag = math.clamp(springForce + dampingForce, 0, maxVerticalForce)

            local forwardAxis = forward - normal * forward:Dot(normal)
            if forwardAxis.Magnitude < 1e-4 then
                forwardAxis = right - normal * right:Dot(normal)
            end
            if forwardAxis.Magnitude < 1e-4 then
                forwardAxis = normal:Cross(right)
            end
            if forwardAxis.Magnitude < 1e-4 then
                forwardAxis = Vector3.new(0, 0, 1)
                if math.abs(forwardAxis:Dot(normal)) > 0.99 then
                    forwardAxis = Vector3.new(1, 0, 0)
                end
            end
            forwardAxis = forwardAxis.Unit

            local lateralAxis = normal:Cross(forwardAxis)
            if lateralAxis.Magnitude < 1e-4 then
                lateralAxis = right - normal * right:Dot(normal)
            end
            if lateralAxis.Magnitude < 1e-4 then
                lateralAxis = Vector3.new(1, 0, 0)
                if math.abs(lateralAxis:Dot(normal)) > 0.99 then
                    lateralAxis = Vector3.new(0, 0, 1)
                end
            end
            lateralAxis = lateralAxis.Unit

            local forwardSpeed = relativeVelocity:Dot(forwardAxis)
            local lateralSpeed = relativeVelocity:Dot(lateralAxis)

            local driveForce = 0
            if self.handBrake then
                driveForce = math.clamp(-forwardSpeed * driveSettings.BrakeForce, -driveSettings.BrakeForce, driveSettings.BrakeForce)
            else
                local command = wheel.command
                local maxSpeed = command >= 0 and driveSettings.MaxForwardSpeed or driveSettings.MaxReverseSpeed
                local desiredSpeed = command * maxSpeed
                local speedError = desiredSpeed - forwardSpeed
                driveForce = math.clamp(speedError * driveSettings.DriveForce, -driveSettings.DriveForce, driveSettings.DriveForce)
                if math.abs(command) < 0.05 then
                    local braking = math.clamp(-forwardSpeed * driveSettings.BrakeForce, -driveSettings.BrakeForce, driveSettings.BrakeForce)
                    driveForce += braking
                end
            end

            local planar = forwardAxis * driveForce
            planar -= forwardAxis * (forwardSpeed * traction.LongitudinalStiffness)
            planar -= lateralAxis * (lateralSpeed * traction.LateralStiffness)
            if math.abs(forwardSpeed) > 0.25 then
                planar -= forwardAxis * (sign(forwardSpeed) * traction.RollingDrag)
            end

            local compressionRatio = suspension.RestLength > 0 and compression / suspension.RestLength or 0
            compressionRatio = math.clamp(compressionRatio, 0, 1)
            planar *= compressionRatio

            if planar.Magnitude > maxPlanarForce then
                planar = planar.Unit * maxPlanarForce
            end

            wheelResults[wheel] = {
                vertical = verticalForceMag,
                planar = planar,
                compression = compression,
                contact = true,
                normal = normal,
            }
        else
            applyAirDamping(hull, wheel, settings)
            wheelResults[wheel] = {
                vertical = 0,
                planar = Vector3.zero,
                compression = 0,
                contact = false,
            }
        end
    end

    if suspension.AntiRollStiffness > 0 then
        for _, pair in pairs(self._pairs) do
            local leftWheel = pair.L
            local rightWheel = pair.R
            if leftWheel and rightWheel then
                local leftResult = wheelResults[leftWheel]
                local rightResult = wheelResults[rightWheel]
                if leftResult and rightResult and leftResult.contact and rightResult.contact then
                    local diff = leftResult.compression - rightResult.compression
                    local rollForce = diff * suspension.AntiRollStiffness
                    leftResult.vertical = math.clamp(leftResult.vertical - rollForce, 0, maxVerticalForce)
                    rightResult.vertical = math.clamp(rightResult.vertical + rollForce, 0, maxVerticalForce)
                end
            end
        end
    end

    for _, wheel in ipairs(self.Wheels) do
        local result = wheelResults[wheel]
        if result then
            if result.contact then
                local verticalAxis = result.normal or hull.CFrame.UpVector
                wheel.force.Force = verticalAxis * result.vertical + result.planar
                wheel.force.Enabled = true
                wheel.inContact = true
                if suspension.RestLength > 0 then
                    wheel.compression = result.compression / suspension.RestLength
                else
                    wheel.compression = 0
                end
            else
                applyAirDamping(hull, wheel, settings)
            end
        else
            applyAirDamping(hull, wheel, settings)
        end
    end
end

return TankSuspension
