import SwiftUI
import VLM

struct ScanView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Power", value: model.powerLabel)
                    LabeledContent("Thermal", value: model.thermalLabel)
                    LabeledContent("VLM ready", value: model.canRunVLM ? "Yes" : "No")
                }
                Section("Scanning") {
                    Button {
                        Task { await model.runCascade(maxAssets: 300) }
                    } label: {
                        Label("Quick scan (on-device)", systemImage: "hare")
                    }
                    .disabled(model.isScanning)

                    Button {
                        Task { await model.runForegroundChargingScan() }
                    } label: {
                        Label("Deep scan while charging", systemImage: "battery.100.bolt")
                    }
                    .disabled(model.isScanning)

                    if model.isScanning {
                        ProgressView(model.scanProgress)
                    }
                }
                Section {
                    Text("Heavy Vision / Core ML / VLM work prefers external power. Background processing is scheduled automatically when plugged in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Scan")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var downloading = false
    @State private var downloadProgress: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Privacy") {
                    LabeledContent("Analytics", value: "Off")
                    LabeledContent("Network", value: "VLM download only")
                    Link("Privacy policy", destination: URL(string: "https://github.com/gidi/rustioscleaner/blob/main/PRIVACY.md")!)
                }
                Section("Optional VLM (Tier 3)") {
                    LabeledContent("Installed", value: model.vlmInstalled ? "Yes" : "No")
                    Button {
                        Task { await downloadVLM() }
                    } label: {
                        if downloading {
                            ProgressView(value: downloadProgress)
                        } else {
                            Text("Download open-source VLM weights")
                        }
                    }
                    .disabled(downloading || model.vlmInstalled)
                    Text("Apache/MIT weights only. SHA256 verified. ~1–2 GB. Runs only while charging.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: "0.1.0")
                    Text("MIT licensed. Built with Rust + SwiftUI + Vision + Core ML + MLX.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func downloadVLM() async {
        guard let manifest = VLMModelManager.shared.manifest else {
            model.lastError = "No VLM manifest bundled. See models/MODELS.md."
            return
        }
        // Placeholder URL — real release pins a Hugging Face revision in vlm_manifest.json.
        guard let url = URL(string: "https://huggingface.co/\(manifest.repo)/resolve/\(manifest.revision)/\(manifest.filename)") else {
            return
        }
        downloading = true
        defer { downloading = false }
        do {
            try await VLMModelManager.shared.downloadIfNeeded(
                from: url,
                expectedSHA256: manifest.sha256
            ) { p in
                Task { @MainActor in downloadProgress = p }
            }
            model.vlmInstalled = true
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}
