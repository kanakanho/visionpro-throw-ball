import ARKit
import RealityKit
import SwiftUI

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        self[SIMD3(0, 1, 2)]
    }
}

@Observable
@MainActor
class ViewModel {
    let session = ARKitSession()
    let handTracking = HandTrackingProvider()
    let sceneReconstruction = SceneReconstructionProvider()
    let worldTracking = WorldTrackingProvider()
    
    private var meshEntities = [UUID: ModelEntity]()
    var contentEntity = Entity()
    var latestHandTracking: HandsUpdates = .init(left: nil, right: nil)
    var leftHandEntity = Entity()
    var rightHandEntity = Entity()
    
    var isGlab: Bool = false
    
    // ここで反発係数を決定している可能性あり
    let material = PhysicsMaterialResource.generate(friction: 0.8,restitution: 0.0)
    
    struct HandsUpdates {
        var left: HandAnchor?
        var right: HandAnchor?
    }
    
    var errorState = false
    
    func setupContentEntity() -> Entity {
        return contentEntity
    }
    
    var dataProvidersAreSupported: Bool {
        HandTrackingProvider.isSupported && SceneReconstructionProvider.isSupported
    }
    
    var isReadyToRun: Bool {
        handTracking.state == .initialized && sceneReconstruction.state == .initialized
    }
    
    func processReconstructionUpdates() async {
        for await update in sceneReconstruction.anchorUpdates {
            let meshAnchor = update.anchor
            
            guard let shape = try? await ShapeResource.generateStaticMesh(from: meshAnchor) else { continue }
            switch update.event {
            case .added:
                let entity = ModelEntity()
                entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
                entity.collision = CollisionComponent(shapes: [shape], isStatic: true)
                entity.components.set(InputTargetComponent())
                
                // mode が dynamic でないと物理演算が適用されない
                entity.physicsBody = PhysicsBodyComponent(mode: .dynamic)
                
                meshEntities[meshAnchor.id] = entity
                contentEntity.addChild(entity)
            case .updated:
                guard let entity = meshEntities[meshAnchor.id] else { continue }
                entity.transform = Transform(matrix: meshAnchor.originFromAnchorTransform)
                entity.collision?.shapes = [shape]
            case .removed:
                meshEntities[meshAnchor.id]?.removeFromParent()
                meshEntities.removeValue(forKey: meshAnchor.id)
            }
        }
    }
    
    func monitorSessionEvents() async {
        for await event in session.events {
            switch event {
            case .authorizationChanged(type: _, status: let status):
                print("Authorization changed to: \(status)")
                
                if status == .denied {
                    errorState = true
                }
            case .dataProviderStateChanged(dataProviders: let providers, newState: let state, error: let error):
                print("Data provider changed: \(providers), \(state)")
                if let error {
                    print("Data provider reached an error state: \(error)")
                    errorState = true
                }
            @unknown default:
                fatalError("Unhandled new event type \(event)")
            }
        }
    }
    
    func processHandUpdates() async {
        for await update in handTracking.anchorUpdates {
            switch update.event {
            case .updated:
                let anchor = update.anchor
                
                guard anchor.isTracked else { continue }
                
                if anchor.chirality == .left {
                    latestHandTracking.left = anchor
//                    guard let handAnchor = latestHandTracking.left else { continue }
//                    glabGesture(handAnchor: handAnchor)
                } else if anchor.chirality == .right {
                    latestHandTracking.right = anchor
                    guard let handAnchor = latestHandTracking.right else { continue }
                    glabGesture(handAnchor: handAnchor)
                }
            default:
                break
            }
        }
    }
    
    // ボールの初期化
    func initBall() {
        guard let originTransform = latestHandTracking.right?.originFromAnchorTransform else { return }
        guard let handSkeletonAnchorTransform =  latestHandTracking.right?.handSkeleton?.joint(.indexFingerTip).anchorFromJointTransform else { return }
        
        let originFromIndex = originTransform * handSkeletonAnchorTransform
        let place = originFromIndex.columns.3.xyz
        
        let ball = ModelEntity(
            mesh: .generateSphere(radius: 0.05),
            materials: [SimpleMaterial(color: .white, isMetallic: true)],
            collisionShape: .generateSphere(radius: 0.05),
            mass: 1.0
        )
        
        ball.name = "ball"
        ball.setPosition(place, relativeTo: nil)
        ball.components.set(InputTargetComponent(allowedInputTypes: .all))

        // mode が dynamic でないと物理演算が適用されない
        ball.components.set(PhysicsBodyComponent(shapes: [ShapeResource.generateSphere(radius: 0.05)], mass: 1.0, material: material, mode: .dynamic))
        
        contentEntity.addChild(ball)
    }
    
