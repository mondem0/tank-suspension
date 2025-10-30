# Tank Suspension Roblox Scripts

This project gives you two Roblox scripts:

* `TankSuspension.lua` – a raycast suspension module that applies springs, dampers, and traction forces at each wheel attachment.
* `TankController.server.lua` – a helper script that reads a `VehicleSeat` and feeds the input into the suspension module.

Follow the steps below to set everything up. No wheel constraints or springs are needed—just attachments that mark where the wheels go.

## 1. Prepare the tank model
1. Create a **Model** named **Tank** and set its `PrimaryPart` to the main body part (call it **Hull**).
2. Add a **VehicleSeat** named **DriverSeat**. Weld or constrain it to the Hull so it moves with the body.

## 2. Place the wheel attachments
1. Inside the Hull, insert an **Attachment** for every wheel location.
2. Name them `Wheel_L1`, `Wheel_R1`, `Wheel_L2`, `Wheel_R2`, and so on. Use `L` for the tank's left side and `R` for the right; increase the numbers from front to back.
3. Move each attachment to the spot where the wheel should contact the ground.
4. Rotate the attachment so its green arrow (the attachment's up axis) points straight down toward the ground and the red arrow points toward the front of the tank. The script uses this orientation to know which way is up, forward, and sideways.

You can duplicate the first attachment to create the others—just rename each copy to match its side and index.

## 3. (Optional) Add wheel visuals
The physics only need the attachments, but you can still add wheel meshes or parts for visuals. Weld them to the Hull or use constraints of your choice; the suspension forces are applied directly to the Hull.

## 4. Install the scripts
1. Copy **TankSuspension.lua** into a ModuleScript (for example `ServerScriptService/TankSuspension`).
2. Copy **TankController.server.lua** into a Script parented to the Tank model.
3. Open the controller script and edit the `SETTINGS` table near the top. These numbers control how stiff the springs are, how sticky the tracks feel, and how fast the tank drives.
4. If you move the ModuleScript, update the require path in the controller script (the default lookup already covers a sibling `TankSuspension` module or one in `ServerScriptService`).

## 5. Tune the suspension values
Each section of the `SETTINGS` table controls a part of the simulation:

* `Suspension`
  * `RestLength` – Distance (in studs) the spring wants to keep between the attachment and the ground contact point.
  * `SpringStiffness` – How strong the spring pushes back when compressed.
  * `DamperCoefficient` – Amount of damping applied to stop bouncing.
  * `RaycastLength` – How far down to look for the ground from each attachment.
  * `WheelRadius` – Radius of the wheel or track roller used to offset the ray hit distance.
  * `MaxForce` – Safety limit for the vertical suspension force per wheel.
  * `AirDamping` – Optional force applied when a wheel is off the ground (set to `0` to disable).
* `Traction`
  * `LateralStiffness` – Resistance to sideways sliding.
  * `LongitudinalStiffness` – Resistance to forward/back slipping.
  * `RollingFriction` – Constant drag that keeps the tank from drifting forever.
  * `MaxTractionForce` – Cap on the combined traction force per wheel.
* `Drive`
  * `MaxForwardSpeed` – Target top speed when driving forward.
  * `MaxReverseSpeed` – Target top speed when reversing.
  * `TurnRate` – How strongly steering input skews the left/right track speeds.
  * `DriveForce` – Maximum drive force each wheel can apply when chasing the target speed.
  * `BrakeForce` – Extra force used to slow the tank when the throttle is released or the handbrake is set.

Play the game, sit in the DriverSeat, and tweak the numbers until the tank handles the way you want.
