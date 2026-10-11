/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * USB device discovery, ancestor port classification, and debounced change
 * grouping adapted from WhatCable (https://github.com/darrylmorley/whatcable)
 * under the MIT License.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Combine
import Defaults
import SwiftUI
import DiskArbitration
import Foundation
import IOKit
import IOKit.usb

// MARK: - USB Speed Classification

public enum USBDeviceSpeed: Equatable, Hashable, Sendable {
    case lowSpeed               // 0: 1.5 Mbps (USB 1.0/1.1)
    case fullSpeed              // 1: 12 Mbps (USB 1.1)
    case highSpeed              // 2: 480 Mbps (USB 2.0)
    case superSpeed             // 3: 5 Gbps (USB 3.0 / 3.1 Gen 1)
    case superSpeedPlus         // 4: 10 Gbps (USB 3.1 Gen 2)
    case superSpeedPlusGen2x2   // 5: 20 Gbps (USB 3.2 Gen 2x2)
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .lowSpeed
        case 1: self = .fullSpeed
        case 2: self = .highSpeed
        case 3: self = .superSpeed
        case 4: self = .superSpeedPlus
        case 5: self = .superSpeedPlusGen2x2
        default: self = .unknown(rawValue)
        }
    }

    public var shortLabel: String {
        switch self {
        case .lowSpeed: return "1.5 Mbps"
        case .fullSpeed: return "12 Mbps"
        case .highSpeed: return "480 Mbps"
        case .superSpeed: return "5 Gbps"
        case .superSpeedPlus: return "10 Gbps"
        case .superSpeedPlusGen2x2: return "20 Gbps"
        case .unknown(let raw): return "Speed \(raw)"
        }
    }

    public var generationLabel: String {
        switch self {
        case .lowSpeed: return "USB 1.1 Low-Speed"
        case .fullSpeed: return "USB 1.1 Full-Speed"
        case .highSpeed: return "USB 2.0"
        case .superSpeed: return "USB 3.0"
        case .superSpeedPlus: return "USB 3.1 Gen 2"
        case .superSpeedPlusGen2x2: return "USB 3.2 Gen 2×2"
        case .unknown: return "USB"
        }
    }

    public var isSuperSpeedOrFaster: Bool {
        switch self {
        case .superSpeed, .superSpeedPlus, .superSpeedPlusGen2x2:
            return true
        default:
            return false
        }
    }
}

// MARK: - Mounted USB Storage Volume

public struct USBMountedVolume: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let totalCapacityBytes: Int64?
    public let availableCapacityBytes: Int64?
    public let bsdName: String?

    public var capacitySummary: String? {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        if let avail = availableCapacityBytes, let total = totalCapacityBytes, total > 0 {
            return "\(formatter.string(fromByteCount: avail)) free of \(formatter.string(fromByteCount: total))"
        } else if let total = totalCapacityBytes, total > 0 {
            return formatter.string(fromByteCount: total)
        }
        return nil
    }

    public var usageFraction: Double? {
        guard let total = totalCapacityBytes, total > 0,
              let avail = availableCapacityBytes else { return nil }
        let used = max(0, total - avail)
        return min(max(Double(used) / Double(total), 0), 1)
    }
}

// MARK: - USB Device Model

