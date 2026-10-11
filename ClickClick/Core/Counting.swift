import CryptoKit
import Foundation

struct KeyTransitionCounter: Sendable {
    private(set) var pressed: Set<HIDKeyID> = []
    private var arraySlots: [Int: HIDKeyID] = [:]

    mutating func update(key: HIDKeyID, value: Int64) -> Bool {
        if value == 0 {
            pressed.remove(key)
            return false
        }
        return pressed.insert(key).inserted
    }

    mutating func updateArray(slot: Int, usagePage: UInt16, value: Int64) -> HIDKeyID? {
        let previous = arraySlots[slot]
        let next = value == 0 || value > Int64(UInt16.max)
            ? nil
            : HIDKeyID(usagePage: usagePage, usage: UInt16(value))
        guard previous != next else { return nil }

        if let previous {
            arraySlots.removeValue(forKey: slot)
            pressed.remove(previous)
        }
        guard let next, next.isCountable else { return nil }
        arraySlots[slot] = next
        return pressed.insert(next).inserted ? next : nil
    }

    mutating func reset() {
        pressed.removeAll()
        arraySlots.removeAll()
    }
}

struct MediaPressDeduplicator: Sendable {
    private var recentPresses: [MediaPressKey: Date] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = 0.012) {
        self.window = window
    }

    mutating func shouldCount(deviceID: UUID, key: HIDKeyID, at date: Date = Date()) -> Bool {
        let identifier = MediaPressKey(deviceID: deviceID, key: key)
        if let previous = recentPresses[identifier], date.timeIntervalSince(previous) < window {
            return false
        }
        recentPresses[identifier] = date
        return true
    }
}

private struct MediaPressKey: Hashable, Sendable {
    let deviceID: UUID
    let key: HIDKeyID
}

enum DeviceFingerprint {
    static func make(
        serialNumber: String?,
        uniqueID: String?,
        isBuiltIn: Bool,
        vendorID: UInt32,
        productID: UInt32,
        transport: String?,
        locationID: UInt64?
    ) -> String {
        let identity: String
        if let serialNumber, !serialNumber.isEmpty {
            identity = "serial:\(vendorID):\(productID):\(serialNumber)"
        } else if isBuiltIn {
            identity = "built-in:\(vendorID):\(productID)"
        } else if let locationID, locationID != 0 {
            // Composite keyboard and consumer-control collections normally share
            // a physical location while exposing different software unique IDs.
            identity = "location:\(vendorID):\(productID):\(transport ?? "unknown"):\(locationID)"
        } else if let uniqueID, !uniqueID.isEmpty {
            identity = "unique:\(vendorID):\(productID):\(uniqueID)"
        } else {
            identity = "fallback:\(vendorID):\(productID):\(transport ?? "unknown")"
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum TimeBuckets {
    static func minute(for date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 / 60) * 60
    }

    static func hour(for date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 / 3_600) * 3_600
    }

    static func localDay(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func date(fromLocalDay value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func start(of granularity: TrendGranularity, for date: Date, calendar: Calendar) -> Date {
        switch granularity {
        case .minute:
            return Date(timeIntervalSince1970: TimeInterval(minute(for: date)))
        case .hour:
            return Date(timeIntervalSince1970: TimeInterval(hour(for: date)))
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }
}
