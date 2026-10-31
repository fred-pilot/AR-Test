import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text(controller.message ?? instruction)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                Group {
                    if controller.isTeaching {
                        TeachControls()
                    } else {
                        PlayControls()
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding()
        }
        .onAppear {
            controller.start()
        }
    }

    private var instruction: String {
        switch controller.phase {
        case .placing:
            "Auto einlernen (einmalig), Schritt 1 von 3: Stell das Auto auf Boden oder Tisch und tippe es auf dem Bildschirm an."
        case .aligning:
            "Schritt 2 von 3: Schieb das Modell mit einem Finger und dreh es mit zwei Fingern, bis es genau auf dem Auto sitzt."
        case .scanning:
            "Schritt 3 von 3: Geh langsam einmal ganz um das Auto herum, etwa 30–50 cm entfernt und leicht von oben."
        case .saving:
            "Speichere das Auto …"
        case .searching:
            "Richte die Kamera auf das Auto."
        case .found:
            "Auto erkannt!"
        case .lost:
            "Auto aus dem Blick – richte die Kamera wieder darauf."
        }
    }
}

private struct TeachControls: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        VStack(spacing: 12) {
            switch controller.phase {
            case .aligning:
                Button("Passt") {
                    controller.confirmAlignment()
                }
                .buttonStyle(.borderedProminent)
            case .scanning, .saving:
                ProgressView(value: controller.scanProgress) {
                    Text("Rundgang: \(Int(controller.scanProgress * 100)) %")
                        .font(.footnote)
                }
                Button("Fertig") {
                    controller.finishScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.phase == .saving || controller.scanProgress < controller.minimumScanProgress)
            default:
                EmptyView()
            }

            if controller.phase != .placing {
                Button("Von vorn") {
                    controller.restart()
                }
                .font(.footnote)
            }
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

            HStack {
                Button("Auto neu suchen") {
                    controller.restart()
                }
                .buttonStyle(.borderedProminent)

                if controller.canRelearn {
                    Button("Neu einlernen") {
                        controller.relearn()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
