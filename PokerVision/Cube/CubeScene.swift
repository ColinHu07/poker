import SceneKit
import UIKit

final class CubeScene {
    let scene: SCNScene
    let containerNode: SCNNode
    let cubeNode: SCNNode
    let edgeNode: SCNNode
    let wireframeNode: SCNNode
    let glowNode: SCNNode
    let cameraNode: SCNNode

    private let cubeSize: CGFloat = 0.08

    init() {
        scene = SCNScene()
        scene.background.contents = UIColor.clear

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 0.5
        camera.zNear = 0.1
        camera.zFar = 100

        cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0.5, 0.5, 10)
        scene.rootNode.addChildNode(cameraNode)

        containerNode = SCNNode()
        containerNode.isHidden = true
        scene.rootNode.addChildNode(containerNode)

        // Layer 1: Faint translucent inner fill (hollow feel)
        let cubeGeo = SCNBox(
            width: cubeSize, height: cubeSize,
            length: cubeSize, chamferRadius: 0.004)

        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0, green: 0.03, blue: 0.10, alpha: 0.08)
        mat.emission.contents = UIColor(red: 0.03, green: 0.15, blue: 0.50, alpha: 1.0)
        mat.transparency = 0.96
        mat.isDoubleSided = true
        mat.lightingModel = .constant
        mat.blendMode = .add
        mat.shaderModifiers = [.surface: Self.hollowShader]

        cubeGeo.materials = [mat]
        cubeNode = SCNNode(geometry: cubeGeo)
        containerNode.addChildNode(cubeNode)

        let idleRotation = SCNAction.repeatForever(
            SCNAction.rotateBy(x: 0.4, y: 0.7, z: 0.25, duration: 6.0))
        cubeNode.runAction(idleRotation, forKey: "idle")

        let breathe = SCNAction.sequence([
            SCNAction.scale(to: 1.03, duration: 2.2),
            SCNAction.scale(to: 0.97, duration: 2.2),
        ])
        cubeNode.runAction(SCNAction.repeatForever(breathe), forKey: "breathe")

        // Layer 2: Bright edge wireframe at exact cube size (sharp corners)
        let edgeGeo = SCNBox(
            width: cubeSize, height: cubeSize,
            length: cubeSize, chamferRadius: 0.004)
        let edgeMat = SCNMaterial()
        edgeMat.diffuse.contents = UIColor(red: 0.55, green: 0.88, blue: 1.0, alpha: 0.80)
        edgeMat.emission.contents = UIColor(red: 0.45, green: 0.82, blue: 1.0, alpha: 0.95)
        edgeMat.lightingModel = .constant
        edgeMat.fillMode = .lines
        edgeMat.isDoubleSided = true
        edgeGeo.materials = [edgeMat]

        edgeNode = SCNNode(geometry: edgeGeo)
        cubeNode.addChildNode(edgeNode)

        // Layer 3: Outer wireframe (parallax depth cue)
        let wireSize = cubeSize * 1.25
        let wireGeo = SCNBox(
            width: wireSize, height: wireSize,
            length: wireSize, chamferRadius: 0)
        let wireMat = SCNMaterial()
        wireMat.diffuse.contents = UIColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 0.15)
        wireMat.emission.contents = UIColor(red: 0.18, green: 0.45, blue: 0.80, alpha: 0.28)
        wireMat.lightingModel = .constant
        wireMat.fillMode = .lines
        wireMat.isDoubleSided = true
        wireGeo.materials = [wireMat]

        wireframeNode = SCNNode(geometry: wireGeo)
        cubeNode.addChildNode(wireframeNode)

        let wireRotation = SCNAction.repeatForever(
            SCNAction.rotateBy(x: -0.15, y: 0.35, z: -0.10, duration: 7.5))
        wireframeNode.runAction(wireRotation, forKey: "wireIdle")

        // Layer 4: Glow aura / interaction ring (gray-blue patch)
        let glowGeo = SCNSphere(radius: cubeSize * 2.5)
        glowGeo.segmentCount = 32
        let glowMat = SCNMaterial()
        glowMat.diffuse.contents = UIColor(red: 0.14, green: 0.22, blue: 0.38, alpha: 0.04)
        glowMat.emission.contents = UIColor(red: 0.12, green: 0.26, blue: 0.50, alpha: 0.10)
        glowMat.lightingModel = .constant
        glowMat.isDoubleSided = true
        glowMat.blendMode = .add
        glowMat.writesToDepthBuffer = false
        glowGeo.materials = [glowMat]

        glowNode = SCNNode(geometry: glowGeo)
        containerNode.addChildNode(glowNode)

        let pulse = SCNAction.sequence([
            SCNAction.fadeOpacity(to: 0.5, duration: 2.0),
            SCNAction.fadeOpacity(to: 1.0, duration: 2.0),
        ])
        glowNode.runAction(SCNAction.repeatForever(pulse), forKey: "pulse")

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.3, alpha: 1)
        scene.rootNode.addChildNode(ambient)
    }

    func showCube(at position: SCNVector3, scale: Float = 1.0) {
        containerNode.isHidden = false
        containerNode.position = position
        containerNode.scale = SCNVector3(scale, scale, scale)
        containerNode.eulerAngles = SCNVector3Zero

        containerNode.opacity = 0
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        containerNode.opacity = 1
        SCNTransaction.commit()
    }

    func updatePosition(_ position: SCNVector3) {
        containerNode.position = position
    }

    func updateScale(_ scale: Float) {
        containerNode.scale = SCNVector3(scale, scale, scale)
    }

    func updateRotation(_ eulerAngles: SCNVector3) {
        containerNode.eulerAngles = eulerAngles
    }

    func hideCube() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        SCNTransaction.completionBlock = { [weak self] in
            self?.containerNode.isHidden = true
        }
        containerNode.opacity = 0
        SCNTransaction.commit()
    }

    // Hollow shader: nearly invisible center, subtly brighter near face edges
    private static let hollowShader = """
        float2 rawUV = _surface.diffuseTexcoord;
        float2 uv = rawUV * 4.0;
        float t = scn_frame.time;

        float n1 = sin(uv.x * 7.0 + t * 1.0) * cos(uv.y * 5.0 - t * 0.6);
        float n2 = sin(uv.x * 11.0 - t * 0.8) * cos(uv.y * 9.0 + t * 0.9);
        float n  = (n1 + n2) * 0.5 * 0.5 + 0.5;

        float edgeX = min(rawUV.x, 1.0 - rawUV.x);
        float edgeY = min(rawUV.y, 1.0 - rawUV.y);
        float edgeDist = min(edgeX, edgeY);
        float edge = 1.0 - smoothstep(0.0, 0.15, edgeDist);

        half3 deepBlue = half3(0.03h, 0.08h, 0.30h);
        half3 cyan     = half3(0.12h, 0.45h, 0.85h);
        half3 color = mix(deepBlue, cyan, half(n));

        float centerFade = 0.05 + 0.22 * edge;
        float pulse = 0.85 + 0.15 * sin(t * 1.3);
        float intensity = centerFade * pulse * (0.7 + 0.3 * n);

        _surface.emission = half4(color * half(intensity), 1.0h);
        """
}
