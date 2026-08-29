import SwiftUI

/// Choice of the reference rectangle used for calibration.
struct CourtPickerView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CourtPreset.all) { preset in
                        Button {
                            settings.selectCourt(preset)
                            dismiss()
                        } label: {
                            row(
                                name: preset.name,
                                detail: preset.detail,
                                isSelected: settings.courtPresetID == preset.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Standard courts")
                } footer: {
                    Text(
                        "Any rectangle with known dimensions works. Use a full court when you can — a larger reference gives the geometry more to work with."
                    )
                }

                Section("Custom rectangle") {
                    LabeledContent("Width") {
                        DimensionField(value: $settings.customWidth)
                    }
                    LabeledContent("Length") {
                        DimensionField(value: $settings.customLength)
                    }
                    Button {
                        settings.courtPresetID = "custom"
                        dismiss()
                    } label: {
                        row(
                            name: "Use custom rectangle",
                            detail: String(
                                format: "%.2f m × %.2f m", settings.customWidth,
                                settings.customLength),
                            isSelected: settings.courtPresetID == "custom"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Reference court")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(name: String, detail: String, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Numeric entry for a length in metres.
struct DimensionField: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 4) {
            TextField(
                "0",
                value: $value,
                format: .number.precision(.fractionLength(0...3))
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 90)
            Text("m")
                .foregroundStyle(.secondary)
        }
    }
}