public struct USBDeviceItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: UInt64
    public let locationID: UInt32
    public let vendorID: UInt16
    public let productID: UInt16
    public let vendorName: String?
    public let productName: String
    public let serialNumber: String?
    public let usbVersion: String?
    public let speed: USBDeviceSpeed?
    public let busPowerMA: Int?
    public let currentMA: Int?
    public let portName: String?
    public let isThunderboltTunnelled: Bool
    public let isHub: Bool
    public let isBillboard: Bool
    public let isBuiltIn: Bool
    public let deviceClass: UInt8?
    public let interfaceClasses: Set<UInt8>
    public var mountedVolumes: [USBMountedVolume]

    public var resolvedVendorName: String? {
        if let vendorName, !vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return USBKnownVendors.name(for: vendorID)
    }

    public var vendorProductHex: String {
        String(format: "0x%04X : 0x%04X", vendorID, productID)
    }

    public var powerSummaryText: String? {
        if let currentMA, currentMA > 0 {
            if currentMA >= 1000 {
                let watts = Double(currentMA) * 5.0 / 1000.0
                return String(format: "%d mA (~%.1fW)", currentMA, watts)
            }
            return "\(currentMA) mA"
        }
        if let busPowerMA, busPowerMA > 0 {
            return "Max \(busPowerMA) mA"
        }
        return nil
    }

    public var hasMountedStorage: Bool {
        !mountedVolumes.isEmpty
    }

    /// USB `locationID` encodes the bus in its top byte (`0xBB000000`) and up to
    /// six hub port hops in the remaining nibbles (`0x00DDDDDD`). Removing the
    /// deepest non-zero nibble yields the parent hub's `locationID`.
    public var parentLocationID: UInt32? {
        let portNibbles = locationID & 0x00FF_FFFF
        guard portNibbles != 0 else { return nil }
        for shift in stride(from: 0, through: 20, by: 4) {
            let mask = UInt32(0xF) << shift
            if (locationID & mask) != 0 {
                let parent = locationID & ~mask
                return (parent & 0x00FF_FFFF) != 0 ? parent : nil
            }
        }
        return nil
    }

    public var sfSymbol: String {
        if !mountedVolumes.isEmpty || interfaceClasses.contains(0x08) || deviceClass == 0x08 {
            return "externaldrive.fill"
        }
        let lowerName = productName.lowercased()
        if lowerName.contains("iphone") {
            return "iphone"
        }
        if lowerName.contains("ipad") {
            return "ipad"
        }
        if lowerName.contains("ipod") {
            return "ipod"
        }
        if lowerName.contains("watch") && vendorID == 0x05AC {
            return "applewatch"
        }
        if lowerName.contains("airpods") {
            return "airpodspro"
        }
        if lowerName.contains("sd card") || lowerName.contains("card reader") {
            return "sdcard.fill"
        }
        if lowerName.contains("camera") || lowerName.contains("webcam") || lowerName.contains("camlink") || interfaceClasses.contains(0x0E) {
            return "web.camera.fill"
        }
        if lowerName.contains("mic") || lowerName.contains("yeti") || lowerName.contains("shure") || lowerName.contains("rode") || lowerName.contains("røde") || lowerName.contains("wave:") {
            return "mic.fill"
        }
        if lowerName.contains("headset") || lowerName.contains("headphone") || lowerName.contains("dac") || lowerName.contains("audio") || interfaceClasses.contains(0x01) {
            return "headphones"
        }
        if lowerName.contains("keyboard") || lowerName.contains("keychron") || lowerName.contains("nuphy") || lowerName.contains("hhkb") {
            return "keyboard.fill"
        }
        if lowerName.contains("mouse") || lowerName.contains("trackpad") || lowerName.contains("deathadder") || lowerName.contains("viper") || lowerName.contains("mx master") {
            return "computermouse.fill"
        }
        if lowerName.contains("controller") || lowerName.contains("gamepad") || lowerName.contains("dualshock") || lowerName.contains("dualsense") || lowerName.contains("xbox") {
            return "gamecontroller.fill"
        }
        if lowerName.contains("ethernet") || lowerName.contains("lan") || interfaceClasses.contains(0x02) || interfaceClasses.contains(0x0A) {
            return "network"
        }
        if lowerName.contains("printer") || interfaceClasses.contains(0x07) {
            return "printer.fill"
        }
        if lowerName.contains("yubikey") || lowerName.contains("security key") || interfaceClasses.contains(0x0B) {
            return "key.horizontal.fill"
        }
        if isHub {
            return "point.3.connected.trianglepath.dotted"
        }
        if interfaceClasses.contains(0x03) {
            return "keyboard"
        }
        return "cable.connector.horizontal"
    }
}

// MARK: - HUD State

public enum USBHUDState: Equatable {
    case hidden
    case connected(deviceName: String, subtitle: String, symbolName: String, extraCount: Int)
    case disconnected(deviceName: String, subtitle: String, symbolName: String, extraCount: Int)

    public var isVisible: Bool {
        self != .hidden
    }

    public var isConnectedEvent: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - USB Device Manager

@MainActor
final class USBDeviceManager: ObservableObject {
    static let shared = USBDeviceManager()

