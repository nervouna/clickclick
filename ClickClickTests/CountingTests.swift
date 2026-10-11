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

    @Test func hourBucketStartsAreEpochAlignedAndContiguous() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let now = Date(timeIntervalSince1970: 1_773_146_040) // 2026-03-10T12:34:00Z
        let query = StatisticsQuery(granularity: .hour, deviceID: nil, now: now, calendar: calendar)

        let starts = query.bucketStarts
        #expect(starts.count == 7 * 24)
        #expect(starts.first == query.rangeStart)
        #expect(starts.last == query.currentBucketStart)
        #expect(starts.allSatisfy { Int64($0.timeIntervalSince1970) % 3_600 == 0 })
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 3_600 })
    }

    @Test func monthBucketStartsFollowCalendarMonthLengths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 9)))
        let query = StatisticsQuery(granularity: .month, deviceID: nil, now: now, calendar: calendar)

        let starts = query.bucketStarts
        #expect(starts.count == 24)
        #expect(starts.first == query.rangeStart)
        #expect(starts.last == query.currentBucketStart)
        #expect(starts.allSatisfy { calendar.component(.day, from: $0) == 1 && calendar.component(.hour, from: $0) == 0 })

        let february = try #require(calendar.date(from: DateComponents(year: 2025, month: 2, day: 1)))
        let march = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 1)))
        let index = try #require(starts.firstIndex(of: february))
        #expect(starts[index + 1] == march)
        #expect(calendar.dateComponents([.day], from: february, to: march).day == 28)
    }

    @Test func averageSpansFromFirstDataBucketToRangeEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_773_146_040)
        let query = StatisticsQuery(granularity: .hour, deviceID: nil, now: now, calendar: calendar)
        let starts = query.bucketStarts
        #expect(starts.count == 168)

        let deviceID = UUID()
        let device = keyboardDevice(id: deviceID, count: 400)
        func point(_ date: Date, _ count: Int64) -> TrendPoint {
            TrendPoint(date: date, deviceID: deviceID, deviceName: "Keyboard", count: count)
        }

        let snapshot = StatisticsSnapshot(
            query: query,
            devices: [device],
            trend: [point(starts[100], 300), point(starts[150], 100)],
            keyCounts: []
        )
        // Buckets 100...167 inclusive: 68 buckets, 400 / 68 == 5.
        #expect(snapshot.summary.total == 400)
        #expect(snapshot.summary.average == 400 / 68)
        #expect(snapshot.summary.peak == 300)
        #expect(snapshot.summary.activeDeviceCount == 1)
        #expect(snapshot.trend.count == 2)

        let empty = StatisticsSnapshot(query: query, devices: [device], trend: [], keyCounts: [])
        #expect(empty.summary == .empty)
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
