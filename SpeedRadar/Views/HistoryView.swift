import SwiftUI
import UIKit

/// Every saved shot, newest first, with a summary of the session at the top.
struct HistoryView: View {
    @EnvironmentObject private var store: MeasurementStore
    @EnvironmentObject private var settings: AppSettings

    @State private var exportURL: URL?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if store.measurements.isEmpty {
                    ContentUnavailableView(
                        "No shots yet",
                        systemImage: "figure.tennis",
                        description: Text("Measured shots are saved here automatically.")
                    )
                } else {
                    List {
                        summarySection
                        Section("Shots") {
                            ForEach(store.measurements) { measurement in
                                NavigationLink {
                                    MeasurementDetailView(measurement: measurement)
                                        .environmentObject(settings)
                                } label: {
                                    MeasurementRow(measurement: measurement, unit: settings.speedUnit)
                                }
                            }
                            .onDelete { store.delete(atOffsets: $0) }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            exportURL = try? store.exportCSV()
                        } label: {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.measurements.isEmpty)

                        Button(role: .destructive) {
                            showsDeleteConfirmation = true
                        } label: {
                            Label("Delete all", systemImage: "trash")
                        }
                        .disabled(store.measurements.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                "Delete every saved shot and its clip?",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete all", role: .destructive) { store.deleteAll() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section("Session") {
            if let fastest = store.fastest {
                LabeledContent("Fastest") {
                    Text(settings.speedUnit.formatWithUnit(metersPerSecond: fastest.speedMetersPerSecond))
                        .monospacedDigit()
                }
            }
            if let average = store.averageSpeedMetersPerSecond {
                LabeledContent("Average") {
                    Text(settings.speedUnit.formatWithUnit(metersPerSecond: average))
                        .monospacedDigit()
                }
            }
            LabeledContent("Shots") {
                Text("\(store.measurements.count)")
                    .monospacedDigit()
            }
        }
    }
}

struct MeasurementRow: View {
    let measurement: SpeedMeasurement
    let unit: SpeedUnit

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(unit.format(metersPerSecond: measurement.speedMetersPerSecond))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(unit.abbreviation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(measurement.recordedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Badge(text: measurement.estimate.method.shortName, tint: .blue)
                if measurement.videoFileName != nil {
                    Image(systemName: "film")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Minimal wrapper around `UIActivityViewController` for the CSV export.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
