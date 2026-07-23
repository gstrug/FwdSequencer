import SwiftUI

struct ScalePickerView: View {
    @Binding var selectedScale: MusicalScale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(MusicalScale.allCases, id: \.self) { scale in
                scaleRow(scale)
            }
            .navigationTitle("Select Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func scaleRow(_ scale: MusicalScale) -> some View {
        HStack {
            Text(scale.rawValue)
            Spacer()
            if scale == selectedScale {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedScale = scale
            dismiss()
        }
    }
}
