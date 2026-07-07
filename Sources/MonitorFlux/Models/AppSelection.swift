import Foundation

enum AppSelection: Hashable {
    case general
    case keyboard
    case color
    case display(String)
    case diagnostics
}
