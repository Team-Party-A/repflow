import Combine
import Foundation
import WatchConnectivity

/// 录制文件走 transferFile；不进入训练记录的 transferUserInfo 消息或后端上传。
/// 一个 WCSession 只能有一个 delegate，训练消息也从这里转出，解析和写库由各端自己处理。
final class RecordingTransfer: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = RecordingTransfer()
    @Published private(set) var files: [URL] = []
    @Published private(set) var status = ""
    private let storage = RecordingFiles()
    /// 都在主队列回调
    var onUserInfo: (([String: Any]) -> Void)?
    var onActivated: (() -> Void)?

    override init() {
        super.init()
        #if os(watchOS)
            onUserInfo = { TrainingOutbox.shared.receive($0) }
            onActivated = { TrainingOutbox.shared.check(force: true) }
        #endif
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        refresh()
    }

    func refresh() {
        do { files = try storage.list() } catch {
            status = "读取录制列表失败：\(error.localizedDescription)"
        }
    }

    func send(_ file: URL) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            status = "连接尚未就绪，请打开手机 App，稍后重试。"
            return
        }
        guard
            !session.outstandingFileTransfers.contains(where: {
                $0.file.fileURL.lastPathComponent == file.lastPathComponent
            })
        else {
            status = "文件已在传输队列中，请在手机查看。"
            return
        }
        session.transferFile(file, metadata: nil)
        status = "已排队，系统将择机传输；原文件保留在手表。"
    }

    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            if let error { self.status = "连接失败：\(error.localizedDescription)" }
            if activationState == .activated { self.onActivated?() }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async { self.onUserInfo?(userInfo) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 系统在回调返回后删除临时文件，必须在这里同步保存，不延迟到 UI 队列。
        do {
            try storage.save(Data(contentsOf: file.fileURL))
            DispatchQueue.main.async {
                self.refresh()
                self.status = "已保存录制文件，可以导出。"
            }
        } catch {
            let message = "保存接收文件失败，请在手表重发：\(error.localizedDescription)"
            DispatchQueue.main.async { self.status = message }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?)
    {
        DispatchQueue.main.async {
            self.status =
                error.map { "传输失败，可重试：\($0.localizedDescription)" }
                ?? "系统传输完成，请在手机确认文件；手表仍保留原文件。"
        }
    }

    #if os(watchOS)
        func session(
            _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer,
            error: Error?
        ) {
            DispatchQueue.main.async {
                TrainingOutbox.shared.transferFinished(userInfoTransfer.userInfo, error: error)
            }
        }
    #endif

    #if os(iOS)
        func sessionDidBecomeInactive(_ session: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
