import os

/// Instruments → Points of Interest. Release builds contain no signposts.
enum EditorInkPerformance {
    struct Interval {
        #if DEBUG
        let name: StaticString
        let id: OSSignpostID
        #endif

        @inline(__always) func end() {
            #if DEBUG
            os_signpost(.end, log: EditorInkPerformance.log, name: name, signpostID: id)
            #endif
        }
    }

    #if DEBUG
    private static let log = OSLog(subsystem: "com.edenkim.jottre", category: .pointsOfInterest)
    #endif

    @inline(__always) static func begin(_ name: StaticString) -> Interval {
        #if DEBUG
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Interval(name: name, id: id)
        #else
        return Interval()
        #endif
    }
}
