# Tank Suspension Roblox Scripts

This project gives you two Roblox scripts:

* `TankSuspension.lua` – the module that handles springs, dampers, and wheel motors.
* `TankController.server.lua` – the script that reads the driver seat and talks to the module.

Follow the steps below in Roblox Studio to make the scripts work. Keep the names exactly the same so the code can find everything.

## 1. Build the tank model
1. Create a **Model** named **Tank**. Set its `PrimaryPart` to the main body part (call it **Hull**).
2. Add a **VehicleSeat** named **DriverSeat** and weld it to the Hull.
3. Inside the Tank model create a **Folder** named **WheelAssemblies**. Each wheel assembly will go inside this folder.

## 2. Add hull attachments (repeat for every wheel)
For each wheel you plan to add, make two attachments on the Hull:

* `SuspensionMount_L1`, `SuspensionMount_R1`, `SuspensionMount_L2`, … (L = left, R = right, numbers go from front to back).
* `DamperMount_L1`, `DamperMount_R1`, `DamperMount_L2`, … (match the same numbers as the suspension mounts).

Place the attachments roughly above where the wheel should sit. Point their green arrow (the attachment axis) straight down.

## 3. Create one wheel assembly
Make a **Model** under `WheelAssemblies` called `WheelAssembly_L1` (copy it later for the other wheels). Inside that model add:

1. **Part** named **Hub**. Add two attachments inside the Hub:
   * `SpringAttachment` – where the spring connects.
   * `DamperAttachment` – where the damper force connects.
2. **Attachment** named **AxleAttachment** (parented to the Hub). Point its green arrow sideways, the same direction the wheel spins.
3. **Part** named **Wheel**. Add an attachment inside it called `WheelAttachment` centred on the axle.
4. **CylindricalConstraint** named **WheelConstraint** (parented to the Wheel). Set `Attachment0` to `Hub.AxleAttachment`, `Attachment1` to `Wheel.WheelAttachment`, and set `AngularActuatorType` to `Motor`.
5. **SpringConstraint** named **SuspensionSpring**. Set `Attachment0` to the matching `Hull.SuspensionMount_L1` (or R1, etc.) and `Attachment1` to `Hub.SpringAttachment`.

When the first wheel works, duplicate the wheel assembly model. Rename each copy to match its side and index (for example `WheelAssembly_R1`, `WheelAssembly_L2`, …) and update the spring’s `Attachment0` to use the matching hull attachment.

## 4. Add attributes for tuning
Every wheel assembly model (`WheelAssembly_L1`, etc.) needs these **Number** attributes. The values below are safe starting points:

| Attribute | Example value | What it does |
| --- | --- | --- |
| `RestLength` | `2` | Length the spring wants to stay at.
| `SpringStiffness` | `12000` | Strength of the spring.
| `DamperCoefficient` | `2500` | How much the wheel resists bouncing.
| `RaycastLength` | `3` | How far down to check for ground.
| `WheelRadius` | `1.5` | Size of the wheel.
| `DesignLoad` | `1500` | Weight the wheel should support.

Set these **Number** attributes on the Tank model itself (change later if you like):

| Attribute | Default | Purpose |
| --- | --- | --- |
| `MaxForwardSpeed` | `24` | Top speed going forward.
| `MaxReverseSpeed` | `12` | Top speed going backward.
| `TurnRate` | `0.5` | How sharply the tank can pivot.
| `DriveTorque` | `65000` | Power given to each wheel.
| `BrakeTorque` | `90000` | Force used when braking or empty.
| `MaxDampingForce` | `80000` | Safety limit on damper force.
| `AirDampingScale` | `0.2` | Damping when a wheel leaves the ground.

## 5. Install the scripts
1. Copy **TankSuspension.lua** into a ModuleScript (for example `ServerScriptService/TankSuspension`).
2. Copy **TankController.server.lua** into a Script parented to the Tank model.
3. Open the controller script and set the `TankSuspensionModule` variable at the top if you put the module somewhere else.
4. Press Play. If you see an error, read the message—it will usually tell you which attachment, attribute, or name is wrong.

That’s it! Adjust the numbers until the tank feels right for your game.
