import SwiftUI

struct ContentView: View {
    @ObservedObject var transfer: RecordingTransfer

    init(transfer: RecordingTransfer = .shared) { self.transfer = transfer }

    // 从「我的 → 开发者选项」推入，导航栈由设置页提供
    var body: some View {
        List {
            Section {
                Text("在配对的 Apple Watch 上录制，收到文件后点分享，通过 AirDrop 导出到 Mac。")
                Text("原始数据请保存在仓库外的私有目录。")
                if !transfer.status.isEmpty { Text(transfer.status) }
            }
            Section("录制文件（\(transfer.files.count)）") {
                if transfer.files.isEmpty { Text("尚未收到文件，请打开手表 App 发送。") }
                ForEach(transfer.files, id: \.self) { file in
                    ShareLink(item: file) {
                        Label(file.lastPathComponent, systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("录制文件")
        .refreshable { transfer.refresh() }
    }
}

#Preview {
    NavigationStack { ContentView() }
}
