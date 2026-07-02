import Foundation

/// The one way a color temperature is written in the UI ("3,700 K"), so the popup, the
/// schedule legend, and the display panes never disagree on grouping or spacing.
enum KelvinFormatting {
    static func label(for kelvin: Int) -> String {
        "\(kelvin.formatted(.number)) K"
    }
}
