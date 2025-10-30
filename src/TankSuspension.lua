--!strict
--[[
    TankSuspension.lua
    -------------------
    Completely raycast-driven tank suspension that only requires wheel
    attachments on the hull. Each frame the module casts a ray beneath every
    attachment, builds a spring force aligned to the ground normal, and applies
    traction through a second VectorForce that pushes at the centre of mass.

    The implementation focuses on stability when the vehicle mass changes (for
    example when a driver enters the seat) by smoothing the mass estimate and
    separating vertical support from planar drive forces. Attachments can keep
    their existing orientation – the script reads their axes so you can reuse
    rigs built with other suspension setups.

    Usage:
        local TankSuspension = require(path.to.TankSuspension)
        local controller = TankSuspension.new(tankModel, settings?)
        controller:Bind()
        controller:SetThrottle(0.5)
        controller:SetSteer(-0.25)
        controller:SetHandBrake(false)

    See README.md for the required attachment naming conventions and available
    tuning parameters.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type SuspensionSettings = {
    RestLength: number,
    SpringStiffness: number,
    Damping: number,
    PreloadForce: number,
    RaycastLength: number,
    WheelRadius: number,
    MaxForceMultiplier: number,
    AntiRollStiffness: number,
    MassSmoothing: number,
    AirDamping: number,
    UseAttachmentUp: boolean?,
}

export type TractionSettings = {
    LongitudinalStiffness: number,
    LateralStiffness: number,
    RollingDrag: number,
    GripCoefficient: number,
}

export type DriveSettings = {
    MaxForwardSpeed: number,
    MaxReverseSpeed: number,
    TurnRate: number,
    DriveForce: number,
    IdleBrakeForce: number,
    HandBrakeForce: number,
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
    suspensionForce: VectorForce,
    tractionForce: VectorForce,
    rayDirection: Vector3,
    forwardHint: Vector3,
    lateralHint: Vector3,
    command: number,
    lastLength: number,
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
    _smoothedMass: number,
}

local TankSuspension = {}
TankSuspension.__index = TankSuspension

local DEFAULT_SETTINGS: TankSettings = {
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
            index = math.max(1, math.floor(parsedIndex + 0.5))
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

local function createForce(attachment: Attachment, suffix: string, applyAtCenter: boolean): VectorForce
    local force = Instance.new("VectorForce")
    force.Name = attachment.Name .. suffix
    force.Attachment0 = attachment
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.ApplyAtCenterOfMass = applyAtCenter
    force.Force = Vector3.zero
    force.Enabled = false
    force.Parent = attachment.Parent
    return force
end

local function compareWheels(a: WheelConfig, b: WheelConfig): boolean
    if a.side == b.side then
        return a.index < b.index
    end
    return a.side < b.side
end

local function sign(value: number): number
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

local function resolveDirectionVector(base: Vector3, fallback: Vector3): Vector3
    if base.Magnitude < 1e-4 then
        return fallback.Unit
    end
    return base.Unit
end

function TankSuspension.new(model: Model, overrides: TankSettings?): TankSuspension
    local hull = expectPrimaryPart(model)
    local settings = cloneTable(DEFAULT_SETTINGS)
    mergeTables(settings, overrides)

    local suspensionSettings = settings.Suspension
    local useAttachmentUp = suspensionSettings.UseAttachmentUp ~= false

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

                local attachmentCFrame = attachment.WorldCFrame
                local hullCFrame = hull.CFrame
                local downDirection = useAttachmentUp and -attachmentCFrame.UpVector or -hullCFrame.UpVector
                local forwardHint = attachmentCFrame.LookVector
                local lateralHint = attachmentCFrame.RightVector

                downDirection = resolveDirectionVector(downDirection, -hullCFrame.UpVector)
                forwardHint = resolveDirectionVector(forwardHint, hullCFrame.LookVector)
                lateralHint = resolveDirectionVector(lateralHint, hullCFrame.RightVector)

                local suspensionForce = createForce(attachment, "_SuspensionForce", false)
                local tractionForce = createForce(attachment, "_TractionForce", true)

                table.insert(wheels, {
                    name = attachment.Name,
                    side = side,
                    index = index,
                    attachment = attachment,
                    suspensionForce = suspensionForce,
                    tractionForce = tractionForce,
                    rayDirection = downDirection,
                    forwardHint = forwardHint,
                    lateralHint = lateralHint,
                    command = 0,
                    lastLength = suspensionSettings.RestLength,
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
        _smoothedMass = hull.AssemblyMass,
    }, TankSuspension)

    return self
end

local function clampCommand(value: number): number
    if value > 1 then
        return 1
    elseif value < -1 then
        return -1
    end
    return value
end

function TankSuspension:SetThrottle(value: number)
    self.throttle = clampCommand(value)
end

function TankSuspension:SetSteer(value: number)
    self.steer = clampCommand(value)
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
        wheel.suspensionForce:Destroy()
        wheel.tractionForce:Destroy()
    end

    table.clear(self.Wheels)
end

local function computeCommand(throttle: number, steer: number, turnRate: number): (number, number)
    local turn = steer * turnRate
    local left = math.clamp(throttle - turn, -1, 1)
    local right = math.clamp(throttle + turn, -1, 1)
    return left, right
end

local function blend(previous: number, target: number, rate: number, dt: number): number
    if rate <= 0 then
        return target
    end
    local alpha = math.clamp(dt * rate, 0, 1)
    return previous + (target - previous) * alpha
end

local function computePlanarForces(
    hull: BasePart,
    wheel: WheelConfig,
    normal: Vector3,
    contactPoint: Vector3,
    forwardCommand: number,
    settings: TankSettings,
    verticalForce: number,
    handBrake: boolean
): Vector3
    local traction = settings.Traction
    local drive = settings.Drive

    local forwardAxis = wheel.forwardHint - normal * wheel.forwardHint:Dot(normal)
    if forwardAxis.Magnitude < 1e-4 then
        forwardAxis = hull.CFrame.LookVector - normal * hull.CFrame.LookVector:Dot(normal)
    end
    if forwardAxis.Magnitude < 1e-4 then
        forwardAxis = normal:Cross(hull.CFrame.RightVector)
    end
    forwardAxis = forwardAxis.Unit

    local lateralAxis = wheel.lateralHint - normal * wheel.lateralHint:Dot(normal)
    if lateralAxis.Magnitude < 1e-4 then
        lateralAxis = normal:Cross(forwardAxis)
    end
    if lateralAxis.Magnitude < 1e-4 then
        lateralAxis = hull.CFrame.RightVector - normal * hull.CFrame.RightVector:Dot(normal)
    end
    lateralAxis = lateralAxis.Unit

    local velocity = hull:GetVelocityAtPosition(contactPoint)
    local forwardSpeed = velocity:Dot(forwardAxis)
    local lateralSpeed = velocity:Dot(lateralAxis)

    local maxSpeed = forwardCommand >= 0 and drive.MaxForwardSpeed or drive.MaxReverseSpeed
    local desiredSpeed = handBrake and 0 or forwardCommand * maxSpeed
    local speedError = desiredSpeed - forwardSpeed
    local driveForce = math.clamp(speedError * drive.DriveForce, -drive.DriveForce, drive.DriveForce)

    local planar = forwardAxis * driveForce
    planar -= forwardAxis * (forwardSpeed * traction.LongitudinalStiffness)
    planar -= lateralAxis * (lateralSpeed * traction.LateralStiffness)

    if traction.RollingDrag > 0 and math.abs(forwardSpeed) > 0.1 then
        planar -= forwardAxis * (sign(forwardSpeed) * traction.RollingDrag)
    end

    if handBrake then
        planar -= forwardAxis * (forwardSpeed * drive.HandBrakeForce)
    elseif math.abs(forwardCommand) < 0.05 then
        planar -= forwardAxis * (forwardSpeed * drive.IdleBrakeForce)
    end

    local gripLimit = math.max(verticalForce * traction.GripCoefficient, 0)
    if planar.Magnitude > gripLimit and gripLimit > 0 then
        planar = planar.Unit * gripLimit
    end

    return planar
end

local function applyAirResponse(hull: BasePart, wheel: WheelConfig, suspension: SuspensionSettings)
    wheel.command = 0
    wheel.lastLength = suspension.RaycastLength
    wheel.suspensionForce.Force = Vector3.zero
    wheel.suspensionForce.Enabled = false

    if suspension.AirDamping > 0 then
        local velocity = hull:GetVelocityAtPosition(wheel.attachment.WorldPosition)
        wheel.tractionForce.Force = -velocity * suspension.AirDamping
        wheel.tractionForce.Enabled = true
    else
        wheel.tractionForce.Force = Vector3.zero
        wheel.tractionForce.Enabled = false
    end
end

function TankSuspension:_step(dt: number)
    if self._destroyed then
        return
    end

    if not dt or dt <= 0 then
        dt = 1 / 60
    end

    local wheelCount = #self.Wheels
    if wheelCount == 0 then
        return
    end

    local settings = self.Settings
    local suspension = settings.Suspension
    local hull = self.Hull

    local mass = hull.AssemblyMass
    self._smoothedMass = blend(self._smoothedMass, mass, suspension.MassSmoothing, dt)

    local gravity = Workspace.Gravity
    local massPerWheel = self._smoothedMass / wheelCount
    local weightPerWheel = massPerWheel * gravity
    local maxVerticalForce = math.max(weightPerWheel * suspension.MaxForceMultiplier, 0)

    local leftCommand, rightCommand = computeCommand(self.handBrake and 0 or self.throttle, self.steer, settings.Drive.TurnRate)

    local wheelResults: {[WheelConfig]: {vertical: number, planar: Vector3, compression: number, normal: Vector3}} = {}

    for _, wheel in ipairs(self.Wheels) do
        wheel.command = wheel.side == "L" and leftCommand or rightCommand

        local attachment = wheel.attachment
        local origin = attachment.WorldPosition
        local rayDirection = wheel.rayDirection * suspension.RaycastLength
        local result = Workspace:Raycast(origin, rayDirection, self._raycastParams)

        if result then
            local normal = result.Normal.Unit
            local rawLength = math.max(result.Distance - suspension.WheelRadius, 0)
            local restLength = suspension.RestLength
            local compression = math.clamp(restLength - rawLength, 0, restLength)
            local suspensionVelocity = (wheel.lastLength - rawLength) / dt
            wheel.lastLength = rawLength

            local springForce = compression * suspension.SpringStiffness + suspension.PreloadForce
            local dampingForce = suspensionVelocity * suspension.Damping
            local verticalForce = math.clamp(springForce + dampingForce, 0, maxVerticalForce)

            local planarForce = computePlanarForces(
                hull,
                wheel,
                normal,
                result.Position,
                wheel.command,
                settings,
                verticalForce,
                self.handBrake
            )

            wheelResults[wheel] = {
                vertical = verticalForce,
                planar = planarForce,
                compression = compression,
                normal = normal,
            }
        else
            applyAirResponse(hull, wheel, suspension)
        end
    end

    if suspension.AntiRollStiffness > 0 then
        for _, pair in pairs(self._pairs) do
            local leftWheel = pair.L
            local rightWheel = pair.R
            if leftWheel and rightWheel then
                local leftResult = wheelResults[leftWheel]
                local rightResult = wheelResults[rightWheel]
                if leftResult and rightResult then
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
            wheel.suspensionForce.Force = result.normal * result.vertical
            wheel.suspensionForce.Enabled = result.vertical > 0

            if result.planar.Magnitude > 1e-3 then
                wheel.tractionForce.Force = result.planar
                wheel.tractionForce.Enabled = true
            else
                wheel.tractionForce.Force = Vector3.zero
                wheel.tractionForce.Enabled = false
            end
        else
            applyAirResponse(hull, wheel, suspension)
        end
    end
end

return TankSuspension
