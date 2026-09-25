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
            Text("On-device AI finds utility junk, social misses, and the best shot in a burst. Nothing leaves your iPhone.")
                .foregroundStyle(.secondary)
        }
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
