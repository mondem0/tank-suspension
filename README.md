# Tank Suspension Roblox Scripts

This repository contains Roblox Lua scripts and documentation for building a physically driven tank suspension system with per-wheel springs, dampers, and wheel constraints. The included module expects a very specific tank model hierarchy and naming convention; follow the setup instructions carefully before inserting the scripts into Studio.

## Repository layout

| Path | Description |
| --- | --- |
| `src/TankSuspension.lua` | Core module that simulates suspension behavior, per-track drive logic, and wheel damping. |
| `src/Server/TankController.server.lua` | Server script that connects a `VehicleSeat` to the `TankSuspension` module. |

## Building the tank model in Studio

Create a `Model` named `Tank` and ensure its `PrimaryPart` is the hull. All parts should be welded (e.g. with `WeldConstraint`) so the chassis behaves as a single rigid body.

### Required root instances

| Instance | Name | Notes |
| --- | --- | --- |
| `Part` | `Hull` | Primary chassis body. Set as `PrimaryPart` of the model. Add `Attachment`s described below. |
| `VehicleSeat` | `DriverSeat` | Weld to the hull. Seat replication drives the throttle/steer inputs used by the script. |
| `Folder` | `WheelAssemblies` | Holds all wheel models. |

### Hull attachments (one pair per wheel)

Add these attachments to the `Hull` for every wheel. Replace `<Side>` with `L` or `R` and `<Index>` with a sequential number starting at 1 from front to back.

| Attachment name | Purpose |
| --- | --- |
| `SuspensionMount_<Side><Index>` | Connection point for the wheel's `SpringConstraint` (`Attachment0`). The attachment's `Axis` should point downward along the suspension travel direction. |
| `DamperMount_<Side><Index>` | Anchor for the scripted damping `VectorForce`. The attachment's `Axis` should also point downward. |

Optionally, add `Attachment` `TrackForce_<Side>` on the hull if you want a visible reference for where track forces are applied; it is not required by the script.

### Wheel assembly model structure

Each child of `WheelAssemblies` must be a `Model` named `WheelAssembly_<Side><Index>` with the following contents:

| Instance | Name | Notes |
| --- | --- | --- |
| `Part` | `Hub` | Acts as the bogey/swing arm. Add two attachments: `SpringAttachment` (for the spring) and `DamperAttachment` (for damping forces). Align the part so its local X-axis points outward from the hull. |
| `Part` | `Wheel` | Visual/contact wheel geometry. Add attachment `WheelAttachment` centred on the axle. Set `CustomPhysicalProperties` with high `Friction` (≈1.8) and `FrictionWeight` ≥ 2 for good grip. |
| `CylindricalConstraint` | `WheelConstraint` | Parent to the wheel model (e.g. under `Wheel`). Set `Attachment0` = `Hub.AxleAttachment` (see below) and `Attachment1` = `Wheel.WheelAttachment`. Set `AngularActuatorType` = `Motor`, `MotorMaxTorque` to a large value (e.g. 60000), and disable limits. |
| `Attachment` | `AxleAttachment` | Parent to `Hub`. Align its axis (X axis) to match the wheel's rotation axis. Used by the wheel constraint. |
| `SpringConstraint` | `SuspensionSpring` | Parent anywhere inside the wheel model. `Attachment0` = `Hull.SuspensionMount_<Side><Index>`, `Attachment1` = `Hub.SpringAttachment`. Configure `FreeLength`, `MinLength`, `MaxLength`, `Stiffness`, and `Damping` to approximate your desired ride characteristics. |

> **Tip:** If you prefer separate visible damper geometry, add an extra `Part` inside the wheel assembly and weld it to `Hub`; only the attachments listed above are required for scripting.

### Required attributes for each wheel assembly

Add attributes to every `WheelAssembly_<Side><Index>` model:

| Attribute | Type | Description |
| --- | --- | --- |
| `RestLength` | `Number` | The target spring length in studs (matches the `SuspensionSpring.FreeLength`). |
| `SpringStiffness` | `Number` | Hooke stiffness (force per stud) applied to the spring. The script copies this into the constraint on startup. |
| `DamperCoefficient` | `Number` | Damping coefficient applied by the scripted `VectorForce` pair (in force·seconds/stud). |
| `RaycastLength` | `Number` | How far below the hull to raycast for ground contact. Typically `RestLength + 1`. |
| `WheelRadius` | `Number` | Radius of the wheel in studs (used for converting linear speed to motor angular speed). |
| `DesignLoad` | `Number` | Expected static load on the wheel in newtons. Used to scale drive torque and traction. |

The script will error during initialization if any attribute is missing.

### Model-level attributes

Set these attributes on the `Tank` model to tune overall behaviour (defaults shown):

| Attribute | Default | Meaning |
| --- | --- | --- |
| `MaxForwardSpeed` | `24` | Maximum forward track speed in studs/second. |
| `MaxReverseSpeed` | `12` | Maximum reverse speed magnitude. |
| `TurnRate` | `0.5` | Weighting factor for steering differential (1 = pivot turn, 0 = tank cannot steer). |
| `DriveTorque` | `65000` | Baseline motor torque (N·stud) given to each wheel. |
| `BrakeTorque` | `90000` | Torque applied when the handbrake engages or no driver occupies the seat. |
| `MaxDampingForce` | `80000` | Clamp applied to each damper force to keep the solver stable. |
| `AirDampingScale` | `0.2` | Scale applied to damper force when a wheel is airborne. |

### Ground detection and traction

The module uses per-wheel raycasts originating from each `SuspensionSpring.Attachment0` along the attachment's negative axis. Ensure no other parts of the tank extend into this ray path or the vehicle may think it is grounded while airborne. You can customise the collision filtering by editing the script's `RaycastParams` if necessary.

## Script installation

1. Copy `src/TankSuspension.lua` into a ModuleScript (for example `ServerScriptService/TankSuspension`).
2. Copy `src/Server/TankController.server.lua` into a Script parented to your `Tank` model.
3. Set the script's `TankSuspensionModule` reference if you move the module (see the comment at the top of the server script).
4. Enter Play mode to let the script wire up the suspension. Errors about missing attachments, attributes, or constraints point to mismatches with the naming scheme above.

## Extending the system

* Add your own input mapping by calling `SetThrottle`, `SetSteer`, and `SetHandBrake` on the returned controller.
* You can author different wheel groups (e.g. return rollers) by tagging the assemblies and filtering them before handing to the module.
* Consider adding track visual meshes driven by the wheel angular speed for extra polish.

Refer to the inline documentation in the scripts for additional guidance on tuning values.
