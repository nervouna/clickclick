import Foundation
import Testing
@testable import ClickClick

struct CountingTests {
    @Test func transitionCountsOnlyPressEdges() {
        let key = HIDKeyID(usagePage: 0x07, usage: 0x04)
        var counter = KeyTransitionCounter()

        let first = counter.update(key: key, value: 1)
        let repeated = counter.update(key: key, value: 1)
        let released = counter.update(key: key, value: 0)
        let second = counter.update(key: key, value: 1)
        #expect(first)
        #expect(!repeated)
        #expect(!released)
        #expect(second)
    }

    @Test func modifiersRemainIndependent() {
        let leftShift = HIDKeyID(usagePage: 0x07, usage: 0xE1)
        let rightShift = HIDKeyID(usagePage: 0x07, usage: 0xE5)
        var counter = KeyTransitionCounter()

        let left = counter.update(key: leftShift, value: 1)
        let right = counter.update(key: rightShift, value: 1)
        let repeated = counter.update(key: leftShift, value: 1)
        #expect(left)
        #expect(right)
        #expect(!repeated)
    }

    @Test func arrayElementsUseValueAsUsageAndDeduplicateSlots() {
        var counter = KeyTransitionCounter()
        let first = counter.updateArray(slot: 1, usagePage: 0x07, value: 0x04)
        let repeated = counter.updateArray(slot: 1, usagePage: 0x07, value: 0x04)
        let released = counter.updateArray(slot: 1, usagePage: 0x07, value: 0)
        let second = counter.updateArray(slot: 1, usagePage: 0x07, value: 0x05)
        #expect(first == HIDKeyID(usagePage: 0x07, usage: 0x04))
        #expect(repeated == nil)
        #expect(released == nil)
        #expect(second == HIDKeyID(usagePage: 0x07, usage: 0x05))
    }

    @Test func fingerprintPrioritizesStableIdentity() {
        let first = DeviceFingerprint.make(
            serialNumber: "serial", uniqueID: "one", isBuiltIn: false,
            vendorID: 1, productID: 2, transport: "USB", locationID: 3
        )
        let moved = DeviceFingerprint.make(
            serialNumber: "serial", uniqueID: "two", isBuiltIn: false,
            vendorID: 1, productID: 2, transport: "USB", locationID: 99
        )
        #expect(first == moved)
    }

    @Test func builtInFingerprintIgnoresLocation() {
        let first = DeviceFingerprint.make(
            serialNumber: nil, uniqueID: nil, isBuiltIn: true,
            vendorID: 1, productID: 2, transport: "SPI", locationID: 3
        )
        let second = DeviceFingerprint.make(
            serialNumber: nil, uniqueID: nil, isBuiltIn: true,
            vendorID: 1, productID: 2, transport: "SPI", locationID: 5
        )
        #expect(first == second)
    }

    @Test func compositeCollectionsSharePhysicalLocation() {
        let keyboard = DeviceFingerprint.make(
            serialNumber: nil, uniqueID: "keyboard-collection", isBuiltIn: false,
            vendorID: 1, productID: 2, transport: "USB", locationID: 42
        )
        let media = DeviceFingerprint.make(
            serialNumber: nil, uniqueID: "consumer-collection", isBuiltIn: false,
            vendorID: 1, productID: 2, transport: "USB", locationID: 42
        )
        #expect(keyboard == media)
    }

    @Test func unknownKeyStillHasStableName() {
        let name = KeyCatalog.name(for: HIDKeyID(usagePage: 0x07, usage: 0xFF))
        #expect(name == "键 0xFF")
    }

    @Test func reservedKeyboardUsagesAreNotCountable() {
        for usage in UInt16(0)...UInt16(3) {
            #expect(!HIDKeyID(usagePage: 0x07, usage: usage).isCountable)
        }
        #expect(!HIDKeyID(usagePage: 0x0C, usage: 0).isCountable)
        #expect(HIDKeyID(usagePage: 0x07, usage: 0x04).isCountable)
    }

    @Test func dashboardHidesZeroCountDevicesWhenRequested() {
        let activeID = UUID()
        let idleID = UUID()
        let hiddenID = UUID()
        let snapshot = DashboardSnapshot(
            todayTotal: 3,
            devices: [
                keyboardDevice(id: activeID, count: 10),
                keyboardDevice(id: idleID, count: 0),
                keyboardDevice(id: hiddenID, count: 5, isHidden: true)
            ],
            todayByDevice: [
                DeviceCount(deviceID: activeID, deviceName: "Active", count: 3),
                DeviceCount(deviceID: idleID, deviceName: "Idle", count: 0)
            ]
        )

        #expect(snapshot.visibleDevices(hideZeroCount: true).map(\.id) == [activeID])
        #expect(snapshot.visibleDevices(hideZeroCount: false).map(\.id) == [activeID, idleID])
        #expect(snapshot.visibleTodayCounts(hideZeroCount: true).map(\.deviceID) == [activeID])
        #expect(snapshot.visibleTodayCounts(hideZeroCount: false).map(\.deviceID) == [activeID, idleID])
    }

    @Test func timeBucketsUseUTCBoundaries() {
        let date = Date(timeIntervalSince1970: 3_661)
        #expect(TimeBuckets.minute(for: date) == 3_660)
        #expect(TimeBuckets.hour(for: date) == 3_600)
    }

    @Test func localDayRespectsTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let date = Date(timeIntervalSince1970: 0)
        #expect(TimeBuckets.localDay(for: date, calendar: calendar) == "1970-01-01")
    }

    @Test func localDayHandlesDaylightSavingBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let second = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9)))
        #expect(second.timeIntervalSince(first) == 23 * 3_600)
        #expect(TimeBuckets.start(of: .day, for: first.addingTimeInterval(20 * 3_600), calendar: calendar) == first)
    }

    @Test func mediaReportsAreDeduplicatedOnlyInsideWindow() {
        let device = UUID()
        let key = HIDKeyID(usagePage: 0x0C, usage: 0xE9)
        let start = Date(timeIntervalSince1970: 1_000)
        var deduplicator = MediaPressDeduplicator()
        let first = deduplicator.shouldCount(deviceID: device, key: key, at: start)
        let duplicate = deduplicator.shouldCount(deviceID: device, key: key, at: start.addingTimeInterval(0.005))
        let next = deduplicator.shouldCount(deviceID: device, key: key, at: start.addingTimeInterval(0.020))
        #expect(first)
        #expect(!duplicate)
        #expect(next)
    }

    private func keyboardDevice(id: UUID, count: Int64, isHidden: Bool = false) -> KeyboardDevice {
        KeyboardDevice(
            id: id,
            name: "Keyboard",
            manufacturer: nil,
            product: nil,
            transport: nil,
            isBuiltIn: false,
            isConnected: true,
            isHidden: isHidden,
            totalCount: count
        )
    }
}
