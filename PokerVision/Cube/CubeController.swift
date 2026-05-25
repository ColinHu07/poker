import CoreGraphics
import SceneKit

enum RightHandMode: String {
    case idle
    case pinchDrag
    case oneFingerRotate
    case grabRotate
    case twoFingerScale
}

@MainActor
final class CubeController {
    let cubeScene: CubeScene
    let stateMachine: CubeStateMachine

    private(set) var currentCubePosition = CGPoint(x: 0.5, y: 0.6)
    private let fingertipOffset: CGFloat = 0.05

    // Right-hand pinch drag
    private var dragSmoother = SmoothedPoint(smoothing: 0.55)
    private let pinchThreshold: CGFloat = 0.07
    private let pinchReleaseThreshold: CGFloat = 0.10

    // Scale (right hand two-finger on ring)
    private var scaleSmoother = SmoothedValue(smoothing: 0.70)
    private var currentScale: CGFloat = 1.0
    private var rightScaleBaseline: CGFloat?
    private var rightScaleStartScale: CGFloat?

    // Rotation (right hand grab ring)
    private var accRotX: Float = 0
    private var accRotY: Float = 0
    private var accRotZ: Float = 0
    private var rotVelX: Float = 0
    private var rotVelY: Float = 0
    private var rotVelZ: Float = 0
    private var rightGrabPrevPos: CGPoint?
    private var rightGrabPrevAngle: CGFloat?
    private var rightOneFingerPrevTip: CGPoint?
    private let rotationSensitivity: Float = 8.0
    private let oneFingerRotSensitivity: Float = 10.0
    private let zRotationGain: Float = 2.5
    private let rotationFriction: Float = 0.92

    // Ring zone
    private let ringBaseRadius: CGFloat = 0.16
    private var rightHandMode: RightHandMode = .idle

    var onStateChange: ((CubeState) -> Void)?

    // Diagnostics
    private(set) var lastHandPosition: CGPoint?
    private(set) var currentCubeScale: CGFloat = 1.0
    private(set) var leftHandDetected = false
    private(set) var rightHandDetected = false
    private(set) var pointingDetected = false
    private(set) var rightHandModeStr: String = "idle"
    private(set) var currentRotation = SCNVector3Zero
    private var logCounter = 0

    init() {
        cubeScene = CubeScene()
        stateMachine = CubeStateMachine()
        stateMachine.onStateChange = { [weak self] state in
            self?.handleStateTransition(state)
        }
    }

    // MARK: - Session lifecycle

    /// Full reset: hides cube, clears all interaction and transform state.
    func resetForNewSession() {
        NSLog("[Reset] resetForNewSession called (state was %@)", stateMachine.state.rawValue)
        stateMachine.transition(to: .hidden)
        currentCubePosition = CGPoint(x: 0.5, y: 0.6)
        currentScale = 1.0
        currentCubeScale = 1.0
        accRotX = 0; accRotY = 0; accRotZ = 0
        rotVelX = 0; rotVelY = 0; rotVelZ = 0
        dragSmoother.reset()
        scaleSmoother.reset()
        rightScaleBaseline = nil
        rightScaleStartScale = nil
        rightGrabPrevPos = nil
        rightGrabPrevAngle = nil
        rightOneFingerPrevTip = nil
        rightHandMode = .idle
        rightHandModeStr = "idle"
        leftHandDetected = false
        rightHandDetected = false
        pointingDetected = false
        lastHandPosition = nil
        currentRotation = SCNVector3Zero
    }

    // Off-screen safety margins (normalized coords, 0–1 is on-screen)
    private let safeMargin: CGFloat = 0.08

    /// Returns true if the cube center is outside the safe viewport.
    func isCubeOffScreen() -> Bool {
        let x = currentCubePosition.x
        let y = currentCubePosition.y
        return x < -safeMargin || x > 1 + safeMargin
            || y < -safeMargin || y > 1 + safeMargin
    }

    // MARK: - Main entry point

