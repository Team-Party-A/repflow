import WatchConnectivity
import WatchKit

final class RecordingBackgroundTasks: NSObject, WKApplicationDelegate {
    private var pending: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var contentObservation: NSKeyValueObservation?
    private var activationObservation: NSKeyValueObservation?

    override init() {
        super.init()
        let session = WCSession.default
        contentObservation = session.observe(\.hasContentPending, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.completeFinishedTasks() }
        }
        activationObservation = session.observe(\.activationState, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.completeFinishedTasks() }
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                pending.append(connectivity)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        completeFinishedTasks()
    }

    private func completeFinishedTasks() {
        let session = WCSession.default
        guard session.activationState == .activated, !session.hasContentPending else { return }
        for task in pending { task.setTaskCompletedWithSnapshot(false) }
        pending.removeAll()
    }
}
