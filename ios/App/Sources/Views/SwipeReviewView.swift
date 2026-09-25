import SwiftUI
import UIKit

/// Keep / Toss / Skip card stack with reason chips and undo.
struct SwipeReviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var offset: CGSize = .zero
    @State private var showCommit = false
    @State private var relatedPresentation: RelatedPhotoPresentation?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let card = model.currentCard {
                    cardView(card)
                        .offset(offset)
                        .rotationEffect(.degrees(Double(offset.width / 20)))
                        .gesture(drag)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(accessibilityLabel(for: card))
                        .accessibilityHint("Swipe right to keep, left to toss, up to skip")

                    reasonChips(card.reasons)

                    HStack(spacing: 24) {
                        actionButton("Toss", system: "xmark.circle.fill", color: .red) {
                            model.decide(.toss)
                            resetOffset()
                        }
                        actionButton("Skip", system: "questionmark.circle", color: .orange) {
                            model.decide(.skip)
                            resetOffset()
                        }
                        actionButton("Keep", system: "checkmark.circle.fill", color: .green) {
                            model.decide(.keep)
                            resetOffset()
                        }
                    }
                    .padding(.top, 8)

                    HStack {
                        Button("Undo") { model.decide(.undo) }
                        Spacer()
                        Text("\(model.reviewRemaining) left")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Delete \(model.stagedTossCount)…") {
                            showCommit = true
                        }
                        .disabled(model.stagedTossCount == 0)
                    }
                    .padding(.horizontal)
                } else {
                    ContentUnavailableView(
                        "You're all caught up",
                        systemImage: "checkmark.seal",
                        description: Text("Run a scan to find more candidates, or enjoy the free space.")
                    )
                }
            }
            .padding()
            .navigationTitle("Keep or Toss")
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
            .sheet(item: $relatedPresentation) { presentation in
                RelatedPhotoSheet(presentation: presentation)
                    .environmentObject(model)
            }
        }
    }

    private func cardView(_ card: AppModel.ReviewCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = model.cardImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                        .overlay(ProgressView())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "junk %.0f%% · miss %.0f%% · aesthetic %.0f%%",
                            card.junk * 100, card.miss * 100, card.aesthetic * 100))
                    .font(.caption2.monospaced())
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()

            swipeOverlay
        }
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
            .opacity(min(1, abs(offset.width + offset.height) / 120))
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

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.05))
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
                image = await model.loadRelatedImage(assetId: presentation.assetId)
            }
        }
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
