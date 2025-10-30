# Tank Suspension Roblox Scripts

This repository contains two Roblox scripts that turn a hull with wheel
attachments into a tracked vehicle with raycast suspension:

* `TankSuspension.lua` – module that builds per-wheel springs, damping, and
  traction forces using raycasts.
* `TankController.server.lua` – helper Script that feeds `VehicleSeat`
  throttle/steer values into the suspension module.

Everything runs from attachments only. You reuse the attachments already placed
on the hull and tune the behaviour through script settings—no physical
constraints are required.

## 1. Prepare the tank model
1. Create a **Model** for the tank and set its `PrimaryPart` to the hull body.
2. Add a **VehicleSeat** named **DriverSeat** and weld or constrain it to the
   hull.

## 2. Place (or reuse) wheel attachments
1. Inside the hull part, add an **Attachment** for every wheel station. You can
   keep the ones your model already uses.
2. Either set attributes `WheelSide` (`"Left"`/`"Right"`) and `WheelIndex`
   (`1`, `2`, …) on each attachment, **or** include an `L` or `R` with a number
   anywhere in the attachment name (for example `Wheel_L1`, `LeftBogey02`,
   `TrackR3`).
3. Move the attachment to the spot where the wheel touches the ground. The
   script reads the attachment orientation, so there is no need to rotate it in
   a special way.

## 3. Install the scripts
1. Copy **TankSuspension.lua** into a ModuleScript (for example
   `ServerScriptService/TankSuspension`).
2. Copy **TankController.server.lua** into a Script parented to the tank model.
3. If you place the ModuleScript elsewhere, update the `require` call in the
   controller script.

## 4. Tune the suspension
All tuning happens in the `SETTINGS` table near the top of
`TankController.server.lua`.

### Suspension
* `RestLength` – Target distance (studs) between the attachment and ground
  contact before compression.
* `SpringStiffness` – Force per stud of compression applied by the spring.
* `Damping` – Amount of force that resists suspension velocity. Increase to kill
  oscillations, decrease for a softer ride.
* `PreloadForce` – Constant force (in newtons) added to each wheel so the tank
  supports itself before compression builds.
* `RaycastLength` – How far to raycast beneath each attachment.
* `WheelRadius` – Radius of the road wheel/roller. The raycast hit distance is
  offset by this value.
* `MaxForceMultiplier` – Limits spring force relative to each wheel’s share of
  the tank weight. Keep it above `1` so the wheels can hold the hull up when the
  tank lands.
* `AntiRollStiffness` – Balances the compression between the left and right
  wheels at the same index to resist body roll. Set to `0` to disable.
* `MassSmoothing` – Rate used to smooth sudden mass changes (like a driver
  entering the seat). Higher values adapt faster.
* `AirDamping` – Optional damping applied when a wheel is off the ground.
* `UseAttachmentUp` – When `true`, the raycast direction follows each
  attachment’s up axis. Set to `false` to force the raycasts to use the hull’s up
  vector instead.

### Traction
* `LongitudinalStiffness` – Resists forward/back slip when throttle is neutral.
* `LateralStiffness` – Resists sideways sliding on the contact patch.
* `RollingDrag` – Constant drag applied while the wheel is rolling.
* `GripCoefficient` – Multiplier that caps planar force relative to the current
  vertical load. Raising it increases traction; lowering it allows more slip.

### Drive
* `MaxForwardSpeed` – Target speed for a fully throttled track moving forward.
* `MaxReverseSpeed` – Target speed when reversing.
* `TurnRate` – How strongly steering input skews the left/right track commands.
* `DriveForce` – Maximum drive force each wheel uses to chase the target speed.
* `IdleBrakeForce` – Damping applied when throttle is close to zero so the tank
  coasts to a stop.
* `HandBrakeForce` – Extra damping applied while the handbrake is set (for
  example when no driver is seated).

## 5. Run and iterate
Play the game, sit in the DriverSeat, and tweak the numbers until the tank feels
right. The module recalculates suspension forces every frame, smoothing mass
changes so the hull stays planted when a player enters or exits.
