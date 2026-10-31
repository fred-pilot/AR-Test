import ARKit
import CoreImage
import RealityKit
import Vision

/// Führt die Lage des Autos zwischen zwei ARKit-Erkennungen in Echtzeit nach.
///
/// Punkte auf der Oberfläche des Modells werden ins vorige Kamerabild projiziert. Der optische Fluss
/// (Vision) zeigt, wohin sich diese Bildpunkte bis zum aktuellen Bild bewegt haben. Weil das Auto auf
/// dem Boden fährt, behält jeder Punkt seine Höhe: Zurückprojiziert auf seine Höhenebene ergibt das
/// die neue Lage des Punkts in der Welt. Aus allen Punkten zusammen wird robust (RANSAC) die
/// Verschiebung und Drehung des Autos auf dem Boden bestimmt. Die Bewegung der Kamera selbst ist
/// darin schon herausgerechnet, weil ARKit für jedes Bild die Kameralage kennt.
final class MotionTracker: @unchecked Sendable {
    struct Sample {
        /// Position im Koordinatensystem des Autos, in Metern.
        let position: SIMD3<Float>
        /// Nach außen zeigende Flächennormale, um verdeckte Punkte auszusortieren.
        let normal: SIMD3<Float>?
    }

    struct Frame: @unchecked Sendable {
        let image: CVPixelBuffer
        let camera: ARCamera
        let time: TimeInterval
    }

    enum Outcome: Sendable {
        /// Das Auto hat sich bewegt: neue Lage = `delta` * alte Lage (in Weltkoordinaten).
        case moved(simd_float4x4)
        /// Keine Bewegung über dem Messrauschen.
        case still
        /// Auto nicht im Bild oder Bewegung nicht sicher bestimmbar.
        case lost
    }

    private let samples: [Sample]
    private let queue = DispatchQueue(label: "MotionTracker", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// Längste Seite des Bildausschnitts, auf dem der Fluss berechnet wird.
    private let workingSize: CGFloat = 320
    /// Ein Punkt passt zur geschätzten Bewegung, wenn er höchstens so weit danebenliegt.
    private let inlierDistance: Float = 0.003
    /// Kleinere Bewegungen gelten als Rauschen.
    private let minimumShift: Float = 0.0004
    private let minimumTurn: Float = 0.25 * .pi / 180

    init(samples: [Sample]) {
        self.samples = samples
    }

    /// Bestimmt die Bewegung des Autos von `keyframe` bis `current`. `pose` ist die Lage zur Zeit des `keyframe`.
    func track(from keyframe: Frame, to current: Frame, pose: simd_float4x4,
               completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async {
            completion(self.step(from: keyframe, to: current, pose: pose))
        }
    }

    private func step(from keyframe: Frame, to current: Frame, pose: simd_float4x4) -> Outcome {
        let before = Pinhole(keyframe.camera)
        let after = Pinhole(current.camera)
        let width = Float(CVPixelBufferGetWidth(keyframe.image))
        let height = Float(CVPixelBufferGetHeight(keyframe.image))

        // 1. Sichtbare Punkte des Autos im vorigen Bild.
        var points: [(world: SIMD3<Float>, pixel: SIMD2<Float>)] = []
        for sample in samples {
            let world = (pose * SIMD4(sample.position, 1)).xyz
            if let normal = sample.normal {
                let worldNormal = (pose * SIMD4(normal, 0)).xyz
                if simd_dot(worldNormal, before.position - world) <= 0 { continue }
            }
            guard let pixel = before.project(world),
                  pixel.x >= 0, pixel.y >= 0, pixel.x < width, pixel.y < height else { continue }
            points.append((world, pixel))
        }
        guard points.count >= 12 else { return .lost }

        // 2. Bildausschnitt ums Auto, mit Rand für die Bewegung bis zum aktuellen Bild.
        var low = points[0].pixel, high = points[0].pixel
        for point in points {
            low = simd_min(low, point.pixel)
            high = simd_max(high, point.pixel)
        }
        let margin = max(high.x - low.x, high.y - low.y) * 0.4 + 16
        let crop = CGRect(x: CGFloat(low.x - margin), y: CGFloat(low.y - margin),
                          width: CGFloat(high.x - low.x + 2 * margin), height: CGFloat(high.y - low.y + 2 * margin))
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            .integral
        guard crop.width >= 32, crop.height >= 32 else { return .lost }
        let scale = min(1, workingSize / max(crop.width, crop.height))
        let outWidth = Int(crop.width * scale), outHeight = Int(crop.height * scale)

        guard let previous = render(keyframe.image, crop: crop, scale: scale, width: outWidth, height: outHeight),
              let next = render(current.image, crop: crop, scale: scale, width: outWidth, height: outHeight)
        else { return .lost }

        // 3. Optischer Fluss: für jeden Bildpunkt des vorigen Bilds, wohin er im aktuellen Bild gewandert ist.
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: previous, options: [:])
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: next, options: [:])
        guard (try? handler.perform([request])) != nil,
              let flow = request.results?.first?.pixelBuffer,
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float
        else { return .lost }

