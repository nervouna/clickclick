import CoreHID
import Foundation

actor CoreHIDInputMonitor {
    private let manager = HIDDeviceManager()
    private let engine: StatisticsEngine
    private var monitorTask: Task<Void, Never>?
    private var deviceTasks: [UInt64: Task<Void, Never>] = [:]
    private var transitions: [UInt64: KeyTransitionCounter] = [:]
    private var canonicalIDs: [UInt64: UUID] = [:]
    private var mediaDeduplicator = MediaPressDeduplicator()
    private(set) var state: InputPermissionState = InputPermission.currentState()
    private(set) var isPaused = false

    init(engine: StatisticsEngine) {
        self.engine = engine
    }

    func refreshPermission() -> InputPermissionState {
        let permission = InputPermission.currentState()
        if case .granted = permission, monitorTask == nil {
            start()
        } else if permission != .granted {
            stopListening()
        }
        state = permission
        return state
    }

    func requestPermission() -> InputPermissionState {
        _ = InputPermission.request()
        return refreshPermission()
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

    func stop() {
        stopListening()
    }

    private func stopListening() {
        monitorTask?.cancel()
        monitorTask = nil
        for task in deviceTasks.values { task.cancel() }
        deviceTasks.removeAll()
        transitions.removeAll()
        canonicalIDs.removeAll()
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

        do {
            for try await notification in await manager.monitorNotifications(matchingCriteria: criteria) {
                guard !Task.isCancelled else { break }
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
            if !Task.isCancelled {
                state = .failed(error.localizedDescription)
                monitorTask = nil
            }
        }
    }

    private func attach(_ reference: HIDDeviceClient.DeviceReference) async {
        guard deviceTasks[reference.deviceID] == nil,
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

        do {
            let canonicalID = try await engine.registerDevice(referenceID: reference.deviceID, descriptor: descriptor)
            canonicalIDs[reference.deviceID] = canonicalID
            transitions[reference.deviceID] = KeyTransitionCounter()
            let elements = await client.elements.filter { element in
                element.type == .input && (
                    element.usage.page == HIDUsage.KeyboardOrKeypadUsage.page ||
                        element.usage.page == HIDUsage.ConsumerUsage.page
                )
            }
            guard !elements.isEmpty else { return }
            deviceTasks[reference.deviceID] = Task { [weak self] in
                await self?.observe(client: client, referenceID: reference.deviceID, elements: elements)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func observe(client: HIDDeviceClient, referenceID: UInt64, elements: [HIDElement]) async {
        do {
            for try await notification in await client.monitorNotifications(
                reportIDsToMonitor: [],
                elementsToMonitor: elements
            ) {
                guard !Task.isCancelled else { break }
                switch notification {
                case .elementUpdates(let values):
                    for value in values { await process(value, referenceID: referenceID) }
                case .deviceRemoved:
                    await detach(referenceID: referenceID)
                default:
                    break
                }
            }
        } catch {
            if !Task.isCancelled {
                state = .failed(error.localizedDescription)
            }
        }
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
        await engine.record(deviceID: deviceID, key: key)
    }

    private func detach(referenceID: UInt64) async {
        deviceTasks[referenceID]?.cancel()
        deviceTasks.removeValue(forKey: referenceID)
        transitions.removeValue(forKey: referenceID)
        canonicalIDs.removeValue(forKey: referenceID)
        await engine.disconnect(referenceID: referenceID)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
