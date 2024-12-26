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
    
    private var meshEntities = [UUID: ModelEntity]()
    var contentEntity = Entity()
    var latestHandTracking: HandsUpdates = .init(left: nil, right: nil)
    var leftHandEntity = Entity()
    var rightHandEntity = Entity()
    
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
                    glabGesture(handAnchor: latestHandTracking.left)
                } else if anchor.chirality == .right {
                    latestHandTracking.right = anchor
                    glabGesture(handAnchor: latestHandTracking.right)
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
        
        let material = PhysicsMaterialResource.generate(friction: 0.8,restitution: 0.0)
        ball.components.set(PhysicsBodyComponent(shapes: [ShapeResource.generateSphere(radius: 0.05)], mass: 1.0, material: material, mode: .dynamic))
        
        contentEntity.addChild(ball)
    }
    
    // 握るジェスチャーの検出
    func glabGesture(handAnchor: HandAnchor?) {
        guard let handAnchor = handAnchor else { return }
        
        guard let middleFingerTip = handAnchor.handSkeleton?.joint(.middleFingerTip).anchorFromJointTransform else { return }
        guard let thumbIntermediateTip = handAnchor.handSkeleton?.joint(.thumbIntermediateTip).anchorFromJointTransform else { return }
        
        let middleFingerTipToThumbIntermediateTipDistance = distance(middleFingerTip.columns.3.xyz, thumbIntermediateTip.columns.3.xyz)
        
        if middleFingerTipToThumbIntermediateTipDistance > 0.04 {
            return
        }
        
        // ボールエンティティの取得
        guard let ballEntity = contentEntity.children.first(where: { $0.name == "ball" }) as? ModelEntity else { return }
        
        let ballPosition = ballEntity.position
        let handPosition = handAnchor.originFromAnchorTransform.columns.3.xyz
        
        let distance = simd_distance(ballPosition, handPosition)
        if distance > 0.2 {
            return
        }
        
        ballEntity.addForce(calculateForceDirection(handAnchor: handAnchor) * 300, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {}
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
