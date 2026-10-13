import SwiftUI

/// 저장한 영상 목록. 영상과 정보 파일(.json)을 함께 내보낸다.
struct ClipsView: View {
    @State private var clips: [URL] = []

    var body: some View {
        Group {
            if clips.isEmpty {
                VStack(spacing: 8) {
                    Text("저장한 영상이 없습니다").font(.headline).foregroundStyle(Theme.text)
                    Text("촬영 화면에서 영상 녹화를 누르면 여기에 쌓입니다.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(clips, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                Text(size(url)).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            ShareLink(items: files(url)) {
                                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("보내기")
                        }
                        .listRowBackground(Theme.background)
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.plain)
            }
        }
        .background(Theme.background)
        .navigationTitle("저장한 영상")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: ClipRecorder.folder, includingPropertiesForKeys: nil)) ?? []
        clips = urls.filter { $0.pathExtension == "mov" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func files(_ url: URL) -> [URL] {
        let info = url.deletingPathExtension().appendingPathExtension("json")
        return FileManager.default.fileExists(atPath: info.path) ? [url, info] : [url]
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            files(clips[index]).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        load()
    }
}
