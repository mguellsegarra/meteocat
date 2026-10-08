import SwiftUI

/// The scrubber's arrow-key route. Only an unmodified press steps, so VoiceOver (⌃⌥ arrows), ⌘, ⌥ and ⇧ presses are
/// left to whoever owns them; a handled press steps exactly once.
enum ScrubberKeys {
    static let blocking: EventModifiers = [.command, .option, .control, .shift]

    static func handle(_ modifiers: EventModifiers, delta: Int, step: (Int) -> Void) -> KeyPress.Result {
        guard modifiers.intersection(blocking).isEmpty else { return .ignored }
        step(delta)
        return .handled
    }
}