    @Published private(set) var allDevices: [USBDeviceItem] = []
    @Published private(set) var hudState: USBHUDState = .hidden
    @Published private(set) var ejectingDeviceIDs: Set<UInt64> = []
    @Published var lastEjectError: String?
    @Published var showHubsOverride: Bool = false

    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private var hasStarted = false
    private var hasCompletedInitialEnumeration = false
    private var knownDevicesByID: [UInt64: USBDeviceItem] = [:]
    private var deviceSettleTask: Task<Void, Never>?
    private var volumeRefreshTask: Task<Void, Never>?
    private var hudHideWorkItem: DispatchWorkItem?

    /// Settle window to group composite USB devices and hub subtrees that
    /// enumerate or terminate across multiple IOKit callbacks (same approach as WhatCable).
    private let settleWindowSeconds: TimeInterval = 0.35
    private let hudDisplayDuration: TimeInterval = 2.8

    private init() {
        Defaults.publisher(.enableUSBDeviceFeature, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                if change.newValue {
                    self.startMonitoring()
                } else {
                    self.stopMonitoring()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Filtered Views

    /// External devices (excluding built-in internal controllers).
    var externalDevices: [USBDeviceItem] {
        allDevices.filter { !$0.isBuiltIn && !$0.isBillboard }
    }

    /// Number of connected USB hubs currently hidden by the hub filter.
    var hiddenHubCount: Int {
        guard Defaults[.hideUSBHubsAndInternal] && !showHubsOverride else { return 0 }
        let nonBuiltIn = externalDevices
        let hubs = nonBuiltIn.filter(\.isHub)
        // Only count hubs that actually get hidden
        let endpoints = nonBuiltIn.filter { !$0.isHub }
        if endpoints.isEmpty {
            return 0 // When only hubs are connected, we still show them so the list isn't mysteriously blank
        }
        return hubs.count
    }

    /// Devices presented in the Popover and Notch Tab.
    var displayedDevices: [USBDeviceItem] {
        let candidates = externalDevices
        guard Defaults[.hideUSBHubsAndInternal] && !showHubsOverride else {
            return candidates
        }
        let endpoints = candidates.filter { !$0.isHub }
        // Mirror WhatCable's HubDisplay.endpointsOnly rule: if only a hub is
        // plugged in with no non-hub children yet, show the hub so it doesn't
        // vanish without explanation.
        return endpoints.isEmpty ? candidates : endpoints
    }

    // MARK: - Lifecycle

    func startMonitoring() {
        guard Defaults[.enableUSBDeviceFeature] else { return }
        guard !hasStarted else { return }
        hasStarted = true
        hasCompletedInitialEnumeration = false

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let addedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let manager = Unmanaged<USBDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak manager] in
                manager?.handleAdded(iterator: iterator)
            }
        }

        let removedCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let manager = Unmanaged<USBDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak manager] in
                manager?.handleRemoved(iterator: iterator)
            }
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            addedCallback,
            selfPtr,
            &addedIter
        ) == KERN_SUCCESS {
            handleAdded(iterator: addedIter, isInitialSeed: true)
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            removedCallback,
            selfPtr,
            &removedIter
        ) == KERN_SUCCESS {
            handleRemoved(iterator: removedIter, isInitialSeed: true)
        }

        setupVolumeObservers()
        refreshMountedVolumes()

        // Seed baseline snapshot so existing devices don't trigger a plug HUD on app launch.
        knownDevicesByID = Dictionary(uniqueKeysWithValues: allDevices.map { ($0.id, $0) })
        hasCompletedInitialEnumeration = true
    }

    func stopMonitoring() {
        guard hasStarted else { return }
        hasStarted = false
        hasCompletedInitialEnumeration = false

        deviceSettleTask?.cancel()
        deviceSettleTask = nil
        volumeRefreshTask?.cancel()
        volumeRefreshTask = nil
        hudHideWorkItem?.cancel()
        hudHideWorkItem = nil
        hudState = .hidden

        if addedIter != 0 {
            IOObjectRelease(addedIter)
            addedIter = 0
        }
        if removedIter != 0 {
            IOObjectRelease(removedIter)
            removedIter = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        allDevices.removeAll()
        knownDevicesByID.removeAll()
    }

    /// Re-enumerates connected USB devices and mounted volumes in place without
    /// tearing down IOKit notifications (same safe re-enumeration rule as WhatCable).
    func refreshDevices() {
        guard hasStarted else {
            startMonitoring()
            return
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        let volumeMap = Self.discoverUSBMountedVolumes()
        let rebuilt = Self.drainIteratorRetrying(iterator) { service in
            Self.makeDevice(from: service, volumeMap: volumeMap)
        }.compactMap { $0 }

        allDevices = Self.sortedDevices(rebuilt)
        knownDevicesByID = Dictionary(uniqueKeysWithValues: allDevices.map { ($0.id, $0) })
    }

    // MARK: - Eject & Finder Actions

    func openVolumeInFinder(_ volume: USBMountedVolume) {
        NSWorkspace.shared.open(volume.url)
    }

    func ejectDevice(_ device: USBDeviceItem) {
        guard !device.mountedVolumes.isEmpty else { return }
        guard !ejectingDeviceIDs.contains(device.id) else { return }

        ejectingDeviceIDs.insert(device.id)
        lastEjectError = nil
        let volumes = device.mountedVolumes
        let deviceID = device.id
        let deviceName = device.productName

        Task.detached(priority: .userInitiated) {
            var firstError: Error?
            for volume in volumes {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                } catch {
                    firstError = error
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ejectingDeviceIDs.remove(deviceID)
                self.refreshMountedVolumes()
                if let firstError {
                    self.lastEjectError = "Could not eject \(deviceName): \(firstError.localizedDescription)"
                } else {
                    self.playFeedbackIfNeeded(connected: false)
                }
            }
        }
    }

    // MARK: - Test HUD Presentation

    func presentTestHUD(connected: Bool) {
        let sampleDevice = displayedDevices.first
        let name = sampleDevice?.productName ?? "SanDisk Extreme SSD"
        let symbol = sampleDevice?.sfSymbol ?? "externaldrive.fill"
        let subtitle: String
        if connected {
            let speed = sampleDevice?.speed?.shortLabel ?? "10 Gbps"
            subtitle = "USB Connected • \(speed)"
        } else {
            subtitle = "USB Disconnected"
        }

        presentHUD(
            state: connected
                ? .connected(deviceName: name, subtitle: subtitle, symbolName: symbol, extraCount: 0)
                : .disconnected(deviceName: name, subtitle: subtitle, symbolName: symbol, extraCount: 0)
        )
        playFeedbackIfNeeded(connected: connected)
    }

    // MARK: - IOKit Notification Handlers

    private func handleAdded(iterator: io_iterator_t, isInitialSeed: Bool = false) {
        let volumeMap = isInitialSeed ? [:] : Self.discoverUSBMountedVolumes()
        let found = Self.drainIteratorRetrying(iterator) { service in
            Self.makeDevice(from: service, volumeMap: volumeMap)
        }

        var didChange = false
        for device in found {
            guard let device else { continue }
            if let existingIdx = allDevices.firstIndex(where: { $0.id == device.id }) {
                allDevices[existingIdx] = device
                didChange = true
            } else {
                allDevices.append(device)
                didChange = true
            }
        }

        if didChange {
            allDevices = Self.sortedDevices(allDevices)
        }

        guard !isInitialSeed && hasCompletedInitialEnumeration else { return }
        scheduleDeviceDiffSettle()
        scheduleDelayedVolumeRefresh()
    }

    private func handleRemoved(iterator: io_iterator_t, isInitialSeed: Bool = false) {
        let removedIDs = Self.drainIteratorRetrying(iterator) { service -> UInt64? in
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
                return nil
            }
            return entryID
        }

        var didRemove = false
        for entryID in removedIDs {
            guard let entryID else { continue }
            let beforeCount = allDevices.count
            allDevices.removeAll { $0.id == entryID }
            if allDevices.count != beforeCount {
                didRemove = true
            }
        }

        guard !isInitialSeed && hasCompletedInitialEnumeration && didRemove else { return }
        scheduleDeviceDiffSettle()
    }

    // MARK: - Debounced Settle & Subtree Grouping

    private func scheduleDeviceDiffSettle() {
        deviceSettleTask?.cancel()
        let delay = settleWindowSeconds
        deviceSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.evaluateSettledDeviceChanges()
        }
    }

    private func evaluateSettledDeviceChanges() {
        let currentByID = Dictionary(uniqueKeysWithValues: allDevices.map { ($0.id, $0) })
        let previousByID = knownDevicesByID
        knownDevicesByID = currentByID

        let addedIDs = Set(currentByID.keys).subtracting(previousByID.keys)
        let removedIDs = Set(previousByID.keys).subtracting(currentByID.keys)

        let addedDevices = addedIDs.compactMap { currentByID[$0] }
            .filter { !$0.isBuiltIn && !$0.isBillboard }
        let removedDevices = removedIDs.compactMap { previousByID[$0] }
            .filter { !$0.isBuiltIn && !$0.isBillboard }

        guard Defaults[.enableUSBDeviceFeature] else { return }

        if !addedDevices.isEmpty {
            if let summary = Self.summarizeDeviceBatch(addedDevices, isConnected: true) {
                if Defaults[.showUSBConnectionHUD] {
                    presentHUD(state: summary)
                }
                playFeedbackIfNeeded(connected: true)
            }
        } else if !removedDevices.isEmpty {
            if let summary = Self.summarizeDeviceBatch(removedDevices, isConnected: false) {
                if Defaults[.showUSBConnectionHUD] {
                    presentHUD(state: summary)
                }
                playFeedbackIfNeeded(connected: false)
            }
        }
    }

    /// Picks the primary device from a settled plug/unplug batch so plugging in a
    /// hub or dock with internal USB2/USB3 companions produces a single crisp HUD
    /// instead of multiple rapid-fire notifications.
    private static func summarizeDeviceBatch(_ batch: [USBDeviceItem], isConnected: Bool) -> USBHUDState? {
        guard !batch.isEmpty else { return nil }

        let endpoints = batch.filter { !$0.isHub }
        let candidates = endpoints.isEmpty ? batch : endpoints

        // Sort so storage drives or high-speed devices win the headline slot
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.hasMountedStorage != rhs.hasMountedStorage {
                return lhs.hasMountedStorage
            }
            let lhsSpeed = lhs.speed?.isSuperSpeedOrFaster ?? false
            let rhsSpeed = rhs.speed?.isSuperSpeedOrFaster ?? false
            if lhsSpeed != rhsSpeed {
                return lhsSpeed
            }
            return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
        }

        guard let primary = sorted.first else { return nil }
        let extraCount = max(0, candidates.count - 1)

        if isConnected {
            let subtitle: String
            if let speedLabel = primary.speed?.shortLabel {
                subtitle = "USB Connected • \(speedLabel)"
            } else {
                subtitle = "USB Connected"
            }
            return .connected(
                deviceName: primary.productName,
                subtitle: subtitle,
                symbolName: primary.sfSymbol,
                extraCount: extraCount
            )
        } else {
            return .disconnected(
                deviceName: primary.productName,
                subtitle: "USB Disconnected",
                symbolName: primary.sfSymbol,
                extraCount: extraCount
            )
        }
    }

    private func presentHUD(state: USBHUDState) {
        hudHideWorkItem?.cancel()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            hudState = state
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                self.hudState = .hidden
            }
        }
        hudHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hudDisplayDuration, execute: workItem)
    }

    private func playFeedbackIfNeeded(connected: Bool) {
        if Defaults[.enableUSBConnectionHaptics] && Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(
                connected ? .alignment : .levelChange,
                performanceTime: .default
            )
        }

        if Defaults[.playUSBConnectionSound] {
            let soundName = connected ? "Tink" : "Pop"
            NSSound(named: NSSound.Name(soundName))?.play()
        }
    }

    // MARK: - Volume Mount / Unmount Tracking

    private func setupVolumeObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        let notifications: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]

        for name in notifications {
            let token = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshMountedVolumes()
                }
            }
            workspaceObservers.append(token)
        }
    }

    private func scheduleDelayedVolumeRefresh() {
        volumeRefreshTask?.cancel()
        volumeRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled, let self else { return }
            self.refreshMountedVolumes()
        }
    }

    func refreshMountedVolumes() {
        let volumeMap = Self.discoverUSBMountedVolumes()
        var updated = allDevices
        var changed = false

        for idx in updated.indices {
            let device = updated[idx]
            let matched = volumeMap[device.id] ?? []
            if updated[idx].mountedVolumes != matched {
                updated[idx].mountedVolumes = matched
                changed = true
            }
        }

        if changed {
            allDevices = Self.sortedDevices(updated)
        }
    }

    /// Maps IOKit `IOUSBHostDevice` registry entry IDs to mounted Finder volumes
    /// by resolving each mounted volume's `DADisk` to its `IOMedia` service and
    /// walking up `kIOServicePlane` to its parent `IOUSBHostDevice`.
    nonisolated private static func discoverUSBMountedVolumes() -> [UInt64: [USBMountedVolume]] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ),
        let session = DASessionCreate(kCFAllocatorDefault) else {
            return [:]
        }

        var result: [UInt64: [USBMountedVolume]] = [:]

        for url in urls {
            guard url.path != "/" else { continue }
            guard let daDisk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
                continue
            }

            let mediaService = DADiskCopyIOMedia(daDisk)
            guard mediaService != 0 else { continue }
            defer { IOObjectRelease(mediaService) }

            guard let usbEntryID = findAncestorUSBDeviceEntryID(from: mediaService) else {
                continue
            }

            let resourceValues = try? url.resourceValues(forKeys: Set(keys))
            let volumeName = resourceValues?.volumeName ?? url.lastPathComponent
            let totalBytes = resourceValues?.volumeTotalCapacity.map { Int64($0) }
            let availBytes = resourceValues?.volumeAvailableCapacity.map { Int64($0) }
            let bsdName = DADiskGetBSDName(daDisk).map { String(cString: $0) }

            let mounted = USBMountedVolume(
                url: url,
                name: volumeName,
                totalCapacityBytes: totalBytes,
                availableCapacityBytes: availBytes,
                bsdName: bsdName
            )
            result[usbEntryID, default: []].append(mounted)
        }

        return result
    }

    nonisolated private static func findAncestorUSBDeviceEntryID(from startService: io_service_t) -> UInt64? {
        var current: io_registry_entry_t = startService
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<24 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return nil
            }
            IOObjectRelease(current)
            current = parent

            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                var entryID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(current, &entryID) == KERN_SUCCESS {
                    return entryID
                }
            }
        }
        return nil
    }

    // MARK: - IOKit Device Construction (Adapted from WhatCable)

    nonisolated private static func makeDevice(
        from service: io_service_t,
        volumeMap: [UInt64: [USBMountedVolume]]
    ) -> USBDeviceItem? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            return nil
        }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let vendorID = (dict["idVendor"] as? NSNumber)?.uint16Value ?? 0
        let productID = (dict["idProduct"] as? NSNumber)?.uint16Value ?? 0
        let locationID = (dict["locationID"] as? NSNumber)?.uint32Value ?? 0

        // Root hub simulation nodes have locationID without port nibbles or vendorID == 0
        if vendorID == 0 && productID == 0 {
            return nil
        }

        let rawVendor = (dict["USB Vendor Name"] as? String)
            ?? (dict["kUSBVendorString"] as? String)
        let rawProduct = (dict["USB Product Name"] as? String)
            ?? (dict["kUSBProductString"] as? String)
            ?? di_getIOName(service)
            ?? "USB Device"
        let productName = rawProduct.trimmingCharacters(in: .whitespacesAndNewlines)
        let serialNumber = ((dict["USB Serial Number"] as? String)
            ?? (dict["kUSBSerialNumberString"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let speedRaw = (dict["Device Speed"] as? NSNumber)?.uint8Value
        let bcdUSB = (dict["bcdUSB"] as? NSNumber)?.uint16Value
        let busPower = (dict["Bus Power Available"] as? NSNumber).map { $0.intValue * 2 }
        let requestedPower = (dict["Requested Power"] as? NSNumber).map { $0.intValue * 2 }
            ?? (dict["PortCurrentAllocation"] as? NSNumber).map { $0.intValue }
        let deviceClass = (dict["bDeviceClass"] as? NSNumber)?.uint8Value

        var classBuf = [CChar](repeating: 0, count: 128)
        let ioClassName = IOObjectGetClass(service, &classBuf) == KERN_SUCCESS
            ? String(cString: classBuf)
            : nil

        let interfaceClasses = collectInterfaceClasses(under: service)
        let (portName, isThunderboltTunnelled, hasInternalParent) = classifyPortAncestry(for: service)

        let builtInFlag = (dict["Built-In"] as? NSNumber)?.boolValue ?? false
        let nonRemovableFlag = (dict["non-removable"] as? NSNumber)?.boolValue ?? false
        let isInternalAppleDevice = vendorID == 0x05AC && (
            productName.localizedCaseInsensitiveContains("Internal")
            || productName.localizedCaseInsensitiveContains("Root Hub")
            || productName.localizedCaseInsensitiveContains("XHCI")
            || productName.localizedCaseInsensitiveContains("T2 Bus")
            || productName.localizedCaseInsensitiveContains("Ambient Light")
            || productName.localizedCaseInsensitiveContains("Touch Bar")
            || productName.localizedCaseInsensitiveContains("FaceTime")
            || productName.localizedCaseInsensitiveContains("Headset") && builtInFlag
        )
        let isBuiltIn = builtInFlag || nonRemovableFlag || isInternalAppleDevice || hasInternalParent

        let isBillboard = deviceClass == 0x11
            || ioClassName == "AppleUSBHostBillboardDevice"
            || productName.localizedCaseInsensitiveContains("Billboard")

        let isHub = deviceClass == 0x09
            || interfaceClasses.contains(0x09)
            || (ioClassName?.localizedCaseInsensitiveContains("Hub") ?? false)
            || (productName.localizedCaseInsensitiveContains("Hub") && !interfaceClasses.contains(0x08))

        return USBDeviceItem(
            id: entryID,
            locationID: locationID,
            vendorID: vendorID,
            productID: productID,
            vendorName: rawVendor,
            productName: productName.isEmpty ? "USB Device" : productName,
            serialNumber: (serialNumber?.isEmpty == false) ? serialNumber : nil,
            usbVersion: bcdUSB.map { formatBCD($0) },
            speed: speedRaw.map { USBDeviceSpeed(rawValue: $0) },
            busPowerMA: busPower,
            currentMA: requestedPower,
            portName: portName,
            isThunderboltTunnelled: isThunderboltTunnelled,
            isHub: isHub,
            isBillboard: isBillboard,
            isBuiltIn: isBuiltIn,
            deviceClass: deviceClass,
            interfaceClasses: interfaceClasses,
            mountedVolumes: volumeMap[entryID] ?? []
        )
    }

    nonisolated private static func collectInterfaceClasses(under deviceService: io_service_t) -> Set<UInt8> {
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(childIter) }

        var classes = Set<UInt8>()
        var child = IOIteratorNext(childIter)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(childIter)
            }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               let prop = IORegistryEntryCreateCFProperty(child, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                classes.insert(prop.uint8Value)
            }
        }
        return classes
    }

    nonisolated private static func classifyPortAncestry(
        for service: io_service_t
    ) -> (portName: String?, isThunderboltTunnelled: Bool, hasInternalParent: Bool) {
        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        var portName: String?
        var isThunderboltTunnelled = false
        var hasInternalParent = false

        for _ in 0..<18 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent

            var classBuf = [CChar](repeating: 0, count: 128)
            let className = IOObjectGetClass(current, &classBuf) == KERN_SUCCESS
                ? String(cString: classBuf)
                : ""

            if className == "AppleUSBXHCITR" || className.hasPrefix("AppleUSBXHCIFL") || className.hasPrefix("AppleASMediaUSBXHCI") {
                isThunderboltTunnelled = true
            }

            if let ioPort = IORegistryEntryCreateCFProperty(current, "UsbIOPort" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                portName = humanizePortName(ioPort)
            } else if portName == nil, let name = di_getIOName(current), name.hasPrefix("Port-USB-C@") {
                portName = humanizePortName(name)
            }

            if let builtIn = IORegistryEntryCreateCFProperty(current, "Built-In" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
               builtIn,
               className.contains("USBHub") {
                // Only mark internal if the hub itself is marked non-removable
                if let nonRemovable = IORegistryEntryCreateCFProperty(current, "non-removable" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
                   nonRemovable {
                    hasInternalParent = true
                }
            }
        }

        if portName == nil && isThunderboltTunnelled {
            portName = "Thunderbolt"
        }

        return (portName, isThunderboltTunnelled, hasInternalParent)
    }

    nonisolated private static func humanizePortName(_ raw: String) -> String {
        if let atRange = raw.range(of: "@") {
            let indexStr = String(raw[atRange.upperBound...])
            if raw.localizedCaseInsensitiveContains("USB-C") {
                return "USB-C Port \(indexStr)"
            }
            return "Port \(indexStr)"
        }
        return raw
    }

    nonisolated private static func formatBCD(_ bcd: UInt16) -> String {
        let major = (bcd >> 8) & 0xFF
        let minor = (bcd >> 4) & 0x0F
        let sub = bcd & 0x0F
        if sub == 0 {
            return String(format: "%X.%X", major, minor)
        }
        return String(format: "%X.%X%X", major, minor, sub)
    }

    nonisolated private static func sortedDevices(_ devices: [USBDeviceItem]) -> [USBDeviceItem] {
        devices.sorted { lhs, rhs in
            if lhs.isHub != rhs.isHub {
                return !lhs.isHub
            }
            if lhs.hasMountedStorage != rhs.hasMountedStorage {
                return lhs.hasMountedStorage
            }
            return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
        }
    }

    /// Safe retry iterator drain adapted from WhatCable's `wcDrainAllRetrying`.
    nonisolated private static func drainIteratorRetrying<T>(
        _ iterator: io_iterator_t,
        maxAttempts: Int = 3,
        transform: (io_service_t) -> T
    ) -> [T] {
        var attempt = 0
        while true {
            attempt += 1
            var results: [T] = []
            var sawAny = false
            var next = IOIteratorNext(iterator)
            while next != 0 {
                sawAny = true
                results.append(transform(next))
                IOObjectRelease(next)
                next = IOIteratorNext(iterator)
            }
            let invalidatedMidWalk = sawAny && IOIteratorIsValid(iterator) == 0
            if !invalidatedMidWalk || attempt >= maxAttempts {
                return results
            }
            IOIteratorReset(iterator)
        }
    }
}

