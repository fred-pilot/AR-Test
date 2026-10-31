import Foundation
import RealityKit

extension MeshResource {
    /// Zylinder entlang der y-Achse, mittig im Ursprung.
    /// Eigene Umsetzung, weil `generateCylinder` erst ab iOS 18 existiert und die App mit Xcode 15 (iOS 17) baubar sein soll.
    static func cylinder(height: Float, radius: Float, segments: Int = 24) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let half = height / 2

        func direction(_ i: Int) -> SIMD3<Float> {
            let angle = Float(i) / Float(segments) * 2 * .pi
            return SIMD3(cos(angle), 0, sin(angle))
        }

        // Mantel: je Segment ein Paar (unten, oben)
        for i in 0...segments {
            let d = direction(i)
            positions += [SIMD3(d.x * radius, -half, d.z * radius), SIMD3(d.x * radius, half, d.z * radius)]
            normals += [d, d]
        }
        for i in 0..<segments {
            let b = UInt32(i * 2)
            indices += [b, b + 1, b + 2, b + 1, b + 3, b + 2]
        }

        // Deckel oben und unten
        for (y, normalY) in [(half, Float(1)), (-half, Float(-1))] {
            let center = UInt32(positions.count)
            positions.append(SIMD3(0, y, 0))
            normals.append(SIMD3(0, normalY, 0))
            for i in 0...segments {
                let d = direction(i)
                positions.append(SIMD3(d.x * radius, y, d.z * radius))
                normals.append(SIMD3(0, normalY, 0))
            }
            for i in 0..<segments {
                let a = center + 1 + UInt32(i)
                indices += normalY > 0 ? [center, a + 1, a] : [center, a, a + 1]
            }
        }

        var descriptor = MeshDescriptor(name: "cylinder")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        // Kann bei gültigen Daten nicht fehlschlagen; im Notfall ein Würfel statt Absturz.
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: [radius * 2, height, radius * 2])
    }
}
