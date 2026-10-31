import Foundation
import OSLog
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Work that goes on without Plume in front (iPhone and iPad):
/// - a periodic refresh, so Spotlight, Files and the outbox stay current
///   while the app is closed;
/// - uploads that continue after leaving the app, with the system's
///   progress (iOS 26), or for the usual grace period before that.
///
/// On the Mac the app keeps running when its windows are closed, so none of
/// this is needed there.
@MainActor
final class Background {
    static let shared = Background()
    weak var model: AppModel?

    private let log = Logger(subsystem: "Plume", category: "Background")
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "plume" }
    private var refreshID: String { bundleID + ".refresh" }
    private var uploadPrefix: String { bundleID + ".upload." }

    #if os(iOS)
    /// The system task keeping uploads alive, while there are some.
    private var uploadTask: BGTask?
    private var graceTask: UIBackgroundTaskIdentifier = .invalid
    private var uploadsSubmitted = false
    #endif

    /// Registers the launch handlers: before the app finishes launching.
    func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            let box = UncheckedTask(task)
            Task { @MainActor in Background.shared.refresh(box.task) }
        }
        if #available(iOS 26, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: uploadPrefix + "*", using: nil) { task in
                let box = UncheckedTask(task)
                Task { @MainActor in Background.shared.runUploads(box.task) }
            }
        }
        #endif
    }

    // MARK: Refresh

    /// Asks for the next refresh, at the earliest in 15 minutes (the system
    /// decides when, from how Plume is used).
    func scheduleRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("Refresh not scheduled: \(error, privacy: .public)")
        }
        #endif
    }

    #if os(iOS)
    private func refresh(_ task: BGTask) {
        scheduleRefresh()
        guard let model else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { await model.sync() }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
    #endif

    // MARK: Uploads

    /// Uploads started (`count` in progress, `progress` over all of them):
    /// keep the app running until they end.
    func uploadsChanged(count: Int, progress: Progress) {
        #if os(iOS)
        if count == 0 {
            uploadTask?.setTaskCompleted(success: true)
            uploadTask = nil
            uploadsSubmitted = false
            if graceTask != .invalid {
                UIApplication.shared.endBackgroundTask(graceTask)
                graceTask = .invalid
            }
            return
        }
        if #available(iOS 26, *), !uploadsSubmitted {
            uploadsSubmitted = true
            let request = BGContinuedProcessingTaskRequest(
                identifier: uploadPrefix + UUID().uuidString,
                title: "Uploading to Plume",
                subtitle: count == 1 ? "1 file" : "\(count) files")
            request.strategy = .queue
            do {
                try BGTaskScheduler.shared.submit(request)
                currentProgress = progress
                return
            } catch {
                log.error("Continued upload not submitted: \(error, privacy: .public)")
            }
        }
        if graceTask == .invalid {
            graceTask = UIApplication.shared.beginBackgroundTask(withName: "Uploads") { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(graceTask)
                graceTask = .invalid
            }
        }
        currentProgress = progress
        #endif
    }

    /// The uploads' progress, mirrored into the system's.
    private var currentProgress: Progress?

    #if os(iOS)
    @available(iOS 26, *)
    private func runUploads(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask, uploadsSubmitted else {
            task.setTaskCompleted(success: true)
            return
        }
        uploadTask = task
        task.progress.totalUnitCount = 1000
        // The system shows `task.progress`; follow the uploads' until they end.
        let follow = Task { [weak self] in
            while !Task.isCancelled, let self, self.uploadTask === task {
                if let progress = self.currentProgress, progress.totalUnitCount > 0 {
                    task.progress.completedUnitCount = Int64(progress.fractionCompleted * 1000)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        task.expirationHandler = { [weak self] in
            follow.cancel()
            // Unsent uploads stay in the outbox and go at the next sync.
            Task { @MainActor in
                guard let self, self.uploadTask === task else { return }
                self.uploadTask = nil
                self.uploadsSubmitted = false
                task.setTaskCompleted(success: false)
            }
        }
    }
    #endif
}

#if os(iOS)
/// BGTask predates Sendable; each is handed over once, to the main actor.
private struct UncheckedTask: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}
#endif