    // 握るジェスチャーの検出
    func glabGesture(handAnchor: HandAnchor) {
        guard let wrist = handAnchor.handSkeleton?.joint(.wrist).anchorFromJointTransform else { return }
        guard let thumbIntermediateTip = handAnchor.handSkeleton?.joint(.thumbIntermediateTip).anchorFromJointTransform else { return }
        guard let indexFingerTip = handAnchor.handSkeleton?.joint(.indexFingerTip).anchorFromJointTransform else { return }
        guard let middleFingerTip = handAnchor.handSkeleton?.joint(.middleFingerTip).anchorFromJointTransform else { return }
        guard let ringFingerTip = handAnchor.handSkeleton?.joint(.ringFingerTip).anchorFromJointTransform else { return }
        guard let littleFingerTip = handAnchor.handSkeleton?.joint(.littleFingerTip).anchorFromJointTransform else { return }
        
        let thumbIntermediateTipToWristDistance = simd_length_squared(wrist.columns.3.xyz - thumbIntermediateTip.columns.3.xyz)
        let indexFingerTipToWristDistance = simd_length_squared(wrist.columns.3.xyz - indexFingerTip.columns.3.xyz)
        let middleFingerTipToWristDistance = simd_length_squared(wrist.columns.3.xyz - middleFingerTip.columns.3.xyz)
        let ringFingerTipToWristDistance = simd_length_squared(wrist.columns.3.xyz - ringFingerTip.columns.3.xyz)
        let littleFingerTipToWristDistance = simd_length_squared(wrist.columns.3.xyz - littleFingerTip.columns.3.xyz)
        
        // ボールエンティティの取得
        guard let ballEntity = contentEntity.children.first(where: { $0.name == "ball" }) as? ModelEntity else { return }
        
        // ボールとの距離を計算
        let ballPositionTransformMatrix = contentEntity.transform.matrix * ballEntity.transform.matrix
        let handPositionTransformMatrix = handAnchor.originFromAnchorTransform * indexFingerTip
        let ballHandLength = simd_length_squared(ballPositionTransformMatrix.columns.3.xyz - handPositionTransformMatrix.columns.3.xyz)
        
        // ボールとの距離で判定
        if  ballHandLength > 0.20 {
            isGlab = false
            return
        }
        
        // 手の形を判定
        if thumbIntermediateTipToWristDistance > 0.01
            && indexFingerTipToWristDistance > 0.01
            && middleFingerTipToWristDistance > 0.01
            && ringFingerTipToWristDistance > 0.01
            && littleFingerTipToWristDistance > 0.01 {
            print(Date().timeIntervalSince1970,"\tにぎらない")
            // 物理演算を再開
            ballEntity.components.set((PhysicsBodyComponent(shapes: [ShapeResource.generateSphere(radius: 0.05)], mass: 1.0, material: material, mode: .dynamic)))
            isGlab = false
            return
        }
        
        print(Date().timeIntervalSince1970,"\tにぎる")
        
        // 握っている間は物理演算を解除
        ballEntity.components.set((PhysicsBodyComponent(shapes: [ShapeResource.generateSphere(radius: 0.05)], mass: 1.0, material: material, mode: .static)))
        
        ballEntity.transform = Transform(
            matrix: matrix_multiply(handAnchor.originFromAnchorTransform, (handAnchor.handSkeleton?.joint(.indexFingerTip).anchorFromJointTransform)!)
        )
        
        isGlab = true
        
        // 手の向きに力を加える
        ballEntity.addForce(calculateForceDirection(handAnchor: handAnchor) * 4, relativeTo: nil)
    }
    
    func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        return simd_length(a - b)
    }
    
    // 手の向きに基づいて力を加える方向を計算
    func calculateForceDirection(handAnchor: HandAnchor) -> SIMD3<Float> {
        let handRotation = Transform(matrix: handAnchor.originFromAnchorTransform).rotation
        return handRotation.act(handAnchor.chirality == .left ? SIMD3(1, 0, 0) : SIMD3(-1, 0, 0))
    }
}
