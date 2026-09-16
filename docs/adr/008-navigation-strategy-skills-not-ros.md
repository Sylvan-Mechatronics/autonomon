# ADR-008: Navigation Strategy — Composable Skills over a Shared World State, Without ROS

**Status:** Accepted
**Date:** 2026-09-13
**Deciders:** Perceptua

---

## Context

The workspace review of 2026-09-13 (`REVIEW-2026-09-13.md` at the workspace root)
measured autonomon against the product goal in the business plan: a
semi-autonomous outdoor utility cart that **follows its operator hands-free** or
**moves point-to-point on command**, avoiding obstacles, with a field-ready
prototype targeted for spring 2027.

What exists today is a reactive layer, not a navigation stack:

- Three routines (`explore`, `follow-user`, `patrol`), each a **fixed pipeline**
  with its own world model and planner. Planners select among hand-written
  action tuples; none represents a goal.
- **No state estimation.** The brain receives ultrasonic, grayscale, a camera
  frame, and battery. There is no odometry, IMU, GPS, or depth, so nothing knows
  where the robot is or which way it faces.
- **Following has no obstacle or cliff avoidance.** `follow-user` fans in the
  ultrasonic only for standoff distance; `FollowPlanner` never reads
  `obstacle_ahead` or `cliff_detected`, and the avoidance behaviour that does
  exist (`AvoidancePlanner`) cannot be composed with it because each routine owns
  its planner.
- **Perception is too slow to steer on.** YOLOv8n on the Pi Zero 2W runs at
  ~0.8 Hz, forcing 1.5 s drive bursts on a stale heading.
- **No arbitration.** Manual control, the AI relay, the voice listener, an
  autonomon routine, and nomopractic's own Phase-11 `explore` all write the same
  actuators, last writer wins.

Continuing to add entries to the routine registry will not converge on the
product. Three architectures were weighed:

- **A. Skills + arbiter in autonomon.** One always-running pipeline; small
  parameterised behaviours ("skills") publish desired motion into a priority
  arbiter over a shared world state.
- **B. ROS 2 + Nav2.** Adopt the standard navigation stack (localisation,
  costmaps, planners, controllers, recoveries, behaviour-tree navigator).
- **C. An agentic task layer** (an LLM composing skills) on top of A or B.

A survey of autonomy work outside ROS (2024–2026) was also made; the relevant
findings are recorded under *Alternatives Considered*.

## Decision

