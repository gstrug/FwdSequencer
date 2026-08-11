import SwiftUI

struct PluginPickerView: View {
    @Binding var selectedPlugin: PluginInfo?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = PluginManager.shared

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Select Plugin")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if selectedPlugin != nil {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Remove") {
                                selectedPlugin = nil
                                dismiss()
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
                .onAppear { manager.scan() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        if manager.isScanning {
            VStack(spacing: 16) {
                ProgressView()
                Text("Scanning for plugins…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if manager.instruments.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No AUv3 Instruments Found")
                    .font(.headline)
                Text("Install AUv3 instrument apps on this iPad to use them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(manager.instruments, id: \.id) { plugin in
                pluginRow(plugin)
            }
        }
    }

    private func pluginRow(_ plugin: PluginInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(plugin.manufacturerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedPlugin == plugin {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPlugin = plugin
            dismiss()
        }
    }
}
