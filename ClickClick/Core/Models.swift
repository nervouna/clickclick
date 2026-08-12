import Foundation

struct HIDKeyID: Hashable, Codable, Sendable, Identifiable {
    let usagePage: UInt16
    let usage: UInt16

    var id: String { "\(usagePage):\(usage)" }
    var isKeyboardKey: Bool { usagePage == 0x07 }
    var isConsumerKey: Bool { usagePage == 0x0C }
    var isCountable: Bool {
        if isKeyboardKey { return usage > 0x03 }
        if isConsumerKey { return usage != 0 }
        return usage != 0
    }
}

struct KeyboardDevice: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var manufacturer: String?
    var product: String?
    var transport: String?
    var isBuiltIn: Bool
    var isConnected: Bool
    var isHidden: Bool
    var totalCount: Int64

    var kindLabel: String {
        if isBuiltIn { return "内置" }
        switch transport?.lowercased() {
        case let value? where value.contains("bluetooth"): return "蓝牙"
        case let value? where value.contains("usb"): return "USB"
        default: return "外接"
        }
    }
}

struct DeviceDescriptor: Sendable {
    let observedFingerprint: String
    let suggestedName: String
    let manufacturer: String?
    let product: String?
    let vendorID: UInt32
    let productID: UInt32
    let transport: String?
    let isBuiltIn: Bool
}

struct DeviceCount: Identifiable, Hashable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let count: Int64
    var id: UUID { deviceID }
}

struct KeyCount: Identifiable, Hashable, Sendable {
    let key: HIDKeyID
    let count: Int64
    var id: HIDKeyID { key }
}

struct TrendPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let deviceID: UUID
    let deviceName: String
    let count: Int64
    var id: String { "\(date.timeIntervalSince1970):\(deviceID.uuidString)" }
}

enum TrendGranularity: String, CaseIterable, Identifiable, Sendable {
    case minute = "分钟"
    case hour = "小时"
    case day = "天"
    case week = "周"
    case month = "月"

    var id: Self { self }

    var defaultLookback: DateComponents {
        switch self {
        case .minute: return DateComponents(hour: -3)
        case .hour: return DateComponents(day: -7)
        case .day: return DateComponents(day: -90)
        case .week: return DateComponents(weekOfYear: -52)
        case .month: return DateComponents(month: -24)
        }
    }
}

enum InputPermissionState: Equatable, Sendable {
    case notRequested
    case granted
    case denied
    case failed(String)

    var title: String {
        switch self {
        case .notRequested: "等待授权"
        case .granted: "统计中"
        case .denied: "未授予输入监控权限"
        case .failed: "监听失败"
        }
    }
}

struct DashboardSnapshot: Sendable {
    var todayTotal: Int64 = 0
    var devices: [KeyboardDevice] = []
    var todayByDevice: [DeviceCount] = []

    func visibleDevices(hideZeroCount: Bool) -> [KeyboardDevice] {
        devices.filter { device in
            !device.isHidden && (!hideZeroCount || device.totalCount > 0)
        }
    }

    func visibleTodayCounts(hideZeroCount: Bool) -> [DeviceCount] {
        hideZeroCount ? todayByDevice.filter { $0.count > 0 } : todayByDevice
    }
}
