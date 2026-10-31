import RealityKit
import UIKit

/// Der Drahtkasten, den man im Scan-Modus um das Auto legt.
/// Ursprung = Mitte der Unterseite, -Z = vorne (rote Kanten).
@MainActor
final class ScanBox {
    /// Breite (x), Höhe (y), Länge (z) in Metern.
    var size: SIMD3<Float> = [0.06, 0.07, 0.12]
    var yaw: Float = 0

    private var anchor: AnchorEntity?
    private let box = Entity()

    var worldTransform: simd_float4x4? {
        anchor == nil ? nil : box.transformMatrix(relativeTo: nil)
    }

    func place(at position: SIMD3<Float>, in scene: RealityKit.Scene) {
        if anchor == nil {
            let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
            anchor.addChild(box)
            scene.addAnchor(anchor)
            self.anchor = anchor
        }
        box.position = position
    }

    func remove() {
        anchor?.removeFromParent()
        anchor = nil
    }

    func contains(_ worldPoint: SIMD3<Float>) -> Bool {
        guard anchor != nil else { return false }
        let p = box.convert(position: worldPoint, from: nil)
        return abs(p.x) <= size.x / 2 && p.y >= 0 && p.y <= size.y && abs(p.z) <= size.z / 2
    }

    func rebuild() {
        box.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        box.children.removeAll()

        let thickness: Float = 0.0015
        let (w, h, l) = (size.x, size.y, size.z)
        let white = UnlitMaterial(color: .white)
        let red = UnlitMaterial(color: .systemRed)

        func edge(_ dimensions: SIMD3<Float>, _ position: SIMD3<Float>, _ material: UnlitMaterial) {
            let entity = ModelEntity(mesh: .generateBox(size: dimensions), materials: [material])
            entity.position = position
            box.addChild(entity)
        }

        for x in [-w / 2, w / 2] {
            for z in [-l / 2, l / 2] {
                edge([thickness, h, thickness], [x, h / 2, z], z < 0 ? red : white)
            }
        }
        for y in [0, h] {
            for z in [-l / 2, l / 2] {
                edge([w, thickness, thickness], [0, y, z], z < 0 ? red : white)
            }
            for x in [-w / 2, w / 2] {
                edge([thickness, thickness, l], [x, y, 0], white)
            }
        }
    }
}
