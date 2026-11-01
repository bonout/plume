import Darwin
import Foundation
@testable import PlumeKit
import Synchronization
import Testing

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

@Suite(.enabled(if: TestServer.credentials != nil
                && ProcessInfo.processInfo.environment["PLUME_BIG_UPLOAD_MB"] != nil,
                "PLUME_BIG_UPLOAD_MB and PLUME_TEST_SERVER are not set"))
struct MemoryTests {
    @Test func bigUploadKeepsMemoryFlat() async throws {
        let megabytes = Int(ProcessInfo.processInfo.environment["PLUME_BIG_UPLOAD_MB"]!)!
        let credentials = try await LoginFlow.complete(
            server: TestServer.credentials!.account.server, loginName: TestServer.credentials!.account.loginName,
            appPassword: TestServer.credentials!.appPassword)
        let client = NextcloudClient(credentials: credentials)
        let file = FileManager.default.temporaryDirectory.appending(path: "plume-big-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        var block = Data(count: 1024 * 1024)
        block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        for _ in 0..<megabytes { handle.write(block) }
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        let baseline = footprint()
        let peak = Atomic<UInt64>(baseline)
        let sampler = Task {
            while !Task.isCancelled {
                let now = footprint()
                if now > peak.load(ordering: .relaxed) { peak.store(now, ordering: .relaxed) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let path = RemotePath("plume-big-upload-\(UUID().uuidString.prefix(8)).bin")
        let started = Date()
        let item = try await client.upload(file, to: path, overwrite: false)
        sampler.cancel()
        let growth = Double(peak.load(ordering: .relaxed) - baseline) / 1_048_576
        print("MEMORY upload \(megabytes) MB in \(Int(Date().timeIntervalSince(started))) s, footprint grew \(Int(growth)) MB")
        try? await client.delete(path)
        #expect(item.size == Int64(megabytes) * 1024 * 1024)
        #expect(growth < 150)
    }
}
