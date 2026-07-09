import SwiftUI

struct ProjectView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var collapsedTracks: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    ForEach(store.project.tracks.indices, id: \.self) { idx in
                        let track = store.project.tracks[idx]
                        TrackRowView(
                            track: $store.project.tracks[idx],
                            isCollapsed: Binding(
                                get: { collapsedTracks.contains(track.id) },
                                set: { collapsed in
                                    if collapsed { collapsedTracks.insert(track.id) }
                                    else { collapsedTracks.remove(track.id) }
                                }
                            ),
                            index: idx,
                            trackCount: store.project.tracks.count
                        ) {
                            store.deleteTrack(at: IndexSet(integer: idx))
                        }
                    }

                    Button {
                        store.addTrack()
                    } label: {
                        Label("Add Track", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                            .padding(10)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
            }
        }
        .ignoresSafeArea(.keyboard)
    }
}