**Adopt A.** autonomon becomes a single pipeline of composable **skills** over a
**shared world state**, selected by a **priority arbiter**, with ROS
conventions used as the internal contract so that no ROS is required at any
planned milestone. C is layered on later. B is not adopted; the one place it
would have entered (the cart's low-level controller) is gated on a different
option (D3 below).

### D1 — Shared world state replaces per-routine world models

One `WorldState` object carries everything the skills read: pose estimate
(odom frame), body twist, `obstacle_ahead`, `cliff_detected`, the occupancy
snapshot, the target track (bearing, distance, freshness), and battery. The
existing `ObstacleWorldModel`, `OccupancyWorldModel`, and `TargetWorldModel`
become **estimators that update fields of the shared state** rather than
separate `WorldModelBase` pipelines. Message shapes on the queues are unchanged
(`PerceptionEvent` in, `WorldStateUpdate` out).

### D2 — Skills and a priority arbiter replace the routine registry

A **skill** is a small class with `evaluate(state, now) -> Motion | None`,
where `Motion` is a body-frame velocity request (`v` m/s, `ω` rad/s) plus
optional camera pan/tilt and a priority. The arbiter (the Planning position)
runs every tick, asks each active skill, and emits the highest-priority
non-`None` motion as the `ActionPlan`. Fixed priority order, highest first:

1. `estop` — software e-stop; always wins.
2. `cliff_stop` — grayscale edge → stop and reverse.
3. `avoid` — obstacle ahead → stop, reverse, steer (today's
   `AvoidancePlanner` logic).
4. Task skills: `follow_operator`, `navigate_to`, `retrace`, `hold`, `wander`.
5. `idle` — zero motion, camera level.

A "routine" is now just the set of task skills enabled at launch; `explore`
= `{wander}`, `follow-user` = `{follow_operator}`, `patrol` = `{wander}` with
the occupancy caution rule. The `RulePlanner` TOML tables are kept as the
implementation of `wander`'s caution behaviour, not as a planner.

### D3 — Actuation contract is body velocity; kinematics live in nomopractic

The Action layer emits `v`/`ω`; nomopractic converts to wheel/steer commands for
the chassis (Ackermann on the PicarX today, whatever the cart uses tomorrow).
The existing `drive`/`steer` percent/angle IPC stays as the low-level path; a
new `cmd_vel { v_mps, omega_radps, ttl_ms }` method sits beside it. When the
cart drivetrain is chosen, the decision *ArduPilot Rover on a flight controller
vs. nomopractic* is taken then (a Guided-mode velocity command with a 3 s
timeout is the same lease contract), and either way the layers above D3 do not
change.

### D4 — Following uses UWB ranging as the primary sensor; vision confirms

Two DW3000/DWM3000 UWB modules (one on the robot, one worn by the operator)
provide range at ~10 cm accuracy, and bearing with a PDoA module or two robot
anchors, at tens of hertz, independent of light and clothing. This is a new
**raw input** exposed by nomothetic (`GET /api/sensor/uwb`) and consumed by a
`UwbPerception` source. Vision (`VisionPerception`) remains a secondary
confirmation and search aid. This removes the 0.8 Hz problem for following on
current hardware and is how commercial follow-me carts work.

### D5 — Point-to-point is teach-and-repeat first, not map-and-plan

`navigate_to` is first implemented as **retrace with visual correction**: while
following or being driven, the robot records a trail of odometry poses with
periodic low-resolution camera keyframes; "go back to the shed" replays the
trail in reverse, correcting lateral/heading drift by matching keyframes
(QVPR-style teach-and-repeat, monocular + wheel odometry, no GPS, low compute).
`avoid` and `cliff_stop` stay active throughout. A metric map and a global
planner are deferred until a job requires routing across unseen ground.

### D6 — Odometry and IMU are the next raw inputs

Wheel encoders (or motor hall sensors) and a low-cost I2C IMU are added in
nomopractic and exposed by nomothetic as `GET /api/sensor/odometry` and
`GET /api/sensor/imu`. A `PoseEstimator` (dead reckoning first, complementary
filter for heading) fills the pose/twist fields of the shared world state. D2,
D5, and any future navigation depend on this.

### D7 — Compute moves to a Raspberry Pi 5 with an NPU before outdoor trials

A Pi 5 with an AI HAT+ (Hailo-8L/8, YOLOv8n at 30–136 fps) or AI HAT+ 2
(Hailo-10H, 40 TOPS, 8 GB) keeps the Python brain intact and makes per-frame
detection and monocular depth feasible on-device. The Zero 2W remains a valid
target for the gateway and firmware.

### D8 — The agentic layer sits above the arbiter

Once skills exist, the Claude tool loop currently in nomothetic (`ai_command`)
moves into autonomon as the **task layer**: its tools become skills
(`follow_operator`, `go_to`, `wait_here`, `return_to_operator`, `stop`), it
composes them into a behaviour tree per request, and the arbiter and safety
skills execute deterministically regardless of what the model asks. The model is
never on the control loop.

## Rationale

- **Following does not need Nav2** under any option, and following is the
  product's first behaviour. The safety gap (following without avoidance) is
  closed by D1/D2 with existing code.
- **Nav2 bringup would be redone on the cart.** Bringup on the PicarX does not
  transfer to a different chassis, sensors, and compute; and the Zero 2W cannot
  host ROS 2. Doing it now buys nothing.
- **Teach-and-repeat covers the hauling loop** (out with the operator, back
  along the same path) with odometry plus a camera, no GPS and no map. It is the
  smallest thing that delivers "point-to-point on command".
- **UWB is cheaper and more robust than vision for following** and turns a
  compute problem into a $50 sensor.
- **ROS-shaped internal types** (twist, odometry, stamped pose, costmap-like
  occupancy, behaviour-tree arbiter) mean that if Nav2 or ArduPilot is adopted
  later, it replaces the implementation of one skill, not the brain.
- **Minimalism.** A is a refactor of ~5 k lines already in the repo. B adds a
  middleware, a build system, and a dependency closure larger than the whole
  workspace.

## Trade-offs

| Benefit | Cost |
|---|---|
| Safe following (subsumed by avoid/cliff) within weeks | Per-routine world models and planners are refactored into estimators and skills; `PursuitPlanner` is deleted |
| No ROS at any planned milestone | A metric map / global planner is not available until it is justified; unseen-ground routing is out of scope |
| Chassis-agnostic action contract | nomopractic gains a kinematics layer and a `cmd_vel` method |
| Robust following from a $50 sensor | A wearable tag is part of the product |
| Brain stays Python on a Pi 5 | Compute upgrade before outdoor trials |

## Alternatives Considered

- **ROS 2 + Nav2 (B).** Rejected for now. It is the right answer to metric
  navigation across unseen ground, which is not a current milestone; it needs
  hardware the project does not yet have, and most of autonomon would become
  throwaway. Revisit only if a customer job requires routing beyond retrace.
- **ArduPilot Rover / PX4 v1.16 as the low-level autopilot.** Not rejected —
  deferred to the cart drivetrain decision (D3). It supplies EKF, RTK, geofence,
  waypoints, follow (phone-GPS accuracy), and rangefinder/lidar avoidance in
  mature firmware, over MAVLink, with a lease-like Guided timeout. It replaces
  nomopractic on the cart, not autonomon.
- **Rust dataflow runtimes (dora 1.0-rc, Copper).** Middleware replacements
  with record/replay; they carry no localisation or planning and would replace
  the asyncio pipeline for no navigation gain. Not adopted.
- **Navigation foundation models (GNM/ViNT/NoMaD; 2026 successors).**
  Image-goal navigation from a monocular camera with a topological image map;
  Jetson-class compute; research-grade collision rates. A plausible future
  implementation of `navigate_to` behind the same skill interface; not a safety
  layer. Tracked, not adopted.
- **Vision-language-action models (SmolVLA, Gemini Robotics On-Device).**
  Manipulation-focused, limited availability, and not acceptable on a 500 lb
  vehicle's control loop. Only the task-layer pattern (LLM composes skills into
  a behaviour tree) is taken, in D8.