    func updateHandTracking(_ result: HandTrackingResult) {
        logCounter += 1
        leftHandDetected = result.leftHand != nil
        rightHandDetected = result.rightHand != nil
        pointingDetected = result.isPointingDetected

        if let lh = result.leftHand {
            lastHandPosition = lh.indexTip
        }

        // LEFT hand: summon only (finger-level gating).
        if result.isPointingDetected {
            if stateMachine.state == .hidden {
                let leftIsPointing = result.leftHand?.isIndexPointing ?? false
                if leftIsPointing {
                    let tip = result.leftHand?.indexTip
                    if let tip {
                        NSLog("[Summon] Allowed: LEFT index pointing → spawn at (%.3f, %.3f)",
                              tip.x, tip.y)
                    } else {
                        NSLog("[Summon] Allowed but LEFT indexTip missing — falling back to center")
                    }
                    spawnCube(at: tip)
                } else {
                    NSLog("[Summon] Ignored: pointingEvent fired but LEFT index not pointing (RH may be pointing).")
                }
            } else {
                NSLog("[Summon] Triggered but ignored (cube already spawned), state=%@",
                      stateMachine.state.rawValue)
            }
        }

        // Right hand interacts with spawned cube
        if stateMachine.state == .idle {
            processRightHandInteraction(result.rightHand)
        } else if rightHandMode != .idle {
            endRightHandInteraction()
        }

        // Apply rotation inertia
        if stateMachine.state == .idle || stateMachine.state == .spawning {
            applyRotation()
        }

        // Auto-reset if cube drifted off-screen
        if stateMachine.state == .idle && isCubeOffScreen() {
            NSLog("[Reset] Cube off-screen at (%.3f, %.3f) — auto-resetting",
                  currentCubePosition.x, currentCubePosition.y)
            resetForNewSession()
        }

        if logCounter % 20 == 0 {
            NSLog("[CubeDebug] state=%@ LH=%d RH=%d pointing=%d RHmode=%@ cubePos=(%.3f, %.3f) scale=%.2f",
                  stateMachine.state.rawValue,
                  leftHandDetected ? 1 : 0,
                  rightHandDetected ? 1 : 0,
                  pointingDetected ? 1 : 0,
                  rightHandModeStr,
                  currentCubePosition.x,
                  currentCubePosition.y,
                  currentCubeScale)
        }
    }

    // MARK: - Spawn

