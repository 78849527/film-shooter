import SwiftUI

/// iOS 16 equivalent of the iOS 17 onChange(oldValue:newValue:) API.
/// Keeping the last value in State preserves both arguments for existing UI.
private struct LegacyChangeObserver<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var previous: Value

    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                previous = value
                if initial { action(value, value) }
            }
            .onChange(of: value) { updated in
                let old = previous
                previous = updated
                action(old, updated)
            }
    }
}

extension View {
    func compatibleOnChange<Value: Equatable>(
        of value: Value, initial: Bool = false,
        _ action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(LegacyChangeObserver(value: value, initial: initial, action: action))
    }

    /// The newer navigation zoom transition is cosmetic. Keep it on iOS 18,
    /// retain standard full-screen presentation on iOS 16 and 17.
    @ViewBuilder
    func compatibleGalleryTransition(namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: "gallery", in: namespace))
        } else {
            self
        }
    }
}
