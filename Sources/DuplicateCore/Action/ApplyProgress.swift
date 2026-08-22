import Foundation

/// What an apply is doing right now.
///
/// **A progress bar that only counts items lies about a folder apply.** Verifying one folder pair digests every
/// file in both folders before anything moves -- measured on this user's trees, 10,506 files in one and 15,242 in
/// another -- so the bar sits on item 1 of 8 for minutes while the only thing on screen says the apply is moving
/// files. A frozen bar with no text is indistinguishable from a hang, and the user's remedy for a hang is to
/// force-quit an app that is halfway through moving their photographs.
///
/// So the stage is reported alongside the count, and it is a value rather than a sentence: `DuplicateCore`
/// never produces prose, and "verificando" and "verifying" are the same state.
public enum ApplyStage: Sendable, Equatable {
    /// Re-checking the claim the decision was made on, before anything is touched.
    ///
    /// `filesChecked` is how many files have been digested for the current item. It is zero for an exact or
    /// perceptual item, where verification is one or two files and finishes in milliseconds; it climbs for a
    /// folder, where it is the only honest thing to show.
    case verifying(filesChecked: Int)
    /// Sending the item to the Trash, or to quarantine when the Trash refuses.
    case moving
    /// The item is finished: moved, refused, or failed.
    ///
    /// **A separate case because otherwise the report is ambiguous.** With only two stages, a `.moving` report
    /// carrying `itemsDone: 1` means both "item 1 is done" and "item 2 has started moving", and a caller cannot
    /// tell which -- the first version of this had a test asserting `[1, 2, 3, 4, 5]` and getting
    /// `[1, 1, 2, 2, 3, 3, 4, 4, 5]`. The bar advances on this; the label keeps whatever it last said.
    case done
}

/// How far an apply has got, and what it is doing.
public struct ApplyProgress: Sendable, Equatable {
    /// Items fully dealt with -- moved, refused or failed.
    public var itemsDone: Int
    public var itemCount: Int
    /// The item being worked on, so a caller can name it rather than show a bare fraction.
    public var path: String
    public var stage: ApplyStage

    public init(itemsDone: Int, itemCount: Int, path: String, stage: ApplyStage) {
        self.itemsDone = itemsDone
        self.itemCount = itemCount
        self.path = path
        self.stage = stage
    }

    /// How many files to digest between reports.
    ///
    /// The same rule the scan path uses for sampling the current path: nobody reads more than ten updates a
    /// second, and a callback per file over 15,242 files is 15,242 atomic writes to say something no eye can
    /// follow.
    public static let fileReportInterval = 64
}
