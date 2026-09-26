import SwiftUI
import UIKit
import XCTest
@testable import RustCleaner

/// Regression: score badge / Delete chrome / chips must not grow past a proposed width.
///
/// These use `UIHostingController.sizeThatFits` so a future layout tweak that lets
/// content expand past the screen fails CI immediately — without relying on
/// SwiftUI → UIKit accessibility-identifier bridging (which is flaky).
@MainActor
final class SwipeReviewLayoutTests: XCTestCase {
    /// Narrowest modern iPhone width we still support in practice.
    private let narrowWidth: CGFloat = 320
    /// Typical recent iPhone width.
    private let phoneWidth: CGFloat = 393

    func testScoreBadgeNeverExceedsProposedWidth() {
        let badge = ReviewScoreBadge(junk: 0.99, miss: 0.99, aesthetic: 0.99)
        for width in [narrowWidth - 32, narrowWidth, phoneWidth, 280, 200] as [CGFloat] {
            let fitted = sizeThatFits(badge, width: width, height: 80)
            XCTAssertLessThanOrEqual(
                fitted.width, width + 0.5,
                "Score badge grew to \(fitted.width) when proposed \(width)"
            )
        }
    }

    func testScoreBadgeInsideCardNeverWidensCard() {
        // Reproduces the screenshot bug: unconstrained score text widened the ZStack
        // past the screen and clipped "junk" on the left.
        let card = ZStack(alignment: .bottomLeading) {
            Color.gray
            ReviewScoreBadge(junk: 0, miss: 0.7, aesthetic: 0.73)
                .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .clipped()

        let contentWidth = narrowWidth - 32
        let fitted = sizeThatFits(card, width: contentWidth, height: 300)
        XCTAssertLessThanOrEqual(
            fitted.width, contentWidth + 0.5,
            "Card+badge grew to \(fitted.width) when proposed \(contentWidth)"
        )
    }

    func testBottomChromeNeverExceedsProposedWidth() {
        let chrome = ReviewBottomChrome(
            remaining: 99_999,
            stagedCount: 99_999,
            undoEnabled: true,
            deleteEnabled: true,
            onUndo: {},
            onDelete: {}
        )
        for width in [narrowWidth - 32, narrowWidth, phoneWidth, 280, 200] as [CGFloat] {
            let fitted = sizeThatFits(chrome, width: width, height: 60)
            XCTAssertLessThanOrEqual(
                fitted.width, width + 0.5,
                "Bottom chrome grew to \(fitted.width) when proposed \(width)"
            )
        }
    }

    func testFlowLayoutNeverExceedsProposedWidth() {
        let chips = FlowLayout(spacing: 8) {
            Text("Similar photos (12)")
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            Text(String(repeating: "Looks like: a very long automatic caption that must wrap. ", count: 3))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            Text("Near duplicate")
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
        for width in [narrowWidth - 32, narrowWidth, phoneWidth, 200] as [CGFloat] {
            let fitted = sizeThatFits(chips, width: width, height: 400)
            XCTAssertLessThanOrEqual(
                fitted.width, width + 0.5,
                "FlowLayout grew to \(fitted.width) when proposed \(width)"
            )
        }
    }

    func testSeededReviewScreenFitsNarrowPhoneWidth() {
        let model = AppModel()
        model.seedReviewLayoutFixture(remaining: 172, stagedCount: 0)

        let view = NavigationStack {
            SwipeReviewView()
                .environmentObject(model)
        }

        let fitted = sizeThatFits(view, width: narrowWidth, height: 700)
        XCTAssertLessThanOrEqual(
            fitted.width, narrowWidth + 0.5,
            "SwipeReviewView grew to \(fitted.width) on \(Int(narrowWidth))pt width"
        )
    }

    func testSeededReviewScreenFitsNarrowPhoneWithLargeDeleteCount() {
        let model = AppModel()
        model.seedReviewLayoutFixture(remaining: 9_999, stagedCount: 9_999)

        let view = NavigationStack {
            SwipeReviewView()
                .environmentObject(model)
        }

        let fitted = sizeThatFits(view, width: narrowWidth, height: 700)
        XCTAssertLessThanOrEqual(
            fitted.width, narrowWidth + 0.5,
            "SwipeReviewView grew to \(fitted.width) with large Delete count"
        )
    }

    // MARK: - Helpers

    private func sizeThatFits<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: height))
    }
}