        // 4. Neue Lage jedes Punkts auf seiner Höhenebene.
        var from: [SIMD2<Float>] = [], to: [SIMD2<Float>] = []
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { return .lost }
        let flowWidth = CVPixelBufferGetWidth(flow), flowHeight = CVPixelBufferGetHeight(flow)
        let rowBytes = CVPixelBufferGetBytesPerRow(flow)
        let toFlowX = Float(flowWidth) / Float(outWidth), toFlowY = Float(flowHeight) / Float(outHeight)
        let origin = SIMD2(Float(crop.minX), Float(crop.minY))
        let s = Float(scale)

        for point in points {
            let local = (point.pixel - origin) * s
            let x = Int(local.x * toFlowX), y = Int(local.y * toFlowY)
            guard x >= 0, y >= 0, x < flowWidth, y < flowHeight else { continue }
            let vector = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self).advanced(by: 2 * x)
            let shift = SIMD2(vector[0] / toFlowX, vector[1] / toFlowY) / s
            guard let moved = after.unproject(point.pixel + shift, planeY: point.world.y) else { continue }
            from.append(SIMD2(point.world.x, point.world.z))
            to.append(SIMD2(moved.x, moved.z))
        }

        // 5. Verschiebung und Drehung auf dem Boden, Ausreißer (z. B. die schiebende Hand) fallen raus.
        guard let fit = RigidFit2D.robust(from: from, to: to, inlierDistance: inlierDistance),
              fit.inliers >= max(10, from.count * 35 / 100) else { return .lost }
        let shift = simd_length(fit.translation), turn = abs(fit.angle)
        guard shift < 0.06, turn < 0.5 else { return .lost }
        guard shift > minimumShift || turn > minimumTurn else { return .still }
        return .moved(fit.matrix)
    }

    private func render(_ buffer: CVPixelBuffer, crop: CGRect, scale: CGFloat, width: Int, height: Int) -> CVPixelBuffer? {
        // Core Image zählt y von unten, die Pixel des Kamerabilds von oben.
        let fullHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let rect = CGRect(x: crop.minX, y: fullHeight - crop.maxY, width: crop.width, height: crop.height)
        let image = CIImage(cvPixelBuffer: buffer)
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &output)
        guard let output else { return nil }
        context.render(image, to: output)
        return output
    }

    // MARK: - Punkte auf dem Modell

    /// Punkte auf der Oberfläche des Modells, im Koordinatensystem von `reference` (in Metern).
    @MainActor
    static func samples(of root: Entity, relativeTo reference: Entity, maxCount: Int = 600) -> [Sample] {
        var all: [Sample] = []
        func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                let toReference = entity.transformMatrix(relativeTo: reference)
                let contents = model.mesh.contents
                for instance in contents.instances {
                    guard let mesh = contents.models[instance.model] else { continue }
                    let transform = toReference * instance.transform
                    for part in mesh.parts {
                        let normals = part.normals?.elements
                        for (index, position) in part.positions.elements.enumerated() {
                            var normal: SIMD3<Float>?
                            if let normals, index < normals.count {
                                normal = simd_normalize((transform * SIMD4(normals[index], 0)).xyz)
                            }
                            all.append(Sample(position: (transform * SIMD4(position, 1)).xyz, normal: normal))
                        }
                    }
                }
            }
            entity.children.forEach(visit)
        }
        visit(root)
        guard all.count > maxCount else { return all }
        let step = Double(all.count) / Double(maxCount)
        return (0..<maxCount).map { all[Int(Double($0) * step)] }
    }
}

