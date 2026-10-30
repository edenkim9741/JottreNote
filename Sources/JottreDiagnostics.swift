import Foundation
import CryptoKit
import MachO
import MetricKit
import UIKit

/// Small, local-only diagnostics recorder. Events are deliberately coarse and
/// never include document names, paths, PDF bytes, or stroke coordinates.
final class JottreDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    private struct Details: @unchecked Sendable {
        let value: [String: Any]
    }

    static let shared = JottreDiagnostics()

    private let queue = DispatchQueue(label: "com.edenkim.jottre.diagnostics", qos: .utility)
    private let fileManager = FileManager.default
    private let inkStateLock = NSLock()
    private var sessionID = ""
    private var session: [String: Any] = [:]
    private var latestStrokeCount = 0
    private var lastInkChangeAt: Date?
    private var sampleTimer: DispatchSourceTimer?
    private var didStart = false

    private var directoryURL: URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    @MainActor func start() {
        let deviceModel = UIDevice.current.model
        queue.sync {
            guard !didStart else { return }
            didStart = true
            guard let directoryURL else { return }
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                summarizePreviousSession(in: directoryURL)

                sessionID = Self.makeSessionID()
                let now = ISO8601DateFormatter().string(from: Date())
                session = [
                    "sessionID": sessionID,
                    "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
                    "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown",
                    "iOSVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                    "device": deviceModel,
                    "sessionStart": now,
                    "lastActivityAt": now,
                    "lastEvent": "app.launch",
                    "termination": "Unconfirmed",
                    "active": true,
                    "memoryWarningCount": 0,
                    "lastSuccessfulRevision": NSNull(),
                    "pendingRevision": NSNull(),
                    "lastFootprintBytes": NSNull(),
                    "highestFootprintBytes": 0
                ]
                persistSession()
                appendEvent("app.launch", details: [:])
                trimOldSessions(in: directoryURL, keeping: 20)
                installLifecycleObservers()
                startMemorySampling()
                MXMetricManager.shared.add(self)
            } catch {
                // Diagnostics must never interfere with editing or persistence.
            }
        }
    }

    func record(_ name: String, details: [String: Any] = [:]) {
        let safeDetails = Details(value: details)
        queue.async { [weak self] in
            guard let self, didStart else { return }
            appendEvent(name, details: safeDetails.value)
        }
    }

    func recordDocument(
        identifier: String,
        pdfSize: Int,
        pageCount: Int,
        strokeCount: Int,
        revision: UInt64? = nil,
        persistedRevision: UInt64? = nil
    ) {
        inkStateLock.lock()
        latestStrokeCount = strokeCount
        inkStateLock.unlock()
        queue.async { [weak self] in
            guard let self, didStart else { return }
            session["documentID"] = Self.anonymizedIdentifier(identifier)
            session["pdfSizeBytes"] = pdfSize
            session["pageCount"] = pageCount
            session["strokeCount"] = strokeCount
            if let revision { session["pendingRevision"] = revision }
            if let persistedRevision { session["lastSuccessfulRevision"] = persistedRevision }
            appendEvent("document.loaded", details: [
                "pdfSizeBytes": pdfSize,
                "pageCount": pageCount,
                "strokeCount": strokeCount
            ])
        }
    }

    func recordPage(_ pageIndex: Int, strokeCount: Int) {
        queue.async { [weak self] in
            guard let self, didStart else { return }
            session["lastPage"] = pageIndex
            session["strokeCount"] = strokeCount
            updateActivity("pdf.pageChanged")
        }
    }

    /// In-memory only. Pencil input never waits on diagnostics I/O; the latest
    /// aggregate is persisted at the next lifecycle/save event or memory sample.
    func updateInkState(strokeCount: Int) {
        inkStateLock.lock()
        latestStrokeCount = strokeCount
        lastInkChangeAt = Date()
        inkStateLock.unlock()
    }

    func recordPersistence(
        identifier: String,
        revision: UInt64,
        strokeCount: Int,
        result: String,
        durationMilliseconds: Double? = nil,
        errorType: String? = nil
    ) {
        queue.async { [weak self] in
            guard let self, didStart else { return }
            session["documentID"] = Self.anonymizedIdentifier(identifier)
            session["pendingRevision"] = revision
            session["strokeCount"] = strokeCount
            if result == "success" {
                session["lastSuccessfulRevision"] = revision
                session["pendingRevision"] = NSNull()
                session["lastSaveResult"] = "success"
                if let durationMilliseconds { session["lastSaveDurationMilliseconds"] = durationMilliseconds }
            } else if result == "failure" {
                session["lastSaveResult"] = "failure"
                session["lastSaveErrorType"] = errorType ?? "Unknown"
            }
            var details: [String: Any] = [
                "revision": revision,
                "strokeCount": strokeCount,
                "durationMilliseconds": durationMilliseconds as Any? ?? NSNull()
            ]
            if let errorType { details["errorType"] = errorType }
            appendEvent("persistence.\(result)", details: details)
        }
    }

    func recordPersistenceStarted(identifier: String, revision: UInt64, strokeCount: Int, pdfSizeBytes: Int) {
        queue.async { [weak self] in
            guard let self, didStart else { return }
            session["documentID"] = Self.anonymizedIdentifier(identifier)
            session["pendingRevision"] = revision
            session["strokeCount"] = strokeCount
            appendEvent("persistence.started", details: [
                "revision": revision,
                "strokeCount": strokeCount,
                "pdfSizeBytes": pdfSizeBytes
            ])
        }
    }

    func recordPDFSaveStage(_ stage: String, durationMilliseconds: Double? = nil, byteCount: Int? = nil) {
        var details: [String: Any] = [:]
        if let durationMilliseconds { details["durationMilliseconds"] = durationMilliseconds }
        if let byteCount { details["byteCount"] = byteCount }
        record("pdf.save.\(stage)", details: details)
    }

    func sampleMemoryNow(for event: String) {
        queue.async { [weak self] in
            guard let self, didStart else { return }
            guard let footprint = Self.currentFootprintBytes() else {
                appendEvent(event, details: ["footprintBytes": NSNull()])
                return
            }
            session["lastFootprintBytes"] = footprint
            session["highestFootprintBytes"] = max(session["highestFootprintBytes"] as? UInt64 ?? 0, footprint)
            var sample: [String: Any] = ["timestamp": Self.timestamp(), "event": event, "footprintBytes": footprint]
            if let documentID = session["documentID"] { sample["documentID"] = documentID }
            appendJSONLine(sample, to: "memory-\(sessionID).jsonl")
            appendEvent(event, details: ["footprintBytes": footprint])
        }
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(willTerminate), name: UIApplication.willTerminateNotification, object: nil)
        center.addObserver(self, selector: #selector(didReceiveMemoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    @objc private func didEnterBackground() { record("app.background") }
    @objc private func didBecomeActive() { record("app.foreground") }
    @objc private func willTerminate() { record("app.willTerminate") }

    @objc private func didReceiveMemoryWarning() {
        queue.async { [weak self] in
            guard let self, didStart else { return }
            let count = (session["memoryWarningCount"] as? Int ?? 0) + 1
            session["memoryWarningCount"] = count
            appendEvent("memory.warning", details: ["count": count, "footprintBytes": Self.currentFootprintBytes() as Any? ?? NSNull()])
        }
    }

    private func startMemorySampling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60), leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.sampleMemory() }
        timer.resume()
        sampleTimer = timer
    }

    private func sampleMemory() {
        guard let footprint = Self.currentFootprintBytes() else { return }
        session["lastFootprintBytes"] = footprint
        session["highestFootprintBytes"] = max(session["highestFootprintBytes"] as? UInt64 ?? 0, footprint)
        persistLatestInkState()
        updateActivity("memory.sample")
        let sample: [String: Any] = ["timestamp": Self.timestamp(), "footprintBytes": footprint]
        appendJSONLine(sample, to: "memory-\(sessionID).jsonl")
    }

    private func appendEvent(_ name: String, details: [String: Any]) {
        persistLatestInkState()
        updateActivity(name)
        var event: [String: Any] = ["timestamp": Self.timestamp(), "event": name]
        event.merge(details) { _, new in new }
        appendJSONLine(event, to: "events-\(sessionID).jsonl")
        persistSession()
    }

    private func updateActivity(_ name: String) {
        session["lastActivityAt"] = Self.timestamp()
        session["lastEvent"] = name
        persistSession()
    }

    private func persistLatestInkState() {
        inkStateLock.lock()
        let strokeCount = latestStrokeCount
        let lastChange = lastInkChangeAt
        inkStateLock.unlock()
        session["strokeCount"] = strokeCount
        if let lastChange { session["lastInkChangeAt"] = Self.isoTimestamp(lastChange) }
    }

    private func persistSession() {
        guard let directoryURL, !sessionID.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: session, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directoryURL.appendingPathComponent("session-\(sessionID).json"), options: .atomic)
        try? data.write(to: directoryURL.appendingPathComponent("active-session.json"), options: .atomic)
    }

    private func appendJSONLine(_ object: [String: Any], to filename: String) {
        guard let directoryURL,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let url = directoryURL.appendingPathComponent(filename)
        var line = data
        line.append(0x0A)
        if fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.synchronize()
                let limit: Int64 = filename.hasPrefix("memory-") ? 512 * 1024 : 1024 * 1024
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   Int64(size) > limit {
                    let tailHandle = try FileHandle(forReadingFrom: url)
                    defer { try? tailHandle.close() }
                    try tailHandle.seek(toOffset: UInt64(max(0, Int64(size) - limit / 2)))
                    let tail = try tailHandle.readToEnd() ?? Data()
                    try tail.write(to: url, options: .atomic)
                }
            } catch { }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private func summarizePreviousSession(in directory: URL) {
        let activeURL = directory.appendingPathComponent("active-session.json")
        guard let data = try? Data(contentsOf: activeURL),
              let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let previousID = previous["sessionID"] as? String else { return }

        let eventURL = directory.appendingPathComponent("events-\(previousID).jsonl")
        let events: [String]
        if let handle = try? FileHandle(forReadingFrom: eventURL) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 64 * 1024 ? size - 64 * 1024 : 0)
            events = ((try? handle.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? "")
                .split(whereSeparator: \.isNewline).suffix(15).map(String.init)
        } else {
            events = []
        }
        let lastFootprint = (previous["lastFootprintBytes"] as? NSNumber).map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .memory) } ?? "Not observed"
        let highestFootprint = (previous["highestFootprintBytes"] as? NSNumber).map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .memory) } ?? "Not observed"
        let documentID = previous["documentID"] as? String ?? "None"
        let report = [
            "JottreNote Diagnostic Report",
            "",
            "Session: \(previousID)",
            "App Version: \(previous["appVersion"] ?? "Unknown") (\(previous["buildVersion"] ?? "Unknown"))",
            "iOS Version: \(previous["iOSVersion"] ?? "Unknown")",
            "Device: \(previous["device"] ?? "Unknown")",
            "Session Start: \(previous["sessionStart"] ?? "Unknown")",
            "Last Recorded Activity: \(previous["lastActivityAt"] ?? "Unknown")",
            "Termination: Unconfirmed",
            "Document ID (anonymous): \(documentID)",
            "PDF Size: \(previous["pdfSizeBytes"] ?? "Unknown") bytes",
            "PDF Page Count: \(previous["pageCount"] ?? "Unknown")",
            "Last Page: \(previous["lastPage"] ?? "Unknown")",
            "Stroke Count: \(previous["strokeCount"] ?? "Unknown")",
            "Last Ink Change: \(previous["lastInkChangeAt"] ?? "Unknown")",
            "Last Successful Revision: \(previous["lastSuccessfulRevision"] ?? "Unknown")",
            "Pending Revision: \(previous["pendingRevision"] ?? "Unknown")",
            "Last Save Duration: \(previous["lastSaveDurationMilliseconds"] ?? "Unknown") ms",
            "Last Save Result: \(previous["lastSaveResult"] ?? "Unknown")",
            "Last Save Error Type: \(previous["lastSaveErrorType"] ?? "None")",
            "Last Observed Footprint: \(lastFootprint)",
            "Highest Observed Footprint: \(highestFootprint)",
            "Memory Warning Count: \(previous["memoryWarningCount"] ?? 0)",
            "",
            "Last Events:",
            events.map { "- \($0)" }.joined(separator: "\n"),
            "",
            "Possible Failure Stage: \(previous["lastEvent"] ?? "Unknown; insufficient evidence")",
            "Available Evidence: Locally persisted events and periodic memory footprint samples.",
            "Limitations: iOS may terminate an app without a callback. This report does not infer a crash or Jetsam event without system diagnostics."
        ].joined(separator: "\n")
        try? Data(report.utf8).write(to: directory.appendingPathComponent("report-\(previousID).txt"), options: .atomic)
        var closedPrevious = previous
        closedPrevious["active"] = false
        closedPrevious["termination"] = "Unconfirmed"
        if let closedData = try? JSONSerialization.data(withJSONObject: closedPrevious, options: [.prettyPrinted, .sortedKeys]) {
            try? closedData.write(to: directory.appendingPathComponent("session-\(previousID).json"), options: .atomic)
        }
        try? fileManager.removeItem(at: activeURL)
    }

    private func trimOldSessions(in directory: URL, keeping limit: Int) {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for prefix in ["metric-", "diagnostic-"] {
            let payloads = urls.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
                .sorted { lhs, rhs in
                    let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return left > right
                }
            payloads.dropFirst(limit).forEach { try? fileManager.removeItem(at: $0) }
        }
        let sessionURLs = urls.filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for oldEvents in sessionURLs.dropFirst(limit) {
            let id = oldEvents.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "events-", with: "")
            for prefix in ["events-", "memory-", "session-", "report-"] {
                let suffix = prefix == "report-" ? "txt" : (prefix == "session-" ? "json" : "jsonl")
                try? fileManager.removeItem(at: directory.appendingPathComponent("\(prefix)\(id).\(suffix)"))
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        persistMetricPayloads(payloads.map { ($0.jsonRepresentation(), "metric") })
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persistMetricPayloads(payloads.map { ($0.jsonRepresentation(), "diagnostic") })
    }

    private func persistMetricPayloads(_ payloads: [(Data, String)]) {
        queue.async { [weak self] in
            guard let self, didStart else { return }
            for (data, kind) in payloads {
                let filename = "\(kind)-\(sessionID)-\(UUID().uuidString).json"
                if let directoryURL {
                    try? data.write(to: directoryURL.appendingPathComponent(filename), options: .atomic)
                }
                appendEvent("metrickit.\(kind)PayloadReceived", details: [:])
            }
        }
    }

    private static func currentFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private static func anonymizedIdentifier(_ value: String) -> String {
        String(SHA256Digest.hex(of: Data(value.utf8)).prefix(16))
    }

    private static func makeSessionID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }

    private static func timestamp() -> String { isoTimestamp(Date()) }

    private static func isoTimestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private enum SHA256Digest {
    static func hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
