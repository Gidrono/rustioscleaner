import SwiftUI
import UIKit

/// Keep / Toss / Skip card stack with reason chips and undo.
struct SwipeReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var offset: CGSize = .zero
    @State private var showCommit = false
    @State private var relatedPresentation: RelatedPhotoPresentation?
    /// Avoid resetting session stats when PhotoKit’s system confirm re-triggers onAppear.
    @State private var didStartSession = false

    /// Space for Toss/Skip/Keep row + vertical padding (chips scroll in between).
    private static let actionRowReserve: CGFloat = 88
    private static let contentPadding: CGFloat = 16
    private static let minCardHeight: CGFloat = 220
    private static let maxCardHeight: CGFloat = 420

    var body: some View {
        GeometryReader { geo in
            let cardHeight = Self.cardHeight(for: geo.size.height)

            Group {
                if let card = model.currentCard {
                    VStack(spacing: 12) {
                        cardView(card, height: cardHeight)
                            .offset(offset)
                            .rotationEffect(.degrees(Double(offset.width / 20)))
                            .gesture(drag)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(accessibilityLabel(for: card))
                            .accessibilityHint("Swipe right to keep, left to toss, up to skip")

                        ScrollView {
                            reasonChips(card.reasons)
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        HStack(spacing: 24) {
                            actionButton("Toss", system: "xmark.circle.fill", color: .red) {
                                model.decide(.toss)
                                resetOffset()
                            }
                            .frame(maxWidth: .infinity)
                            actionButton("Skip", system: "questionmark.circle", color: .orange) {
                                model.decide(.skip)
                                resetOffset()
                            }
                            .frame(maxWidth: .infinity)
                            actionButton("Keep", system: "checkmark.circle.fill", color: .green) {
                                model.decide(.keep)
                                resetOffset()
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(model.isCommittingDeletes)
                    }
                    // Propose a finite width first so FlowLayout / badges never expand past the screen.
                    .frame(width: max(0, geo.size.width - Self.contentPadding * 2), alignment: .center)
                    .padding(Self.contentPadding)
                    .clipped()
                } else if model.stagedTossCount > 0 {
                    ContentUnavailableView(
                        "Ready to delete",
                        systemImage: "trash.circle",
                        description: Text("\(model.stagedTossCount) photo\(model.stagedTossCount == 1 ? "" : "s") staged. Confirm below to move them to Recently Deleted.")
                    )
                    .padding()
                } else if model.sessionDeletedCount > 0 {
                    ContentUnavailableView(
                        "You're all caught up",
                        systemImage: "checkmark.seal",
                        description: Text(sessionEmptyDescription)
                    )
                    .padding()
                } else {
                    ContentUnavailableView(
                        "You're all caught up",
                        systemImage: "checkmark.seal",
                        description: Text("Run a scan to find more candidates, or enjoy the free space.")
                    )
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .navigationTitle("Keep or Toss")
        .onAppear {
            guard !didStartSession else { return }
            didStartSession = true
            model.resetSessionCleanStats()
        }
        .confirmationDialog(
            "Move \(model.stagedTossCount) photos to Recently Deleted?",
            isPresented: $showCommit,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.commitDeletes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apple will ask you to confirm. Photos stay recoverable for 30 days.")
        }
        .sheet(item: Binding(
            get: { model.lastCleanResult },
            set: { if $0 == nil { model.dismissCleanResult() } }
        )) { result in
            CleanedSummarySheet(result: result) {
                model.dismissCleanResult()
            }
        }
        .sheet(item: $relatedPresentation) { presentation in
            RelatedPhotoSheet(presentation: presentation)
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private var bottomChrome: some View {
        if model.isCommittingDeletes {
            committingDoneBar
                .padding(.horizontal, Self.contentPadding)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if model.currentCard != nil || model.stagedTossCount > 0 {
            ReviewBottomChrome(
                remaining: Int(model.reviewRemaining),
                stagedCount: model.stagedTossCount,
                undoEnabled: model.currentCard != nil || model.stagedTossCount > 0,
                deleteEnabled: model.stagedTossCount > 0,
                onUndo: { model.decide(.undo) },
                onDelete: { showCommit = true }
            )
            .padding(.horizontal, Self.contentPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var committingDoneBar: some View {
        HStack {
            Spacer()
            DoneRingButton(title: "Done", isActive: true)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Deleting photos")
    }

    private static func cardHeight(for availableHeight: CGFloat) -> CGFloat {
        // Leave room for padding, a short chip strip, and the action row.
        let proposed = availableHeight - (contentPadding * 2) - actionRowReserve - 48
        return min(maxCardHeight, max(minCardHeight, proposed))
    }

    private var sessionEmptyDescription: String {
        let photos = "\(model.sessionDeletedCount) photo\(model.sessionDeletedCount == 1 ? "" : "s")"
        let space = Self.formatBytes(model.sessionFreedBytes)
        return "This visit you cleaned \(photos) · \(space). Run a scan for more candidates."
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func cardView(_ card: AppModel.ReviewCard, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = model.cardImage {
                    Color.black
                        .overlay {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        }
                } else if model.cardImageLoadFailed {
                    Color.gray.opacity(0.2)
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Couldn’t load photo")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                } else {
                    Color.gray.opacity(0.2)
                        .overlay(ProgressView())
                }
            }

            ReviewScoreBadge(junk: card.junk, miss: card.miss, aesthetic: card.aesthetic)
                .padding(12)

            swipeOverlay
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityIdentifier("review.card")
    }

    @ViewBuilder
    private var swipeOverlay: some View {
        if offset.width > 60 {
            stamp("KEEP", color: .green).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if offset.width < -60 {
            stamp("TOSS", color: .red).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        } else if offset.height < -60 {
            stamp("SKIP", color: .orange).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func stamp(_ text: String, color: Color) -> some View {
        stampLabel(text)
            .foregroundStyle(color)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .padding(24)
            .opacity(min(1.0, abs(offset.width + offset.height) / 120.0))
    }

    private func stampLabel(_ text: String) -> Text {
        Text(text).font(.title.bold())
    }

    private func reasonChips(_ reasons: [AppModel.ReasonChip]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(reasons) { reason in
                if let relatedId = reason.relatedAssetId {
                    Button {
                        relatedPresentation = RelatedPhotoPresentation(
                            assetId: relatedId,
                            title: sheetTitle(for: reason)
                        )
                    } label: {
                        chipLabel(reason.title, tappable: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the related photo")
                } else {
                    chipLabel(reason.title, tappable: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipLabel(_ title: String, tappable: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sheetTitle(for reason: AppModel.ReasonChip) -> String {
        switch reason.kind {
        case "Similar photos", "Better shot exists", "Near duplicate":
            return "Best shot"
        default:
            return reason.kind
        }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation }
            .onEnded { value in
                if value.translation.width > 120 {
                    model.decide(.keep)
                } else if value.translation.width < -120 {
                    model.decide(.toss)
                } else if value.translation.height < -120 {
                    model.decide(.skip)
                }
                resetOffset()
            }
    }

    private func resetOffset() {
        withAnimation(.spring(response: 0.3)) { offset = .zero }
    }

    private func actionButton(_ title: String, system: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack {
                Image(systemName: system)
                    .font(.largeTitle)
                    .foregroundStyle(color)
                Text(title).font(.caption)
            }
        }
        .accessibilityLabel(title)
    }

    private func accessibilityLabel(for card: AppModel.ReviewCard) -> String {
        let chips = card.reasons.map(\.title).joined(separator: ", ")
        return "Photo suggested for review. Reasons: \(chips)"
    }
}

// MARK: - Done ring (in-flight delete)

/// Prominent Done label with a continuous angular ring while work is in progress.
private struct DoneRingButton: View {
    let title: String
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
            let degrees = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.05) / 1.05 * 360

            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 3)
                    .frame(width: 88, height: 88)

                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.accentColor.opacity(0.15),
                                Color.accentColor,
                                Color.accentColor.opacity(0.15)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 88, height: 88)
                    .rotationEffect(.degrees(degrees))

                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// Post-delete celebration with count, space freed, and Done.
private struct CleanedSummarySheet: View {
    let result: AppModel.CleanResult
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)
                        Text("Nice clean")
                            .font(Font.title.bold())
                        Text(batchLine)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                        if showsSessionExtra {
                            Text(sessionLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Text("Photos stay in Recently Deleted for 30 days.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 32)
                    .padding(.bottom, 16)
                }

                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var batchLine: String {
        let photos = "\(result.deletedCount) photo\(result.deletedCount == 1 ? "" : "s")"
        return "\(photos) · \(Self.formatBytes(result.freedBytes))"
    }

    private var showsSessionExtra: Bool {
        result.sessionDeletedCount > result.deletedCount
    }

    private var sessionLine: String {
        let photos = "\(result.sessionDeletedCount) photo\(result.sessionDeletedCount == 1 ? "" : "s")"
        return "This session: \(photos) · \(Self.formatBytes(result.sessionFreedBytes))"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct RelatedPhotoPresentation: Identifiable {
    var id: String { assetId }
    let assetId: String
    let title: String
}

private struct RelatedPhotoSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let presentation: RelatedPhotoPresentation
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.05))
                } else if loadFailed {
                    ContentUnavailableView(
                        "Couldn’t load photo",
                        systemImage: "photo",
                        description: Text("This related photo may have been deleted or isn’t available on this device.")
                    )
                } else {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: presentation.assetId) {
                loadFailed = false
                image = nil
                let result = await model.loadRelatedImage(assetId: presentation.assetId) { preview in
                    Task { @MainActor in
                        image = preview
                        loadFailed = false
                    }
                }
                if image == nil {
                    if let result {
                        image = result
                    } else {
                        loadFailed = true
                    }
                }
            }
        }
    }
}

// MARK: - Layout-constrained chrome (kept internal for overflow regression tests)

/// Score overlay that must never widen the card past the proposed width.
struct ReviewScoreBadge: View {
    let junk: Float
    let miss: Float
    let aesthetic: Float

    var body: some View {
        Text(Self.label(junk: junk, miss: miss, aesthetic: aesthetic))
            .font(.caption2.monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            // Finite width proposal is required for minimumScaleFactor to engage.
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("review.scoreBadge")
    }

    static func label(junk: Float, miss: Float, aesthetic: Float) -> String {
        String(
            format: "junk %.0f%% · miss %.0f%% · aesthetic %.0f%%",
            junk * 100, miss * 100, aesthetic * 100
        )
    }
}

/// Undo / remaining / Delete row. Equal columns so Delete always has room for
/// counts through at least 1k (no trailing ellipsis — it looked like truncation).
struct ReviewBottomChrome: View {
    let remaining: Int
    let stagedCount: Int
    let undoEnabled: Bool
    let deleteEnabled: Bool
    let onUndo: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Undo", action: onUndo)
                .disabled(!undoEnabled)
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(remaining) left")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("review.remaining")

            Button(action: onDelete) {
                Text(deleteLabel)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .disabled(!deleteEnabled)
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("review.deleteButton")
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("review.bottomChrome")
    }

    /// Compact past 9,999 so a third-column still fits on narrow widths.
    private var deleteLabel: String {
        if stagedCount >= 10_000 {
            return "Delete \(stagedCount / 1_000)k"
        }
        return "Delete \(stagedCount)"
    }
}

/// Wrapping layout for reason chips; never reports width wider than the proposal.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        return rows.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(proposal: proposal, subviews: subviews)
        for (i, frame) in rows.frames.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxW = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var width: CGFloat = 0
        for sub in subviews {
            let proposed = maxW.isFinite
                ? ProposedViewSize(width: maxW, height: nil)
                : ProposedViewSize.unspecified
            var size = sub.sizeThatFits(proposed)
            if maxW.isFinite, size.width > maxW {
                size.width = maxW
            }
            if maxW.isFinite, x + size.width > maxW, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            // Full-width chips stack vertically for readability.
            if maxW.isFinite, size.width >= maxW * 0.9, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowH = max(rowH, size.height)
            x += size.width + spacing
            let rowEnd = x > 0 ? x - spacing : 0
            width = max(width, rowEnd)
        }
        let totalWidth: CGFloat
        if maxW.isFinite {
            totalWidth = min(max(width, 0), maxW)
        } else {
            totalWidth = width
        }
        return (CGSize(width: totalWidth, height: y + rowH), frames)
    }
}