// MARK: - Well-Known USB Vendor IDs Fallback

private enum USBKnownVendors {
    static func name(for vendorID: UInt16) -> String? {
        table[vendorID]
    }

    private static let table: [UInt16: String] = [
        0x05AC: "Apple",
        0x04E8: "Samsung",
        0x0781: "SanDisk",
        0x1058: "Western Digital",
        0x0BC2: "Seagate",
        0x0951: "Kingston",
        0x0634: "Crucial / Micron",
        0x054C: "Sony",
        0x046D: "Logitech",
        0x1532: "Razer",
        0x1B1C: "Corsair",
        0x3434: "Keychron",
        0x2188: "CalDigit",
        0x291A: "Anker",
        0x050D: "Belkin",
        0x2B89: "UGREEN",
        0x0BDA: "Realtek",
        0x2109: "VIA Labs",
        0x05E3: "Genesys Logic",
        0x174C: "ASMedia",
        0x0FD9: "Elgato",
        0x0B0E: "Jabra",
        0x1235: "Focusrite",
        0x19F7: "RØDE",
        0x14ED: "Shure",
        0x1050: "Yubico",
        0x056A: "Wacom",
        0x04A9: "Canon",
        0x04B8: "Epson",
        0x03F0: "HP",
        0x413C: "Dell",
        0x043E: "LG Electronics",
        0x045E: "Microsoft",
        0x057E: "Nintendo",
        0x18D1: "Google",
        0x091E: "Garmin",
        0x2E8A: "Raspberry Pi",
        0x2341: "Arduino",
        0x1A86: "QinHeng Electronics",
        0x10C4: "Silicon Labs",
        0x0403: "FTDI"
    ]
}