/// Lochkamera-Modell eines ARKit-Kamerabilds (Pixel im Querformat, Ursprung oben links).
private struct Pinhole {
    let fx, fy, cx, cy: Float
    let transform: simd_float4x4
    let inverse: simd_float4x4

    init(_ camera: ARCamera) {
        let k = camera.intrinsics
        fx = k[0][0]
        fy = k[1][1]
        cx = k[2][0]
        cy = k[2][1]
        transform = camera.transform
        inverse = camera.transform.inverse
    }

    var position: SIMD3<Float> { transform.columns.3.xyz }

    /// ARKit-Kamera: x nach rechts, y nach oben, Blick entlang -z.
    func project(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        let c = inverse * SIMD4(world, 1)
        guard c.z < -0.01 else { return nil }
        return SIMD2(fx * c.x / -c.z + cx, fy * c.y / c.z + cy)
    }

    /// Schnittpunkt des Sehstrahls durch `pixel` mit der waagerechten Ebene in Höhe `planeY`.
    func unproject(_ pixel: SIMD2<Float>, planeY: Float) -> SIMD3<Float>? {
        let ray = (transform * SIMD4((pixel.x - cx) / fx, -(pixel.y - cy) / fy, -1, 0)).xyz
        guard abs(ray.y) > 1e-4 else { return nil }
        let t = (planeY - position.y) / ray.y
        guard t > 0 else { return nil }
        return position + ray * t
    }
}

/// Starre Bewegung in der Bodenebene (x, z): Drehung um die Senkrechte plus Verschiebung.
struct RigidFit2D {
    var angle: Float
    var translation: SIMD2<Float>
    var inliers = 0

    func apply(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let c = cos(angle), s = sin(angle)
        return SIMD2(c * p.x - s * p.y, s * p.x + c * p.y) + translation
    }

    /// Als 4×4-Matrix in Weltkoordinaten (x' = c·x − s·z, z' = s·x + c·z).
    var matrix: simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(c, 0, s, 0), SIMD4(0, 1, 0, 0), SIMD4(-s, 0, c, 0),
                                       SIMD4(translation.x, 0, translation.y, 1)))
    }

    static func leastSquares(from a: [SIMD2<Float>], to b: [SIMD2<Float>]) -> RigidFit2D? {
        guard a.count >= 2 else { return nil }
        let n = Float(a.count)
        let ca = a.reduce(.zero, +) / n, cb = b.reduce(.zero, +) / n
        var dot: Float = 0, cross: Float = 0
        for (p, q) in zip(a, b) {
            let u = p - ca, v = q - cb
            dot += u.x * v.x + u.y * v.y
            cross += u.x * v.y - u.y * v.x
        }
        var fit = RigidFit2D(angle: atan2(cross, dot), translation: .zero)
        fit.translation = cb - fit.apply(ca)
        return fit
    }

    static func robust(from a: [SIMD2<Float>], to b: [SIMD2<Float>], inlierDistance: Float) -> RigidFit2D? {
        guard a.count >= 2 else { return nil }
        var best: [Int] = []
        for _ in 0..<64 {
            let i = Int.random(in: 0..<a.count), j = Int.random(in: 0..<a.count)
            let da = a[j] - a[i], db = b[j] - b[i]
            guard i != j, simd_length(da) > 0.01 else { continue }
            var candidate = RigidFit2D(angle: atan2(db.y, db.x) - atan2(da.y, da.x), translation: .zero)
            candidate.translation = b[i] - candidate.apply(a[i])
            let inliers = a.indices.filter { simd_distance(candidate.apply(a[$0]), b[$0]) < inlierDistance }
            if inliers.count > best.count { best = inliers }
        }
        guard best.count >= 2, var fit = leastSquares(from: best.map { a[$0] }, to: best.map { b[$0] }) else { return nil }
        fit.inliers = a.indices.filter { simd_distance(fit.apply(a[$0]), b[$0]) < inlierDistance }.count
        return fit
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
