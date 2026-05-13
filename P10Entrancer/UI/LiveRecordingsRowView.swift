import SwiftUI

struct LiveRecordingsRowView: View {
    @ObservedObject var store: LiveRecordingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LIVE RECORDINGS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.5))
                if store.selectedID != nil {
                    Text("· tap a pad to assign")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                ForEach(0..<LiveRecordingsStore.capacity, id: \.self) { idx in
                    slot(at: idx)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func slot(at idx: Int) -> some View {
        if idx < store.recent.count {
            let rec = store.recent[idx]
            let isSelected = store.selectedID == rec.id
            ZStack {
                if let thumb = rec.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Color.black
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.5))
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(timeLabel(rec.createdAt))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.6))
                            .padding(3)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .overlay(
                Rectangle().strokeBorder(
                    isSelected ? Color.green : Color.white.opacity(0.18),
                    lineWidth: isSelected ? 3 : 1
                )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                store.toggleSelection(rec.id)
            }
        } else {
            Color.white.opacity(0.04)
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .overlay(
                    Rectangle().strokeBorder(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
