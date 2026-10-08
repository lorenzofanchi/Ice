//
//  IceSlider.swift
//  Ice
//

import SwiftUI

struct IceSlider<Value: BinaryFloatingPoint, ValueLabel: View>: View where Value.Stride: BinaryFloatingPoint {
    @Binding private var value: Value

    private let bounds: ClosedRange<Value>
    private let step: Value?
    private let valueLabel: ValueLabel

    init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value? = nil,
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        self._value = value
        self.bounds = bounds
        self.step = step
        self.valueLabel = valueLabel()
    }

    init(
        _ valueLabelKey: LocalizedStringKey,
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value? = nil
    ) where ValueLabel == Text {
        self._value = value
        self.bounds = bounds
        self.step = step
        self.valueLabel = Text(valueLabelKey)
    }

    /// The step, if the slider shows a tick mark for each one.
    ///
    /// Tick marks blur into a dotted line when there are many, so sliders
    /// with more steps snap to them without showing them.
    private var tickMarkStep: Value? {
        guard let step, step > 0, (bounds.upperBound - bounds.lowerBound) / step <= 20 else {
            return nil
        }
        return step
    }

    /// A binding that rounds the value to the nearest step.
    private var steppedValue: Binding<Value> {
        Binding {
            value
        } set: { newValue in
            guard let step, step > 0 else {
                value = newValue
                return
            }
            value = (newValue / step).rounded() * step
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let tickMarkStep {
                Slider(value: $value, in: bounds, step: Value.Stride(tickMarkStep))
            } else {
                Slider(value: steppedValue, in: bounds)
            }
            valueLabel
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .trailing)
        }
    }
}
