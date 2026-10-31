import simd

/// Passt das Modell beim Einlernen automatisch an das echte Auto an.
///
/// Beim Rundgang sammelt ARKit Merkmalspunkte auf der Oberfläche des echten Autos. Mit ICP
/// (Iterative Closest Point) wird das Modell so verschoben und um die Senkrechte gedreht, dass seine
/// Oberfläche möglichst genau durch diese Punkte geht. Die Hand-Ausrichtung muss dann nur noch
/// ungefähr stimmen.
enum AutoAligner {
    struct Result: Sendable {
        /// Lage des Modells in der Welt.
        let pose: simd_float4x4
        /// Mittlerer Abstand der passenden Punkte zur Modelloberfläche, in Metern.
        let error: Float
        let matchedPoints: Int
    }

    private static let iterations = 30
    /// Anteil der Punkte, die zählen. Der Rest gilt als Ausreißer (Hintergrund, Rauschen).
    private static let keepFraction: Float = 0.7

    /// - Parameters:
    ///   - model: Punkte auf der Modelloberfläche, im Koordinatensystem des Modells.
    ///   - pose: Ausgangslage des Modells in der Welt (die Hand-Ausrichtung).
    ///   - points: Merkmalspunkte des echten Autos in Weltkoordinaten.
    ///   - tryReversed: Prüft auch das um 180° gedrehte Modell (vorne und hinten vertauscht).
    static func fit(model: [SIMD3<Float>], pose: simd_float4x4, points: [SIMD3<Float>],
                    tryReversed: Bool) -> Result? {
        guard model.count >= 50, points.count >= 40 else { return nil }
        let model = thinned(model, to: 1200)
        let points = thinned(points, to: 1200)

        guard let straight = icp(model, start: pose, points) else { return nil }
        guard tryReversed else { return straight }
        let turned = pose * simd_float4x4(simd_quatf(angle: .pi, axis: [0, 1, 0]))
        // Nur umdrehen, wenn es eindeutig besser passt – die Hand-Ausrichtung hat Vorrang.
        if let reversed = icp(model, start: turned, points), reversed.error < straight.error * 0.7 {
            return reversed
        }
        return straight
    }

    private static func icp(_ model: [SIMD3<Float>], start: simd_float4x4, _ points: [SIMD3<Float>]) -> Result? {
        var pose = start
        var result: Result?
        for iteration in 0..<iterations {
            let world = model.map { (pose * SIMD4($0, 1)).xyz }

            // Zu jedem Merkmalspunkt der nächste Punkt auf dem Modell.
            var pairs: [(model: SIMD3<Float>, point: SIMD3<Float>, distance: Float)] = []
            pairs.reserveCapacity(points.count)
            for point in points {
                var best = Float.greatestFiniteMagnitude
                var nearest = world[0]
                for candidate in world {
                    let d = simd_distance_squared(candidate, point)
                    if d < best {
                        best = d
                        nearest = candidate
                    }
                }
                pairs.append((nearest, point, best.squareRoot()))
            }

            // Ausreißer weglassen. Anfangs großzügig (die Hand-Ausrichtung kann ein paar cm daneben
            // liegen), später strenger.
            let distances = pairs.map(\.distance).sorted()
            let limit = max(0.012, 0.03 - Float(iteration) * 0.002)
            let cutoff = min(distances[Int(Float(distances.count - 1) * keepFraction)], limit)
            let kept = pairs.filter { $0.distance <= cutoff }
            guard kept.count >= 30 else { return result }
            let error = kept.map(\.distance).reduce(0, +) / Float(kept.count)
            result = Result(pose: pose, error: error, matchedPoints: kept.count)

            // Drehung um die Senkrechte und Verschiebung in der Bodenebene, dazu die Höhe.
            guard let flat = RigidFit2D.leastSquares(from: kept.map { SIMD2($0.model.x, $0.model.z) },
                                                     to: kept.map { SIMD2($0.point.x, $0.point.z) })
            else { return result }
            let rise = kept.map { $0.point.y - $0.model.y }.reduce(0, +) / Float(kept.count)
            var step = flat.matrix
            step.columns.3.y = rise
            pose = step * pose

            if simd_length(flat.translation) < 0.0001, abs(flat.angle) < 0.0005, abs(rise) < 0.0001 { break }
        }
        return result
    }

    private static func thinned(_ points: [SIMD3<Float>], to count: Int) -> [SIMD3<Float>] {
        guard points.count > count else { return points }
        let step = Double(points.count) / Double(count)
        return (0..<count).map { points[Int(Double($0) * step)] }
    }
}
