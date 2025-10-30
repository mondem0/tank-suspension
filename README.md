# Tank Suspension Roblox Scripts

This project gives you two Roblox scripts:

* `TankSuspension.lua` – a raycast suspension module that applies springs, dampers, and traction forces at each wheel attachment.
* `TankController.server.lua` – a helper script that reads a `VehicleSeat` and feeds the input into the suspension module.

Follow the steps below to set everything up. No wheel constraints or springs are needed—just attachments that mark where the wheels go. The script measures the tank’s mass every frame, so it stays planted even when a driver hops in.

## 1. Prepare the tank model
1. Create a **Model** named **Tank** and set its `PrimaryPart` to the main body part (call it **Hull**).
2. Add a **VehicleSeat** named **DriverSeat**. Weld or constrain it to the Hull so it moves with the body.

## 2. Place the wheel attachments
1. Inside the Hull, insert an **Attachment** for every wheel location.
2. Either:
   * Keep your existing attachments and set two attributes on each one: `WheelSide` (`"Left"`/`"Right"`) and `WheelIndex` (`1`, `2`, ...), **or**
   * Name them with an `L` or `R` and a number anywhere in the name (for example `Wheel_L1`, `LeftBogey02`, `TrackR3`).
3. Move each attachment to the spot where the wheel should contact the ground. The script reads the tank body's orientation, so you do **not** have to rotate the attachments in any special way.

You can duplicate the first attachment to create the others—just rename each copy (or update its attributes) so the side and index are unique.

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
  * `RestLength` – Target distance (in studs) from each attachment to the ground contact point.
  * `SpringStiffness` – Force applied per stud of compression; higher values make the suspension stiffer.
  * `DampingRatio` – Multiplier applied to critical damping; raise it to kill oscillations, lower it for a softer response.
  * `Preload` – Extra compression (in studs) added to each spring so the tank settles without slamming to the stops.
  * `RaycastLength` – How far down to look for the ground from each attachment.
  * `WheelRadius` – Radius of the wheel or roller. The raycast hit distance is offset by this amount.
  * `MaxForceMultiplier` – Scales the maximum vertical force relative to the tank’s weight per wheel. Keep it above `1` so the springs can hold the tank up even when landing.
  * `AntiRollStiffness` – Balances left/right compression to resist body roll. Set to `0` to disable.
  * `AirDamping` – Optional world-space damping when a wheel is off the ground. Set to `0` to disable.
* `Traction`
  * `LateralStiffness` – Resistance to sideways sliding on the contact patch.
  * `LongitudinalStiffness` – Resistance to forward/back slipping when no throttle is applied.
  * `RollingDrag` – Constant drag that bleeds off speed so the tank coasts to a stop.
  * `MaxPlanarForceMultiplier` – Caps the combined traction force based on the wheel’s share of the tank weight.
* `Drive`
  * `MaxForwardSpeed` – Target top speed when driving forward.
  * `MaxReverseSpeed` – Target top speed when reversing.
  * `TurnRate` – How strongly steering input skews the left/right track speeds.
  * `DriveForce` – Maximum drive force each wheel can apply when chasing the target speed.
  * `BrakeForce` – Extra force used to slow the tank when the throttle is released or the handbrake is set.

Play the game, sit in the DriverSeat, and tweak the numbers until the tank handles the way you want.

The suspension automatically recalculates the tank’s weight distribution every frame, so the same settings stay stable whether the hull is empty, carrying cargo, or supporting a seated driver.
