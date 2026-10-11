import CoreHID
import Foundation

actor CoreHIDInputMonitor {
    private var manager = HIDDeviceManager()
    private let engine: StatisticsEngine
    private var monitorTask: Task<Void, Never>?
    private var deviceTasks: [UInt64: Task<Void, Never>] = [:]
    private var retryTasks: [UInt64: Task<Void, Never>] = [:]
    private var transitions: [UInt64: KeyTransitionCounter] = [:]
    private var canonicalIDs: [UInt64: UUID] = [:]
    private var descriptors: [UInt64: DeviceDescriptor] = [:]
    private var mediaDeduplicator = MediaPressDeduplicator()
    private var deviceDirectoryDidChange: (@Sendable () async -> Void)?
    private var stateDidChange: (@Sendable (InputPermissionState) async -> Void)?
    private(set) var state: InputPermissionState = InputPermission.currentState()
    private(set) var isPaused = false

    init(engine: StatisticsEngine) {
        self.engine = engine
    }

    func setDeviceDirectoryHandler(_ handler: (@Sendable () async -> Void)?) {
        deviceDirectoryDidChange = handler
    }

    func setStateHandler(_ handler: (@Sendable (InputPermissionState) async -> Void)?) {
        stateDidChange = handler
    }

    func refreshPermission() async -> InputPermissionState {
        let permission = InputPermission.currentState()
        if case .granted = permission, monitorTask == nil {
            start()
        } else if permission != .granted {
            await stopListening(notifyDirectoryChange: true)
        }
        state = permission
        await stateDidChange?(state)
        return state
    }

    func requestPermission() async -> InputPermissionState {
        _ = InputPermission.request()
        return await refreshPermission()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            for reference in transitions.keys {
                transitions[reference]?.reset()
            }
        }
    }

    func start() {
        guard monitorTask == nil, InputPermission.currentState() == .granted else { return }
        state = .granted
        monitorTask = Task { [weak self] in
            await self?.observeDevices()
        }
    }

    func stop() async {
        await stopListening(notifyDirectoryChange: false)
    }

    private func stopListening(notifyDirectoryChange: Bool) async {
        monitorTask?.cancel()
        monitorTask = nil
        await detachAll(notifyDirectoryChange: notifyDirectoryChange)
    }

    private func detachAll(notifyDirectoryChange: Bool) async {
        for task in deviceTasks.values { task.cancel() }
        for task in retryTasks.values { task.cancel() }
        let referenceIDs = Array(canonicalIDs.keys)
        deviceTasks.removeAll()
        retryTasks.removeAll()
        transitions.removeAll()
        canonicalIDs.removeAll()
        descriptors.removeAll()
        for referenceID in referenceIDs {
            await engine.disconnect(referenceID: referenceID)
        }
        if notifyDirectoryChange, !referenceIDs.isEmpty {
            await deviceDirectoryDidChange?()
        }
    }

    private func observeDevices() async {
        let keyboard = HIDUsage(
            page: HIDUsage.GenericDesktopUsage.page,
            usage: HIDUsage.GenericDesktopUsage.keyboard.rawValue
        )
        let consumer = HIDUsage(
            page: HIDUsage.ConsumerUsage.page,
            usage: HIDUsage.ConsumerUsage.consumerControl.rawValue
        )
        let criteria = [
            HIDDeviceManager.DeviceMatchingCriteria(primaryUsage: keyboard),
            HIDDeviceManager.DeviceMatchingCriteria(primaryUsage: consumer)
        ]

        // The first end of the stream is the original failure, so `failures > 3`
        // means three consecutive restarts failed without a single notification.
        var failures = 0
        var backoff = Duration.seconds(2)
        var lastError = "device notification stream ended"
        while !Task.isCancelled {
            do {
                for try await notification in await manager.monitorNotifications(matchingCriteria: criteria) {
                    guard !Task.isCancelled else { return }
                    let wasFailed = failures > 3
                    failures = 0
                    backoff = .seconds(2)
                    if wasFailed {
                        state = .granted
                        await stateDidChange?(state)
                    }
                    switch notification {
                    case .deviceMatched(let reference):
                        await attach(reference)
                    case .deviceRemoved(let reference):
                        await detach(referenceID: reference.deviceID)
                    @unknown default:
                        break
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
            guard !Task.isCancelled else { return }

            failures += 1
            await detachAll(notifyDirectoryChange: true)
            // A stop during the awaits above cancelled this task and may have started
            // a new one, which must not be touched from here.
            guard !Task.isCancelled else { return }
            let permission = InputPermission.currentState()
            guard permission == .granted else {
                monitorTask = nil
                state = permission
                await stateDidChange?(state)
                return
            }
            if failures > 3 {
                state = .failed(lastError)
                await stateDidChange?(state)
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(60))
            // A manager whose stream ended may be unusable, so restart on a fresh one.
            manager = HIDDeviceManager()
        }
    }

    private func attach(_ reference: HIDDeviceClient.DeviceReference) async {
        let referenceID = reference.deviceID
        guard deviceTasks[referenceID] == nil,
              let client = HIDDeviceClient(deviceReference: reference) else { return }

        let vendorID = await client.vendorID
        let productID = await client.productID
        let product = await client.product
        let manufacturer = await client.manufacturer
        let serial = await client.serialNumber
        let uniqueID = await client.uniqueID
        let locationID = await client.locationID
        let isBuiltIn = await client.isBuiltIn
        let transport = await client.transport.map { String(describing: $0) }
        let fingerprint = DeviceFingerprint.make(
            serialNumber: serial,
            uniqueID: uniqueID,
            isBuiltIn: isBuiltIn,
            vendorID: vendorID,
            productID: productID,
            transport: transport,
            locationID: locationID
        )
        let name = isBuiltIn ? "MacBook 内置键盘" : (product?.nonEmpty ?? manufacturer?.nonEmpty ?? "外接键盘")
        let descriptor = DeviceDescriptor(
            observedFingerprint: fingerprint,
            suggestedName: name,
            manufacturer: manufacturer,
            product: product,
            vendorID: vendorID,
            productID: productID,
            transport: transport,
            isBuiltIn: isBuiltIn
        )

        let elements = await client.elements.filter { element in
            element.type == .input && (
                element.usage.page == HIDUsage.KeyboardOrKeypadUsage.page ||
                    element.usage.page == HIDUsage.ConsumerUsage.page
            )
        }

        // A detach or stop can cancel this task at any await, so re-check after each
        // one and keep everything from the registration result onward synchronous.
        guard !Task.isCancelled else { return }
        do {
            let canonicalID = try await engine.registerDevice(referenceID: referenceID, descriptor: descriptor)
            guard !Task.isCancelled, canonicalIDs[referenceID] == nil else { return }
            canonicalIDs[referenceID] = canonicalID
            descriptors[referenceID] = descriptor
            transitions[referenceID] = KeyTransitionCounter()
            if !elements.isEmpty {
                deviceTasks[referenceID] = Task { [weak self] in
                    await self?.observe(client: client, reference: reference, elements: elements)
                }
            }
            await deviceDirectoryDidChange?()
        } catch {
            state = .failed(error.localizedDescription)
            await stateDidChange?(state)
        }
    }

    private func observe(client: HIDDeviceClient, reference: HIDDeviceClient.DeviceReference, elements: [HIDElement]) async {
        do {
            for try await notification in await client.monitorNotifications(
                reportIDsToMonitor: [],
                elementsToMonitor: elements
            ) {
                guard !Task.isCancelled else { return }
                switch notification {
                case .elementUpdates(let values):
                    for value in values { await process(value, referenceID: reference.deviceID) }
                case .deviceRemoved:
                    await detach(referenceID: reference.deviceID)
                default:
                    break
                }
            }
        } catch {
            // Handled like a clean end: only this device is affected, never the global state.
        }
        guard !Task.isCancelled else { return }
        await detach(referenceID: reference.deviceID, retrying: reference)
    }

    private func process(_ value: HIDElement.Value, referenceID: UInt64) async {
        guard !isPaused, let deviceID = canonicalIDs[referenceID] else { return }
        let usage = value.element.usage
        guard usage.page == HIDUsage.KeyboardOrKeypadUsage.page || usage.page == HIDUsage.ConsumerUsage.page else { return }
        let rawValue = value.logicalValue(asTypeTruncatingIfNeeded: Int64.self) ?? value.integerValue(asTypeTruncatingIfNeeded: Int64.self)
        let key: HIDKeyID
        if let rawUsage = usage.usage {
            key = HIDKeyID(usagePage: usage.page, usage: rawUsage)
            guard key.isCountable else { return }
            guard transitions[referenceID]?.update(key: key, value: rawValue) == true else { return }
        } else {
            guard let arrayKey = transitions[referenceID]?.updateArray(
                slot: value.element.hashValue,
                usagePage: usage.page,
                value: rawValue
            ) else { return }
            key = arrayKey
        }

        if key.isConsumerKey {
            guard mediaDeduplicator.shouldCount(deviceID: deviceID, key: key) else { return }
        }
        await engine.record(referenceID: referenceID, key: key)
    }

    /// Forgets a device. With `retrying`, its stream ended on its own and attaching
    /// is retried after 1 s, 5 s and 30 s unless it is removed or monitoring stops.
    private func detach(referenceID: UInt64, retrying reference: HIDDeviceClient.DeviceReference? = nil) async {
        let deviceTask = deviceTasks.removeValue(forKey: referenceID)
        retryTasks.removeValue(forKey: referenceID)?.cancel()
        transitions.removeValue(forKey: referenceID)
        canonicalIDs.removeValue(forKey: referenceID)
        descriptors.removeValue(forKey: referenceID)
        if let reference {
            retryTasks[referenceID] = Task { [weak self] in
                for delay in [1, 5, 30] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    await self.attach(reference)
                    if await self.canonicalIDs[referenceID] != nil { return }
                }
            }
        }
        await engine.disconnect(referenceID: referenceID)
        await deviceDirectoryDidChange?()
        // Cancel last: this may be the device's own task, and a cancelled task would
        // make the directory refresh above fail with a cancellation error.
        deviceTask?.cancel()
    }

    /// The store dropped this device and its fingerprint alias, so a connected
    /// keyboard is registered again and counted as a new device.
    func deviceWasDeleted(_ id: UUID) async {
        for (referenceID, canonicalID) in canonicalIDs where canonicalID == id {
            guard let descriptor = descriptors[referenceID] else { continue }
            do {
                let newID = try await engine.registerDevice(referenceID: referenceID, descriptor: descriptor)
                if canonicalIDs[referenceID] == id { canonicalIDs[referenceID] = newID }
            } catch {
                state = .failed(error.localizedDescription)
                await stateDidChange?(state)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
