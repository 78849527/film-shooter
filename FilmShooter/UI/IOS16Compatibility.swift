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


extension View {
    /// iOS 18 matched-geometry navigation degrades to a normal transition.
    @ViewBuilder
    func compatibleMatchedTransitionSource<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleNumericText(_ value: Double) -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.numericText(value: value))
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleSymbolReplacement() -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleSymbolBounce(value: Bool) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleSymbolPulse(isActive: Bool) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.pulse, isActive: isActive)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatiblePulse(_ opacity: [Double], duration: Double) -> some View {
        if #available(iOS 17.0, *) {
            phaseAnimator(opacity) { view, level in
                view.opacity(level)
            } animation: { _ in
                .easeInOut(duration: duration)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func compatibleBadgePulse(trigger: Int) -> some View {
        if #available(iOS 17.0, *) {
            phaseAnimator([1.0, 1.1, 1.0], trigger: trigger) { view, scale in
                view.scaleEffect(scale)
            } animation: { _ in
                .spring(response: 0.26, dampingFraction: 0.6)
            }
        } else {
            self
        }
    }
}

/// Camera Control / Action button callback exists only on iOS 18.
/// A15/iOS 16 still uses the on-screen shutter and volume buttons.
struct CompatibleCaptureEventModifier: ViewModifier {
    var isEnabled: Bool
    var shoot: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled: isEnabled) { event in
                if event.phase == .ended { shoot() }
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func compatibleDetailTransition<ID: Hashable>(id: ID, namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
