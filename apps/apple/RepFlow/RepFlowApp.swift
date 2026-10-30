import SwiftUI

@main
struct RepFlowApp: App {
    // 后台文件投递可能不创建窗口，连接随 App 初始化，不能等视图出现。
    private let transfer = RecordingTransfer.shared

    var body: some Scene {
        WindowGroup {
            ContentView(transfer: transfer)
        }
    }
}
