import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        ZStack {
            ARViewContainer(arView: controller.arView)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Picker("Modus", selection: $controller.mode) {
                    ForEach(AppMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if !controller.status.isEmpty {
                    Text(controller.status)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                Spacer()

                Group {
                    switch controller.mode {
                    case .play:
                        PlayControls()
                    case .scan:
                        ScanControls()
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

private struct ScanControls: View {
    @EnvironmentObject private var controller: ARController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sichtbare Punkte im Kasten: \(controller.pointsInBox)")
                .font(.caption.monospacedDigit())

            DimensionSlider(title: "Länge", value: $controller.boxLengthCM, range: 6...20)

            HStack {
                Text("Drehung")
                    .font(.caption)
                    .frame(width: 90, alignment: .leading)
                Slider(value: $controller.boxYawDegrees, in: -180...180)
            }

            HStack {
                Button("Scan speichern") {
                    controller.saveScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.boxPlaced)

                if let url = controller.lastScanURL {
                    ShareLink(item: url) {
                        Label("Exportieren", systemImage: "square.and.arrow.up")
                    }
                }

                Spacer()

                if controller.savedScanCount > 0 {
                    Button("Scans löschen (\(controller.savedScanCount))", role: .destructive) {
                        controller.deleteScans()
                    }
                    .font(.caption)
                }
            }
        }
    }
}

private struct DimensionSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text("\(title): \(value, specifier: "%.1f") cm")
                .font(.caption.monospacedDigit())
                .frame(width: 90, alignment: .leading)
            Slider(value: $value, in: range, step: 0.1)
        }
    }
}
