import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Text(controller.message ?? instruction)
                        .font(.callout)
                    if let note = controller.note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
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
            "Auto einlernen (einmalig), Schritt 1 von 3: Stell das Auto auf Boden oder Tisch, beweg das iPhone kurz hin und her und tippe dann aufs Auto."
        case .aligning:
            "Schritt 2 von 3: Ein Finger schiebt, zwei Finger drehen, Zusammenziehen ändert die Größe. Ungefähr reicht – beim Rundgang passt die App das Modell selbst genau an."
        case .scanning:
            "Schritt 3 von 3: Geh langsam um das Auto herum, 20–40 cm entfernt – einmal flach von der Seite und einmal schräg von oben."
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
                AlignControls()
            case .scanning, .saving:
                ProgressView(value: controller.lowAngleProgress) {
                    Text("Flach von der Seite: \(Int(controller.lowAngleProgress * 100)) %")
                        .font(.footnote)
                }
                ProgressView(value: controller.highAngleProgress) {
                    Text("Schräg von oben: \(Int(controller.highAngleProgress * 100)) %")
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

/// Feinjustieren beim Einlernen. Gedrückt halten wiederholt den Schritt.
private struct AlignControls: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                step("rotate.left", "Nach links drehen") { controller.rotateGhost(degrees: 1) }
                step("rotate.right", "Nach rechts drehen") { controller.rotateGhost(degrees: -1) }
                Button("Wenden") { controller.rotateGhost(degrees: 180) }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 10) {
                step("minus", "Kleiner") { controller.resizeGhost(percent: -1) }
                Text("Größe \(Int((controller.ghostScale * 100).rounded())) %")
                    .font(.footnote)
                    .monospacedDigit()
                    .frame(minWidth: 90)
                step("plus", "Größer") { controller.resizeGhost(percent: 1) }
            }
            HStack(spacing: 10) {
                step("arrow.left", "Nach links") { controller.nudgeGhost(forward: 0, right: -1) }
                step("arrow.up", "Weg von mir") { controller.nudgeGhost(forward: 1, right: 0) }
                step("arrow.down", "Zu mir hin") { controller.nudgeGhost(forward: -1, right: 0) }
                step("arrow.right", "Nach rechts") { controller.nudgeGhost(forward: 0, right: 1) }
            }
            HStack(spacing: 10) {
                Button("Neu antippen") { controller.placeAgain() }
                    .buttonStyle(.bordered)
                Button("Passt") { controller.confirmAlignment() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func step(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
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

            if controller.followsWithMotionTracker {
                Toggle("Echtzeit-Nachführen", isOn: $controller.fastFollow)
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