    private func spawnCube(at fingertip: CGPoint?) {
        stateMachine.transition(to: .spawning)
        dragSmoother.reset()
        scaleSmoother.reset()
        currentScale = 1.0
        currentCubeScale = 1.0
        rightScaleBaseline = nil
        rightScaleStartScale = nil
        accRotX = 0; accRotY = 0; accRotZ = 0
        rotVelX = 0; rotVelY = 0; rotVelZ = 0
        rightGrabPrevPos = nil
        rightGrabPrevAngle = nil
        rightOneFingerPrevTip = nil
        rightHandMode = .idle
        rightHandModeStr = "idle"

        let pos: SCNVector3
        if let p = fingertip {
            pos = SCNVector3(Float(p.x), Float(p.y + fingertipOffset), 0)
            NSLog("[Spawn] Anchored to fingertip (%.3f, %.3f) + offset → (%.3f, %.3f)",
                  p.x, p.y, pos.x, pos.y)
        } else {
            pos = SCNVector3(0.5, 0.6, 0)
            NSLog("[Spawn] FALLBACK to center (0.5, 0.6) — no fingertip data")
        }
        currentCubePosition = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
        cubeScene.showCube(at: pos)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.stateMachine.state == .spawning {
                self?.stateMachine.transition(to: .idle)
            }
        }
    }

    // MARK: - Right hand interaction

    private func processRightHandInteraction(_ rightHand: HandLandmarks?) {
        guard let rh = rightHand else {
            if rightHandMode != .idle { endRightHandInteraction() }
            return
        }

        let ringR = max(CGFloat(0.10), ringBaseRadius * currentScale)
        let exitR = ringR * 1.4

        let pinchDist = ptDist(rh.thumbTip, rh.indexTip)
        let pinchMid = CGPoint(
            x: (rh.thumbTip.x + rh.indexTip.x) / 2,
            y: (rh.thumbTip.y + rh.indexTip.y) / 2
        )
        let pinchToCube = ptDist(pinchMid, currentCubePosition)
        let thumbDist = ptDist(rh.thumbTip, currentCubePosition)
        let indexDist = ptDist(rh.indexTip, currentCubePosition)
        let palmDist = ptDist(rh.palmCenter, currentCubePosition)

        // Log the computed interaction geometry once right-hand is present.
        if rightHandMode == .idle {
            NSLog("[CubeRHGeom] pinchDist=%.3f pinchToCube=%.3f ringR=%.3f thumbDist=%.3f indexDist=%.3f palmDist=%.3f fingerSpread=%.2f",
                  pinchDist, pinchToCube, ringR,
                  thumbDist, indexDist, palmDist,
                  rh.fingerSpread)
        }

        switch rightHandMode {
        case .idle:
            if pinchDist < pinchThreshold && pinchToCube < ringR {
                beginPinchDrag(rh)
            } else if thumbDist < ringR && indexDist < ringR && pinchDist > 0.09 {
                beginTwoFingerScale(rh)
            } else if indexDist < ringR && pinchDist >= pinchThreshold
                && oneFingerRotateEligible(rh)
            {
                beginOneFingerRotate(rh)
            } else if palmDist < ringR && rh.fingerSpread < 1.2 {
                beginGrabRotate(rh)
            }

        case .pinchDrag:
            if pinchDist < pinchReleaseThreshold {
                updatePinchDrag(rh)
            } else {
                NSLog("[Cube] Pinch released — cube stays at (%.3f, %.3f)",
                      currentCubePosition.x, currentCubePosition.y)
                endRightHandInteraction()
            }

        case .twoFingerScale:
            if thumbDist < exitR || indexDist < exitR {
                updateTwoFingerScale(rh)
            } else {
                endRightHandInteraction()
            }

        case .oneFingerRotate:
            let scaleGestureActive =
                thumbDist < ringR && indexDist < ringR && pinchDist > 0.09
            let dragGestureActive =
                pinchDist < pinchThreshold && pinchToCube < ringR
            if dragGestureActive || scaleGestureActive {
                NSLog(
                    "[SwipeRot] ended — stolen by %@",
                    dragGestureActive ? "drag" : "scale")
                endRightHandInteraction()
            } else if indexDist < exitR {
                updateOneFingerRotate(rh)
            } else {
                NSLog("[SwipeRot] ended — index left zone (indexDist=%.3f exitR=%.3f)",
                      indexDist, exitR)
                endRightHandInteraction()
            }

        case .grabRotate:
            if palmDist < exitR {
                updateGrabRotate(rh)
            } else {
                endRightHandInteraction()
            }
        }
    }

    // MARK: - Pinch drag

    private func beginPinchDrag(_ rh: HandLandmarks) {
        rightHandMode = .pinchDrag
        rightHandModeStr = "drag"
        dragSmoother.reset()
        let mid = CGPoint(
            x: (rh.thumbTip.x + rh.indexTip.x) / 2,
            y: (rh.thumbTip.y + rh.indexTip.y) / 2
        )
        _ = dragSmoother.update(mid)
        NSLog("[CubeGrab] pinchDrag began at mid=(%.3f, %.3f) state=%@",
              mid.x, mid.y, stateMachine.state.rawValue)
    }

    private func updatePinchDrag(_ rh: HandLandmarks) {
        let mid = CGPoint(
            x: (rh.thumbTip.x + rh.indexTip.x) / 2,
            y: (rh.thumbTip.y + rh.indexTip.y) / 2
        )
        let smoothed = dragSmoother.update(mid)
        currentCubePosition = smoothed
        cubeScene.updatePosition(SCNVector3(Float(smoothed.x), Float(smoothed.y), 0))
    }

    // MARK: - Two-finger scale

    private func beginTwoFingerScale(_ rh: HandLandmarks) {
        rightHandMode = .twoFingerScale
        rightHandModeStr = "scale"
        rightScaleBaseline = ptDist(rh.thumbTip, rh.indexTip)
        rightScaleStartScale = currentScale
        NSLog("[Ring] Two-finger scale began, baseline=%.4f scale=%.2f",
              rightScaleBaseline ?? 0, currentScale)
    }

    private func updateTwoFingerScale(_ rh: HandLandmarks) {
        guard let baseline = rightScaleBaseline,
              let startScale = rightScaleStartScale,
              baseline > 0.005 else { return }
        let currentDist = ptDist(rh.thumbTip, rh.indexTip)
        let rawScale = startScale * (currentDist / baseline)
        let clamped = min(max(rawScale, 0.25), 3.5)
        currentScale = scaleSmoother.update(clamped)
        currentCubeScale = currentScale
        cubeScene.updateScale(Float(currentScale))
    }

    // MARK: - One-finger swipe rotate (index tip delta → yaw / pitch)

    private func beginOneFingerRotate(_ rh: HandLandmarks) {
        rightHandMode = .oneFingerRotate
        rightHandModeStr = "swipeRot"
        rightOneFingerPrevTip = rh.indexTip
        NSLog("[SwipeRot] began indexTip=(%.3f, %.3f)", rh.indexTip.x, rh.indexTip.y)
    }

    private func updateOneFingerRotate(_ rh: HandLandmarks) {
        guard let prev = rightOneFingerPrevTip else {
            rightOneFingerPrevTip = rh.indexTip
            return
        }
        let dx = Float(rh.indexTip.x - prev.x)
        let dy = Float(rh.indexTip.y - prev.y)
        if abs(dx) > 0.0015 || abs(dy) > 0.0015 {
            rotVelY = -dx * oneFingerRotSensitivity
            rotVelX = -dy * oneFingerRotSensitivity
            NSLog(
                "[SwipeRot] dx=%.4f dy=%.4f → yawVel=%.3f pitchVel=%.3f euler=(%.3f,%.3f,%.3f)",
                dx, dy, rotVelY, rotVelX, accRotX, accRotY, accRotZ)
        }
        rightOneFingerPrevTip = rh.indexTip
    }

    // MARK: - Grab rotate

    private func beginGrabRotate(_ rh: HandLandmarks) {
        rightHandMode = .grabRotate
        rightHandModeStr = "rotate"
        rightGrabPrevPos = rh.palmCenter
        rightGrabPrevAngle = rh.handAngle
        NSLog("[Ring] Grab rotate began")
    }

    private func updateGrabRotate(_ rh: HandLandmarks) {
        if let prevPos = rightGrabPrevPos {
            let dx = Float(rh.palmCenter.x - prevPos.x)
            let dy = Float(rh.palmCenter.y - prevPos.y)
            if abs(dx) > 0.003 || abs(dy) > 0.003 {
                rotVelY = -dx * rotationSensitivity
                rotVelX = -dy * rotationSensitivity
                NSLog("[Rot] dx=%.4f dy=%.4f → yaw=%.3f roll=%.3f", dx, dy, rotVelY, rotVelX)
            }
        }
        if let prevAngle = rightGrabPrevAngle {
            var dz = Float(rh.handAngle - prevAngle)
            if dz > .pi { dz -= 2 * .pi }
            if dz < -.pi { dz += 2 * .pi }
            if abs(dz) > 0.01 {
                rotVelZ = dz * zRotationGain
            }
        }
        rightGrabPrevPos = rh.palmCenter
        rightGrabPrevAngle = rh.handAngle
    }

    // MARK: - End right-hand interaction

    private func endRightHandInteraction() {
        let old = rightHandMode
        rightHandMode = .idle
        rightHandModeStr = "idle"
        rightScaleBaseline = nil
        rightScaleStartScale = nil
        rightGrabPrevPos = nil
        rightGrabPrevAngle = nil
        rightOneFingerPrevTip = nil
        if old != .idle {
            NSLog("[Ring] Interaction ended (was %@)", old.rawValue)
        }
    }

    // MARK: - Rotation with inertia

    private func applyRotation() {
        accRotX += rotVelX
        accRotY += rotVelY
        accRotZ += rotVelZ

        if rightHandMode != .grabRotate && rightHandMode != .oneFingerRotate {
            rotVelX *= rotationFriction
            rotVelY *= rotationFriction
            rotVelZ *= rotationFriction
            if abs(rotVelX) < 0.0005 { rotVelX = 0 }
            if abs(rotVelY) < 0.0005 { rotVelY = 0 }
            if abs(rotVelZ) < 0.0005 { rotVelZ = 0 }
        }

        currentRotation = SCNVector3(accRotX, accRotY, accRotZ)
        cubeScene.updateRotation(currentRotation)
        if logCounter % 20 == 0 && rightHandMode == .oneFingerRotate {
            NSLog(
                "[SwipeRot] finalize euler=(%.3f,%.3f,%.3f)",
                currentRotation.x, currentRotation.y, currentRotation.z)
        }
    }

    // MARK: - State transitions

    private func handleStateTransition(_ state: CubeState) {
        switch state {
        case .hidden, .dismissed:
            cubeScene.hideCube()
            rotVelX = 0; rotVelY = 0; rotVelZ = 0
            endRightHandInteraction()
        default:
            break
        }
        onStateChange?(state)
    }

    // MARK: - Helpers

    private func ptDist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// One-finger swipe: index extended without requiring full strict point pose.
    private func oneFingerRotateEligible(_ rh: HandLandmarks) -> Bool {
        if rh.isIndexPointing { return true }
        let idx = rh.indexExtension
        let other = rh.otherMaxExtension
        return idx > 0.38 && other < idx * 0.92
    }
}
