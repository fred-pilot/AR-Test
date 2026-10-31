import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                if !controller.status.isEmpty {
                    Text(controller.status)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                Spacer()

                PlayControls()
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding()
        }
        .onAppear {
            controller.start()
        }
    }
}

private struct PlayControls: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Reifen", isOn: $controller.wheelsOn)
                Toggle("Wischer", isOn: $controller.wipersOn)
                Toggle("Licht", isOn: $controller.lightsOn)
            }
            .toggleStyle(.button)

            if controller.supportsLiDAR {
                Toggle("Verdeckung durch Umgebung (LiDAR)", isOn: $controller.environmentOcclusion)
                    .font(.footnote)
            }

            Button("Auto neu suchen") {
                controller.restart()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
