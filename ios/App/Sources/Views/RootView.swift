import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "sparkles") }
                .tag(0)
            SwipeReviewView()
                .tabItem { Label("Review", systemImage: "rectangle.stack") }
                .tag(1)
            ScanView()
                .tabItem { Label("Scan", systemImage: "bolt.horizontal.circle") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    categoryPicker
                    startScanButton
                    stats
                    if model.reviewRemaining > 0 {
                        NavigationLink {
                            SwipeReviewView()
                        } label: {
                            Label("Review \(model.reviewRemaining) suggestions", systemImage: "hand.draw")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Start keep or toss review")
                    }
                    privacyCard
                }
                .padding()
            }
            .navigationTitle("Context Cleaner")
            .overlay {
                if model.isScanning {
                    ProgressView(model.scanProgress)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cull by intent, not pixels")
                .font(.title2.bold())
            Text("Choose what to look for, then start a scan. Nothing leaves your iPhone.")
                .foregroundStyle(.secondary)
        }
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find")
                .font(.headline)
            ForEach(ScanCategory.allCases) { category in
                CategoryToggleRow(
                    category: category,
                    isOn: model.scanCategories.isEnabled(category)
                ) {
                    model.toggleCategory(category)
                }
            }
        }
    }

    private var startScanButton: some View {
        Button {
            Task { await model.startScan() }
        } label: {
            Label("Start scan", systemImage: "bolt.horizontal.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isScanning || !model.scanCategories.hasAnyEnabled)
        .accessibilityLabel("Start on-device scan for selected categories")
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Photos indexed", value: "\(model.assetCount)")
            StatTile(title: "To review", value: "\(model.reviewRemaining)")
            StatTile(title: "Staged deletes", value: "\(model.stagedTossCount)")
            StatTile(title: "Thermal", value: model.thermalLabel)
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Privacy first", systemImage: "lock.shield")
                .font(.headline)
            Text("No analytics. No accounts. Deletes go to Recently Deleted for 30 days. The optional VLM download is the only network call, checksum-verified.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CategoryToggleRow: View {
    let category: ScanCategory
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(category.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .minimumScaleFactor(0.7)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
