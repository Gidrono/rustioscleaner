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
                Section {
                    ForEach(ScanCategory.allCases) { category in
                        Button {
                            model.toggleCategory(category)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: model.scanCategories.isEnabled(category)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.scanCategories.isEnabled(category)
                                                     ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.title)
                                        .foregroundStyle(.primary)
                                    Text(category.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .accessibilityLabel(category.title)
                        .accessibilityValue(model.scanCategories.isEnabled(category) ? "Selected" : "Not selected")
                    }
                } header: {
                    Text("Find")
                } footer: {
                    Text("Mark what you want to cull, then start a scan. You can change this anytime — the review list updates immediately.")
                }
                Section("Scanning") {
                    Button {
                        Task { await model.startScan(maxAssets: 300) }
                    } label: {
                        Label("Quick scan (on-device)", systemImage: "hare")
                    }
                    .disabled(model.isScanning || !model.scanCategories.hasAnyEnabled)

                    Button {
                        Task { await model.runForegroundChargingScan() }
                    } label: {
                        Label("Deep scan while charging", systemImage: "battery.100.bolt")
                    }
                    .disabled(model.isScanning || !model.scanCategories.hasAnyEnabled)

                    if model.isScanning {
                        ProgressView(model.scanProgress)
                    }
                }
                Section {
                    Text("Heavy Vision / Core ML / VLM work prefers external power. Background processing is scheduled after you start a scan, when plugged in.")
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
                Section {
                    Toggle("Google Photos", isOn: $model.backsUpGooglePhotos)
                    Toggle("Another backup (computer / NAS)", isOn: $model.backsUpOther)
                } header: {
                    Text("Secondary backup")
                } footer: {
                    Text("Apple doesn’t expose per-photo Google or iCloud backup status. If you also back up elsewhere, we’ll note that on review cards and be slightly more willing to queue soft junk (applies on the next scan). Deleting still removes the photo from your Photos library (and iCloud Photos if that’s your library). Recently Deleted keeps a copy for ~30 days.")
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
