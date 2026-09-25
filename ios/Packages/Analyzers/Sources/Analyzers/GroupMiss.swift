import Foundation

/// Within a burst / near-dup group, a photo is a "miss" if it has face failures
/// while at least one sibling does not.
public enum GroupMiss {
    public struct FaceSummary: Sendable {
        public let assetId: String
        public let anyBlink: Bool
        public let anyLookingAway: Bool
        public let anyMouthOpen: Bool
        public let experimentalMouth: Bool

        public init(
            assetId: String,
            anyBlink: Bool,
            anyLookingAway: Bool,
            anyMouthOpen: Bool,
            experimentalMouth: Bool = false
        ) {
            self.assetId = assetId
            self.anyBlink = anyBlink
            self.anyLookingAway = anyLookingAway
            self.anyMouthOpen = anyMouthOpen
            self.experimentalMouth = experimentalMouth
        }

        public var isMiss: Bool {
            anyBlink || anyLookingAway || (experimentalMouth && anyMouthOpen)
        }
    }

    /// Returns asset ids that should be reviewed as social misses given their group.
    public static func missIds(in group: [FaceSummary]) -> [String] {
        guard group.count >= 2 else {
            return group.filter(\.isMiss).map(\.assetId)
        }
        let anyClean = group.contains { !$0.isMiss }
        guard anyClean else { return [] } // all bad — let aesthetic ranking decide
        return group.filter(\.isMiss).map(\.assetId)
    }
}
