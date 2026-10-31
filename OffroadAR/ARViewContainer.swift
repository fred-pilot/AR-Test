import RealityKit
import SwiftUI

/// Bettet die vom `ARController` verwaltete ARView in SwiftUI ein.
struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView {
        arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