- **Viam.** AGPL-3.0, cloud-centric configuration, and it would replace
  nomothetic wholesale. Conflicts with a minimal codebase the project owns.
- **Keep adding routines to the registry.** Rejected: each routine re-implements
  safety, and none can express a goal.

## Consequences

- The autonomon roadmap gains Phases 8–11 (odometry/IMU inputs, shared world
  state + arbiter with `follow_operator` subsumed by `avoid`/`cliff_stop`, UWB
  following, teach-and-repeat `navigate_to`), recorded in `docs/roadmap.md`.
- nomopractic and nomothetic roadmaps gain the matching raw-input work
  (encoders, IMU, UWB, `cmd_vel`).
- nomopractic's Phase-11 `explore` routine is reduced to reflexes
  (`stop if < N cm`, `stop on cliff`) and its wandering behaviour removed, so
  there is one brain.
- nomothetic defines a single vehicle-ownership/arbitration rule (manual > AI >
  routine, with an e-stop that outranks all) so command sources stop racing.
- The routine registry, `nomon_manifest`, and the catalogue file (ADR-005) are
  retained as the launch/discovery surface; "routine" comes to mean "a named
  set of enabled skills".
- ADR-003 (routine registry as the catalogue) and ADR-007 (occupancy grid +
  rule planner) are amended, not superseded: the registry remains the
  catalogue, and the occupancy grid becomes a field of the shared state.

## References

- `REVIEW-2026-09-13.md` (workspace root) — the review that motivated this ADR
- ADR-001 (layered architecture), ADR-003 (routine registry), ADR-004 (brain
  principle), ADR-006 (lean core), ADR-007 (occupancy grid + rule planner)
- Non-ROS survey sources: ArduPilot Rover follow mode and object avoidance docs;
  ArduPilot Rover Guided-mode MAVLink commands; PX4 v1.16 rover rework; Qorvo
  DWM3000; QVPR teach-repeat (IROS 2021) and VT&R3; GNM/ViNT/NoMaD; Raspberry Pi
  AI HAT+ / AI HAT+ 2; dora-rs; Copper; Gemini Robotics On-Device; Viam RDK
  licence
