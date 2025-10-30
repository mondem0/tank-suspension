--!strict
--[[
    TankSuspension.lua
    -------------------
    ModuleScript that drives a per-wheel suspension and track system for a Roblox tank.

    The module assumes the tank model follows the structure described in README.md. Each
    wheel assembly must provide the attachments, constraints, and attributes documented
    there. When constructed, the module validates every wheel and wires up helper forces
    for damping and traction.

    Usage:
        local TankSuspension = require(path.to.TankSuspension)
        local controller = TankSuspension.new(tankModel)
        controller:Bind() -- begins the Heartbeat update loop
        controller:SetThrottle(0.6)
        controller:SetSteer(-0.2)
        controller:SetHandBrake(false)

    The accompanying `TankController.server.lua` script shows how to drive the module from
    a VehicleSeat. You can also bind your own inputs by calling the setter methods.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

export type WheelConfig = {
    name: string,
    side: string,
    index: number,
    assembly: Model,
    hubPart: BasePart,
    wheelPart: BasePart,
    spring: SpringConstraint,
    motor: CylindricalConstraint,
    hullSpringAttachment: Attachment,
    hubSpringAttachment: Attachment,
    hullDamperAttachment: Attachment,
    hubDamperAttachment: Attachment,
    axleAttachment: Attachment,
    damperHullForce: VectorForce,
    damperHubForce: VectorForce,
    restLength: number,
    raycastLength: number,
    wheelRadius: number,
    stiffness: number,
    damperCoefficient: number,
    maxDampingForce: number,
    designLoad: number,
    sideCommand: number,
    inContact: boolean,
    compression: number,
    contactNormal: Vector3,
    lastHit: RaycastResult?,
}

local TankSuspension = {}
TankSuspension.__index = TankSuspension

export type TankSuspension = {
    Model: Model,
    Hull: BasePart,
    Options: {
        MaxForwardSpeed: number,
        MaxReverseSpeed: number,
        TurnRate: number,
        DriveTorque: number,
        BrakeTorque: number,
        MaxDampingForce: number,
        AirDampingScale: number,
    },
    Wheels: {WheelConfig},
    _raycastParams: RaycastParams,
    _connection: RBXScriptConnection?,
    _forceFolder: Folder?,
    throttle: number,
    steer: number,
    handBrake: boolean,
    _destroyed: boolean,
}

local DEFAULT_OPTIONS = {
    MaxForwardSpeed = 24,
    MaxReverseSpeed = 12,
    TurnRate = 0.5,
    DriveTorque = 65000,
    BrakeTorque = 90000,
    MaxDampingForce = 80000,
    AirDampingScale = 0.2,
}

local REQUIRED_WHEEL_ATTRIBUTES = {
    "RestLength",
    "SpringStiffness",
    "DamperCoefficient",
    "RaycastLength",
    "WheelRadius",
    "DesignLoad",
}

local function cloneTable<T>(source: { [any]: T }): { [any]: T }
    local target: { [any]: T } = {}
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function expectAttachment(parent: Instance, name: string): Attachment
    local attachment = parent:FindFirstChild(name)
    if not attachment or not attachment:IsA("Attachment") then
        error(string.format("Expected Attachment '%s' under %s", name, parent:GetFullName()), 2)
    end
    return attachment
end

local function expectConstraint<T>(parent: Instance, name: string, className: string): T
    local constraint = parent:FindFirstChild(name)
    if not constraint or constraint.ClassName ~= className then
        error(string.format("Expected %s '%s' under %s", className, name, parent:GetFullName()), 2)
    end
    return constraint :: any
end

local function expectPart(parent: Instance, name: string): BasePart
    local part = parent:FindFirstChild(name)
    if not part or not part:IsA("BasePart") then
        error(string.format("Expected BasePart '%s' under %s", name, parent:GetFullName()), 2)
    end
    return part
end

local function getNumberAttribute(instance: Instance, attributeName: string): number
    local value = instance:GetAttribute(attributeName)
    if typeof(value) ~= "number" then
        error(string.format("Instance %s is missing numeric attribute '%s'", instance:GetFullName(), attributeName), 2)
    end
    return value
end

local function mergeOptions(model: Model, overrides: { [string]: number }?): { [string]: number }
    local options = cloneTable(DEFAULT_OPTIONS)
    if overrides then
        for key, value in pairs(overrides) do
            options[key] = value
        end
    end
    for key in pairs(DEFAULT_OPTIONS) do
        local attribute = model:GetAttribute(key)
        if typeof(attribute) == "number" then
            options[key] = attribute :: number
        end
    end
    return options
end

local function parseWheelName(name: string): (string, number)
    local side, index = string.match(name, "WheelAssembly_([LR])(%d+)$")
    if not side or not index then
        error(string.format("Wheel assembly '%s' must be named 'WheelAssembly_<Side><Index>'", name), 2)
    end
    return side, tonumber(index)
end

local function vectorOrDefault(vec: Vector3?): Vector3
    if vec and vec.Magnitude > 0 then
        return vec.Unit
    end
    return Vector3.new(0, -1, 0)
end

local function sign(value: number): number
    if value > 0 then
        return 1
    elseif value < 0 then
        return -1
    end
    return 0
end

-- Private helper that builds the table for a single wheel assembly.
function TankSuspension:_buildWheel(assembly: Model): WheelConfig
    local side, index = parseWheelName(assembly.Name)

    local hub = expectPart(assembly, "Hub")
    local wheel = expectPart(assembly, "Wheel")
    local spring = expectConstraint(assembly, "SuspensionSpring", "SpringConstraint")
    local motor = expectConstraint(assembly, "WheelConstraint", "CylindricalConstraint")

    local hullSpringAttachment = expectAttachment(self.Hull, string.format("SuspensionMount_%s%d", side, index))
    local hullDamperAttachment = expectAttachment(self.Hull, string.format("DamperMount_%s%d", side, index))
    local hubSpringAttachment = expectAttachment(hub, "SpringAttachment")
    local hubDamperAttachment = expectAttachment(hub, "DamperAttachment")
    local axleAttachment = expectAttachment(hub, "AxleAttachment")
    local wheelAttachment = expectAttachment(wheel, "WheelAttachment")

    if motor.Attachment0 ~= axleAttachment or motor.Attachment1 ~= wheelAttachment then
        -- Ensure the constraint is wired correctly before we start changing properties.
        motor.Attachment0 = axleAttachment
        motor.Attachment1 = wheelAttachment
    end
    motor.AngularActuatorType = Enum.ActuatorType.Motor
    motor.MotorMaxTorque = math.max(motor.MotorMaxTorque, self.Options.DriveTorque)
    motor.Enabled = true

    spring.Attachment0 = hullSpringAttachment
    spring.Attachment1 = hubSpringAttachment

    for _, attributeName in ipairs(REQUIRED_WHEEL_ATTRIBUTES) do
        getNumberAttribute(assembly, attributeName)
    end

    local wheelConfig: WheelConfig = {
        name = string.format("%s%d", side, index),
        side = side,
        index = index,
        assembly = assembly,
        hubPart = hub,
        wheelPart = wheel,
        spring = spring,
        motor = motor,
        hullSpringAttachment = hullSpringAttachment,
        hubSpringAttachment = hubSpringAttachment,
        hullDamperAttachment = hullDamperAttachment,
        hubDamperAttachment = hubDamperAttachment,
        axleAttachment = axleAttachment,
        damperHullForce = nil :: any,
        damperHubForce = nil :: any,
        restLength = getNumberAttribute(assembly, "RestLength"),
        raycastLength = getNumberAttribute(assembly, "RaycastLength"),
        wheelRadius = getNumberAttribute(assembly, "WheelRadius"),
        stiffness = getNumberAttribute(assembly, "SpringStiffness"),
        damperCoefficient = getNumberAttribute(assembly, "DamperCoefficient"),
        maxDampingForce = self.Options.MaxDampingForce,
        designLoad = math.max(getNumberAttribute(assembly, "DesignLoad"), 1),
        sideCommand = 0,
        inContact = false,
        compression = 0,
        contactNormal = Vector3.new(0, 1, 0),
        lastHit = nil,
    }

    local maxDampingAttribute = assembly:GetAttribute("MaxDampingForce")
    if typeof(maxDampingAttribute) == "number" then
        wheelConfig.maxDampingForce = math.max(maxDampingAttribute :: number, 0)
    end

    spring.FreeLength = wheelConfig.restLength
    spring.Stiffness = wheelConfig.stiffness
    spring.Damping = 0 -- handled via explicit VectorForce pair for better control
    spring.MinLength = math.min(spring.MinLength, math.max(0.1, wheelConfig.restLength * 0.4))
    spring.MaxLength = math.max(spring.MaxLength, wheelConfig.restLength * 1.6)

    local damperHullForce = Instance.new("VectorForce")
    damperHullForce.Name = "DamperForce_Hull_" .. wheelConfig.name
    damperHullForce.Attachment0 = hullDamperAttachment
    damperHullForce.RelativeTo = Enum.ActuatorRelativeTo.World
    damperHullForce.ApplyAtCenterOfMass = false
    damperHullForce.Force = Vector3.zero
    damperHullForce.Parent = self._forceFolder

    local damperHubForce = Instance.new("VectorForce")
    damperHubForce.Name = "DamperForce_Wheel_" .. wheelConfig.name
    damperHubForce.Attachment0 = hubDamperAttachment
    damperHubForce.RelativeTo = Enum.ActuatorRelativeTo.World
    damperHubForce.ApplyAtCenterOfMass = false
    damperHubForce.Force = Vector3.zero
    damperHubForce.Parent = hub

    wheelConfig.damperHullForce = damperHullForce
    wheelConfig.damperHubForce = damperHubForce

    return wheelConfig
end

local function wheelSort(a: WheelConfig, b: WheelConfig): boolean
    if a.side == b.side then
        return a.index < b.index
    end
    return a.side < b.side
end

function TankSuspension.new(model: Model, overrides: { [string]: number }?): TankSuspension
    assert(model and model:IsA("Model"), "TankSuspension.new expects a Model")
    local hull = expectPart(model, "Hull")

    local self: TankSuspension = setmetatable({}, TankSuspension)
    self.Model = model
    self.Hull = hull
    self.Options = mergeOptions(model, overrides)
    self.Options.MaxForwardSpeed = math.max(self.Options.MaxForwardSpeed, 0)
    self.Options.MaxReverseSpeed = math.max(self.Options.MaxReverseSpeed, 0)
    self.Options.TurnRate = math.clamp(self.Options.TurnRate, 0, 1)
    self.Options.DriveTorque = math.max(self.Options.DriveTorque, 0)
    self.Options.BrakeTorque = math.max(self.Options.BrakeTorque, 0)
    self.Options.MaxDampingForce = math.max(self.Options.MaxDampingForce, 0)
    self.Options.AirDampingScale = math.clamp(self.Options.AirDampingScale, 0, 1)
    self.Wheels = {}
    self._raycastParams = RaycastParams.new()
    self._raycastParams.FilterDescendantsInstances = { model }
    self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    self._forceFolder = Instance.new("Folder")
    self._forceFolder.Name = "SuspensionForces"
    self._forceFolder.Parent = model
    self.throttle = 0
    self.steer = 0
    self.handBrake = true
    self._destroyed = false

    local wheelFolder = model:FindFirstChild("WheelAssemblies")
    if not wheelFolder or not wheelFolder:IsA("Folder") then
        error("Tank model must contain a Folder named 'WheelAssemblies'", 2)
    end

    for _, assembly in ipairs(wheelFolder:GetChildren()) do
        if assembly:IsA("Model") then
            table.insert(self.Wheels, self:_buildWheel(assembly))
        end
    end

    if #self.Wheels == 0 then
        error("WheelAssemblies folder does not contain any wheel models", 2)
    end

    table.sort(self.Wheels, wheelSort)
    return self
end

function TankSuspension:IsDestroyed(): boolean
    return self._destroyed
end

function TankSuspension:SetThrottle(value: number)
    self.throttle = math.clamp(value, -1, 1)
end

function TankSuspension:SetSteer(value: number)
    self.steer = math.clamp(value, -1, 1)
end

function TankSuspension:SetHandBrake(isEngaged: boolean)
    self.handBrake = isEngaged and true or false
end

function TankSuspension:_updateWheelContact(wheel: WheelConfig)
    local origin = wheel.spring.Attachment0.WorldPosition
    local axis = -wheel.spring.Attachment0.WorldAxis
    if axis.Magnitude < 0.001 then
        axis = -wheel.hullSpringAttachment.WorldAxis
    end
    axis = vectorOrDefault(axis)

    local result = Workspace:Raycast(origin, axis * wheel.raycastLength, self._raycastParams)
    wheel.lastHit = result
    if result then
        wheel.inContact = true
        wheel.contactNormal = result.Normal
    else
        wheel.inContact = false
        wheel.contactNormal = Vector3.new(0, 1, 0)
    end

    wheel.compression = wheel.restLength - wheel.spring.CurrentLength
end

function TankSuspension:_applyDamper(wheel: WheelConfig, dt: number)
    local hullAttachment = wheel.hullDamperAttachment
    local hubAttachment = wheel.hubDamperAttachment

    local offset = hubAttachment.WorldPosition - hullAttachment.WorldPosition
    local axis = vectorOrDefault(offset)

    local hullVelocity = self.Hull:GetVelocityAtPosition(hullAttachment.WorldPosition)
    local hubVelocity = wheel.hubPart:GetVelocityAtPosition(hubAttachment.WorldPosition)
    local relativeSpeed = (hubVelocity - hullVelocity):Dot(axis)

    local coefficient = wheel.damperCoefficient
    if not wheel.inContact then
        coefficient *= self.Options.AirDampingScale
    end

    local dampingForceMagnitude = -relativeSpeed * coefficient
    local maxForce = wheel.maxDampingForce
    if math.abs(dampingForceMagnitude) > maxForce then
        dampingForceMagnitude = maxForce * sign(dampingForceMagnitude)
    end

    local forceVector = axis * dampingForceMagnitude
    wheel.damperHullForce.Force = forceVector
    wheel.damperHubForce.Force = -forceVector
end

function TankSuspension:_updateMotorTargets()
    local throttle = self.throttle
    local steer = self.steer
    local turnFactor = self.Options.TurnRate

    -- Differential steering: mix throttle and steer into left/right track commands.
    local leftCommand = math.clamp(throttle - steer * turnFactor, -1, 1)
    local rightCommand = math.clamp(throttle + steer * turnFactor, -1, 1)

    for _, wheel in ipairs(self.Wheels) do
        local command = wheel.side == "L" and leftCommand or rightCommand
        wheel.sideCommand = command

        local motor = wheel.motor
        if self.handBrake then
            motor.AngularVelocity = 0
            motor.MotorMaxTorque = self.Options.BrakeTorque
        else
            local targetSpeed = command >= 0 and self.Options.MaxForwardSpeed or self.Options.MaxReverseSpeed
            local linearSpeed = command * targetSpeed
            local angularSpeed = linearSpeed / math.max(wheel.wheelRadius, 0.1)
            motor.AngularVelocity = angularSpeed

            -- Scale torque based on wheel load to reduce wheel spin when unweighted.
            local loadScale = math.clamp((wheel.compression * wheel.stiffness) / wheel.designLoad, 0, 1)
            motor.MotorMaxTorque = math.max(self.Options.DriveTorque * math.max(loadScale, 0.2), self.Options.BrakeTorque * 0.25)
        end
    end
end

function TankSuspension:_step(dt: number)
    if self._destroyed then
        return
    end

    for _, wheel in ipairs(self.Wheels) do
        self:_updateWheelContact(wheel)
        self:_applyDamper(wheel, dt)
    end

    self:_updateMotorTargets()
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
    for _, wheel in ipairs(self.Wheels) do
        wheel.damperHullForce.Force = Vector3.zero
        wheel.damperHubForce.Force = Vector3.zero
    end
end

function TankSuspension:Destroy()
    if self._destroyed then
        return
    end
    self:Unbind()
    for _, wheel in ipairs(self.Wheels) do
        if wheel.damperHullForce then
            wheel.damperHullForce:Destroy()
        end
        if wheel.damperHubForce then
            wheel.damperHubForce:Destroy()
        end
    end
    if self._forceFolder then
        self._forceFolder:Destroy()
    end
    self._destroyed = true
end

return TankSuspension
