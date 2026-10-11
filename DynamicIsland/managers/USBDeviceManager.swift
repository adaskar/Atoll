/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * USB device discovery, companion hub unification, physical USB-C port & HPM
 * transport inspection, DisplayPort/HDMI Alt-Mode detection, CoreGraphics live
 * display mode enrichment, and debounced change grouping adapted from WhatCable
 * (https://github.com/darrylmorley/whatcable) under the MIT License.
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
import CoreGraphics
import Defaults
import DiskArbitration
import Foundation
import IOKit
import IOKit.usb
import SwiftUI

// MARK: - USB Speed Classification

public enum USBDeviceSpeed: Equatable, Hashable, Sendable {
    case lowSpeed               // 0: 1.5 Mbps (USB 1.0/1.1)
    case fullSpeed              // 1: 12 Mbps (USB 1.1)
    case highSpeed              // 2: 480 Mbps (USB 2.0)
    case superSpeed             // 3: 5 Gbps (USB 3.0 / 3.1 Gen 1 / 3.2 Gen 1)
    case superSpeedPlus         // 4: 10 Gbps (USB 3.1 Gen 2 / 3.2 Gen 2)
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

    public var rawRank: UInt8 {
        switch self {
        case .lowSpeed: return 0
        case .fullSpeed: return 1
        case .highSpeed: return 2
        case .superSpeed: return 3
        case .superSpeedPlus: return 4
        case .superSpeedPlusGen2x2: return 5
        case .unknown(let raw): return raw
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
        case .highSpeed: return "USB 2.0 High-Speed"
        case .superSpeed: return "USB 3.1 / 3.2 Gen 1"
        case .superSpeedPlus: return "USB 3.1 / 3.2 Gen 2"
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

// MARK: - Connected USB / DisplayPort / HDMI Device Model

public struct USBDeviceItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: UInt64
    public let locationID: UInt32
    public var companionLocationIDs: [UInt32] = []
    public let vendorID: UInt16
    public let productID: UInt16
    public let vendorName: String?
    public let productName: String
    public let serialNumber: String?
    public let usbVersion: String?
    public let firmwareVersion: String?
    public let speed: USBDeviceSpeed?
    public let busPowerMA: Int?
    public let currentMA: Int?
    public var portName: String?
    public var busIndex: Int?
    public let isThunderboltTunnelled: Bool
    public let isHub: Bool
    public let isBillboard: Bool
    public let isBuiltIn: Bool
    public var isDisplayConnection: Bool = false
    public let deviceClass: UInt8?
    public let interfaceClasses: Set<UInt8>
    public var mountedVolumes: [USBMountedVolume]

    // WhatCable-inspired enriched topology & transport metadata
    public var containerID: String?
    public var driverName: String?
    public var activeProcessName: String?
    public var companionHubSummary: String?
    public var parentHubID: UInt64?
    public var parentHubName: String?
    public var hubPortNumber: Int?
    public var childDeviceIDs: [UInt64] = []
    public var connectedChildren: [String] = []
    public var portTransportsSummary: String?
    public var usbPDControllerSummary: String?
    public var videoOutputSummary: String?
    public var hasHDMIOutput: Bool = false
    public var hasDisplayPortOutput: Bool = false
    public var billboardSummary: String?

    // DisplayPort / HDMI Alt-Mode specific fields
    public var displayConnectionType: String?       // e.g. "HDMI (USB-C DP Alt Mode)" or "DisplayPort"
    public var displayShortProtocol: String?        // e.g. "HDMI" or "DisplayPort"
    public var displayRateBadge: String?            // e.g. "8.1 Gbps"
    public var displayLinkDescription: String?      // e.g. "8.1 Gbps (HBR3) • 2/2 lanes"
    public var displayResolutionSummary: String?    // e.g. "3840×2160 @ 60 Hz"
    public var displayMaxModeSummary: String?       // e.g. "3840×2160 @ 60 Hz"
    public var displayManufactureDate: String?      // e.g. "2022 (Week 51)"

    public var resolvedVendorName: String? {
        if let vendorName, !vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if isDisplayConnection {
            return nil
        }
        return USBKnownVendors.name(for: vendorID)
    }

    public var vendorProductHex: String {
        if isDisplayConnection && vendorID == 0 {
            return String(format: "PID 0x%04X (%d)", productID, productID)
        }
        return String(format: "0x%04X : 0x%04X", vendorID, productID)
    }

    /// Primary speed or link-rate badge shown on the right side of the device card.
    public var primarySpeedBadge: String? {
        if isDisplayConnection {
            return displayRateBadge ?? displayShortProtocol
        }
        return speed?.shortLabel
    }

    public var isHighBandwidthBadge: Bool {
        if isDisplayConnection {
            return true
        }
        return speed?.isSuperSpeedOrFaster == true
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

    /// Short port/protocol tag describing how this device attaches to its parent hub (e.g. "HDMI", "Port 2", "Port 3").
    public var hubPortBadge: String? {
        if isDisplayConnection {
            return displayShortProtocol ?? "Display"
        }
        if let hubPortNumber {
            return "Port \(hubPortNumber)"
        }
        return nil
    }

    public var parentRouteSummary: String? {
        guard let parentHubName else { return nil }
        if let badge = hubPortBadge {
            return "via \(parentHubName) (\(badge))"
        }
        return "via \(parentHubName)"
    }

    public var hasMountedStorage: Bool {
        !mountedVolumes.isEmpty
    }

    /// USB `locationID` encodes the bus in its top byte (`0xBB000000`) and up to
    /// six hub port hops in the remaining nibbles (`0x00DDDDDD`). Removing the
    /// deepest non-zero nibble yields the parent hub's `locationID`.
    public var parentLocationID: UInt32? {
        Self.computeParentLocationID(locationID)
    }

    public static func computeParentLocationID(_ locID: UInt32) -> UInt32? {
        let portNibbles = locID & 0x00FF_FFFF
        guard portNibbles != 0 else { return nil }
        for shift in stride(from: 0, through: 20, by: 4) {
            let mask = UInt32(0xF) << shift
            if (locID & mask) != 0 {
                let parent = locID & ~mask
                return (parent & 0x00FF_FFFF) != 0 ? parent : nil
            }
        }
        return nil
    }

    /// Returns the 1-based hub port number that `child` is plugged into on `parent`.
    public static func childHubPort(parent: UInt32, child: UInt32) -> Int? {
        let hubPath = child & 0x00FF_FFFF
        guard hubPath != 0 else { return nil }
        for shift in stride(from: 0, to: 24, by: 4) {
            let nibble = (hubPath >> shift) & 0xF
            guard nibble != 0 else { continue }
            let cleared = child & ~(UInt32(0xF) << shift)
            return cleared == parent ? Int(nibble) : nil
        }
        return nil
    }

    public var sfSymbol: String {
        if isDisplayConnection {
            return "display"
        }
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
        if lowerName.contains("receiver") && vendorID == 0x046D {
            return "antenna.radiowaves.left.and.right"
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

// MARK: - Topology Tree Node

public struct USBDeviceTreeNode: Identifiable, Equatable, Sendable {
    public let device: USBDeviceItem
    public let depth: Int
    public let children: [USBDeviceTreeNode]

    public var id: UInt64 { device.id }
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

// MARK: - Physical Port & DisplayPort Transport Helpers (Adapted from WhatCable)

private struct PhysicalPortContext: Sendable {
    let rawPortName: String          // e.g. "Port-USB-C@2"
    let humanPortName: String        // e.g. "USB-C Port 2"
    let portNumber: Int?
    let portTypeDescription: String? // e.g. "USB-C", "HDMI", "MagSafe 3"
    let hpmBusIndex: Int?            // e.g. 1 from "hpm1"
    let activeTransports: [String]   // e.g. ["CC", "USB2", "USB3", "DisplayPort"]
    let supportedTransports: [String]
    let usbPDControllerSummary: String?
    let usbProductPairs: [(vendorID: UInt16, productID: UInt16, signaling: String?)]
}

private struct ActiveDisplayConnection: Sendable {
    let entryID: UInt64
    let productName: String
    let manufacturerName: String?
    let productID: UInt16
    let serialNumber: String?
    let dfpType: String?             // e.g. "HDMI", "DisplayPort"
    let linkRateDescription: String? // e.g. "8.1 Gbps (HBR3)"
    let shortRateBadge: String?      // e.g. "8.1 Gbps"
    let laneCount: Int?
    let maxLaneCount: Int?
    let isTunneled: Bool
    let humanPortName: String?       // e.g. "USB-C Port 2"
    let parentPortType: String?      // e.g. "USB-C" or "HDMI"
    let manufactureDate: String?     // e.g. "2022 (Week 51)"
    let resolutionSummary: String?   // e.g. "3840×2160 @ 60 Hz"
    let maxModeSummary: String?
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
    @Published var notchExpandedDeviceIDs: Set<UInt64> = []
    @Published var notchCollapsedHubBranchIDs: Set<UInt64> = []

    private var notifyPort: IONotificationPortRef?
    private var usbAddedIter: io_iterator_t = 0
    private var usbRemovedIter: io_iterator_t = 0
    private var dpAddedIter: io_iterator_t = 0
    private var dpRemovedIter: io_iterator_t = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appNotificationObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private var hasStarted = false
    private var hasCompletedInitialEnumeration = false
    private var knownDevicesByID: [UInt64: USBDeviceItem] = [:]
    private var deviceSettleTask: Task<Void, Never>?
    private var secondaryDisplayRefreshTask: Task<Void, Never>?
    private var volumeRefreshTask: Task<Void, Never>?
    private var hudHideWorkItem: DispatchWorkItem?

    /// Settle window to group composite USB devices, companion USB2/USB3 hubs,
    /// and DisplayPort/HDMI Alt-Mode connections that enumerate across multiple
    /// IOKit callbacks (same approach as WhatCable).
    private let settleWindowSeconds: TimeInterval = 0.40
    private let hudDisplayDuration: TimeInterval = 2.8

    private init() {
        // One-time migration so existing users who had the old `hideUSBHubsAndInternal = true`
        // default immediately see their external USB 3.1 / 2.1 hubs without having to toggle settings.
        if !Defaults[.didMigrateUSBShowHubsByDefault] {
            Defaults[.hideUSBHubsAndInternal] = false
            Defaults[.didMigrateUSBShowHubsByDefault] = true
        }

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

        Defaults.publisher(keys: .usbTreeViewEnabled, .hideUSBHubsAndInternal, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Filtered Views & Topology Tree

    /// External devices and DisplayPort/HDMI connections (excluding built-in internal controllers
    /// and standalone Billboard management endpoints whose info is merged onto the parent hub/device).
    var externalDevices: [USBDeviceItem] {
        allDevices.filter { !$0.isBuiltIn && !$0.isBillboard }
    }

    /// Number of connected USB hubs currently hidden by the hub filter.
    var hiddenHubCount: Int {
        guard Defaults[.hideUSBHubsAndInternal] && !showHubsOverride else { return 0 }
        let nonBuiltIn = externalDevices
        let hubs = nonBuiltIn.filter(\.isHub)
        let endpoints = nonBuiltIn.filter { !$0.isHub }
        if endpoints.isEmpty {
            return 0
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
        return endpoints.isEmpty ? candidates : endpoints
    }

    /// Returns all direct sub-devices (HDMI/DisplayPort monitors and USB peripherals) connected to `hub`.
    func childDevices(for hub: USBDeviceItem) -> [USBDeviceItem] {
        guard !hub.childDeviceIDs.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: externalDevices.map { ($0.id, $0) })
        return hub.childDeviceIDs.compactMap { byID[$0] }
    }

    /// Hierarchical topology tree of connected devices for Tree View mode.
    var displayedTreeNodes: [USBDeviceTreeNode] {
        let candidates = externalDevices
        let items: [USBDeviceItem]
        if Defaults[.hideUSBHubsAndInternal] && !showHubsOverride {
            // Keep parent hubs that have active sub-devices so the tree hierarchy remains intact
            let filtered = candidates.filter { !$0.isHub || !$0.childDeviceIDs.isEmpty }
            items = filtered.isEmpty ? candidates : filtered
        } else {
            items = candidates
        }
        guard !items.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        var childrenByParentID: [UInt64: [USBDeviceItem]] = [:]
        var roots: [USBDeviceItem] = []

        for item in items {
            if let parentID = item.parentHubID, parentID != item.id, byID[parentID] != nil {
                childrenByParentID[parentID, default: []].append(item)
            } else {
                roots.append(item)
            }
        }

        // Sort roots so hubs with active sub-devices and high-bandwidth devices appear first
        let sortedRoots = roots.sorted { lhs, rhs in
            let lhsHasKids = !(childrenByParentID[lhs.id]?.isEmpty ?? true)
            let rhsHasKids = !(childrenByParentID[rhs.id]?.isEmpty ?? true)
            if lhsHasKids != rhsHasKids {
                return lhsHasKids
            }
            if lhs.hasMountedStorage != rhs.hasMountedStorage {
                return lhs.hasMountedStorage
            }
            if lhs.isDisplayConnection != rhs.isDisplayConnection {
                return lhs.isDisplayConnection
            }
            let lhsSuper = lhs.speed?.isSuperSpeedOrFaster ?? false
            let rhsSuper = rhs.speed?.isSuperSpeedOrFaster ?? false
            if lhsSuper != rhsSuper {
                return lhsSuper
            }
            return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
        }

        var visited = Set<UInt64>()
        func buildNode(_ device: USBDeviceItem, depth: Int) -> USBDeviceTreeNode {
            visited.insert(device.id)
            let rawKids = (childrenByParentID[device.id] ?? []).filter { !visited.contains($0.id) }
            let sortedKids = rawKids.sorted { lhs, rhs in
                if lhs.isDisplayConnection != rhs.isDisplayConnection {
                    return lhs.isDisplayConnection
                }
                let portL = lhs.hubPortNumber ?? Int.max
                let portR = rhs.hubPortNumber ?? Int.max
                if portL != portR {
                    return portL < portR
                }
                return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
            }
            let childNodes = sortedKids.map { buildNode($0, depth: depth + 1) }
            return USBDeviceTreeNode(device: device, depth: depth, children: childNodes)
        }

        return sortedRoots.map { buildNode($0, depth: 0) }
    }

    /// Dynamically calculates the open-notch height when the `.usbDevices` tab is active,
    /// scaling by connected item count (and expanded states) up to the same maximum height limit
    /// used by the Terminal notch view (`terminalMaxHeightFraction`).
    func preferredNotchHeight(baseHeight: CGFloat, screen: NSScreen? = NSScreen.main) -> CGFloat {
        let minHeight = max(baseHeight, NotesLayoutState.list.preferredHeight)
        let screenHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maxFraction = Defaults[.terminalMaxHeightFraction]
        let maxLimit = min(screenHeight * maxFraction, max(300, screenHeight * maxFraction))

        guard !displayedDevices.isEmpty else {
            return minHeight
        }

        // Top notch header bar + USB tab header + bottom content inset
        var estimatedHeight: CGFloat = 96
        if lastEjectError != nil {
            estimatedHeight += 36
        }

        if Defaults[.usbTreeViewEnabled] {
            let treeNodes = displayedTreeNodes
            func measureTreeNode(_ node: USBDeviceTreeNode, isRoot: Bool) -> CGFloat {
                var h: CGFloat = isRoot ? 82 : 70
                if !node.device.mountedVolumes.isEmpty {
                    h += CGFloat(node.device.mountedVolumes.count) * 32
                }
                if notchExpandedDeviceIDs.contains(node.id) {
                    h += 120
                }
                if !node.children.isEmpty && !notchCollapsedHubBranchIDs.contains(node.id) {
                    for child in node.children {
                        h += 6 + measureTreeNode(child, isRoot: false)
                    }
                }
                return h
            }

            for (index, rootNode) in treeNodes.enumerated() {
                if index > 0 {
                    estimatedHeight += 8
                }
                estimatedHeight += measureTreeNode(rootNode, isRoot: true)
            }
        } else {
            let items = displayedDevices
            func measureGridCard(_ device: USBDeviceItem) -> CGFloat {
                var h: CGFloat = 82
                let kids = childDevices(for: device)
                if !kids.isEmpty {
                    h += 28 + CGFloat(kids.count) * 28
                }
                if !device.mountedVolumes.isEmpty {
                    h += CGFloat(device.mountedVolumes.count) * 32
                }
                if notchExpandedDeviceIDs.contains(device.id) {
                    h += 120
                }
                return h
            }

            var rowIndex = 0
            var idx = 0
            while idx < items.count {
                if rowIndex > 0 {
                    estimatedHeight += 8
                }
                let firstHeight = measureGridCard(items[idx])
                let secondHeight = (idx + 1 < items.count) ? measureGridCard(items[idx + 1]) : 0
                estimatedHeight += max(firstHeight, secondHeight)
                idx += 2
                rowIndex += 1
            }
        }

        return min(max(minHeight, estimatedHeight.rounded()), maxLimit)
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

        let ioCallback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let manager = Unmanaged<USBDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak manager] in
                manager?.handleIOKitIteratorSignaled(iterator)
            }
        }

        // Watch IOUSBHostDevice match & terminate
        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            ioCallback,
            selfPtr,
            &usbAddedIter
        ) == KERN_SUCCESS {
            Self.drainIteratorOnly(usbAddedIter)
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            ioCallback,
            selfPtr,
            &usbRemovedIter
        ) == KERN_SUCCESS {
            Self.drainIteratorOnly(usbRemovedIter)
        }

        // Watch IOPortTransportStateDisplayPort match & terminate (HDMI / DisplayPort Alt-Mode on USB-C hubs & ports)
        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            ioCallback,
            selfPtr,
            &dpAddedIter
        ) == KERN_SUCCESS {
            Self.drainIteratorOnly(dpAddedIter)
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOPortTransportStateDisplayPort"),
            ioCallback,
            selfPtr,
            &dpRemovedIter
        ) == KERN_SUCCESS {
            Self.drainIteratorOnly(dpRemovedIter)
        }

        setupVolumeObservers()
        setupDisplayObservers()

        // Build full initial snapshot (USB + HPM Ports + DisplayPort/HDMI + Mounted Volumes)
        rebuildSnapshot()
        knownDevicesByID = Dictionary(uniqueKeysWithValues: allDevices.map { ($0.id, $0) })
        hasCompletedInitialEnumeration = true
    }

    func stopMonitoring() {
        guard hasStarted else { return }
        hasStarted = false
        hasCompletedInitialEnumeration = false

        deviceSettleTask?.cancel()
        deviceSettleTask = nil
        secondaryDisplayRefreshTask?.cancel()
        secondaryDisplayRefreshTask = nil
        volumeRefreshTask?.cancel()
        volumeRefreshTask = nil
        hudHideWorkItem?.cancel()
        hudHideWorkItem = nil
        hudState = .hidden

        for iter in [usbAddedIter, usbRemovedIter, dpAddedIter, dpRemovedIter] where iter != 0 {
            IOObjectRelease(iter)
        }
        usbAddedIter = 0
        usbRemovedIter = 0
        dpAddedIter = 0
        dpRemovedIter = 0

        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        let appCenter = NotificationCenter.default
        for token in appNotificationObservers {
            appCenter.removeObserver(token)
        }
        appNotificationObservers.removeAll()

        allDevices.removeAll()
        knownDevicesByID.removeAll()
    }

    /// Re-enumerates connected USB devices, physical USB-C port transports,
    /// DisplayPort/HDMI connections, and mounted volumes in place without
    /// tearing down IOKit notifications.
    func refreshDevices() {
        guard hasStarted else {
            startMonitoring()
            return
        }
        rebuildSnapshot()
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
            let capturedError = firstError

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.ejectingDeviceIDs.remove(deviceID)
                self.refreshMountedVolumes()
                if let capturedError {
                    self.lastEjectError = "Could not eject \(deviceName): \(capturedError.localizedDescription)"
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
            if let sampleDevice, sampleDevice.isDisplayConnection {
                let proto = sampleDevice.displayShortProtocol ?? "Display"
                let rate = sampleDevice.displayRateBadge ?? "8.1 Gbps"
                subtitle = "\(proto) Connected • \(rate)"
            } else {
                let speed = sampleDevice?.speed?.shortLabel ?? "10 Gbps"
                subtitle = "USB Connected • \(speed)"
            }
        } else {
            if let sampleDevice, sampleDevice.isDisplayConnection {
                let proto = sampleDevice.displayShortProtocol ?? "Display"
                subtitle = "\(proto) Disconnected"
            } else {
                subtitle = "USB Disconnected"
            }
        }

        presentHUD(
            state: connected
                ? .connected(deviceName: name, subtitle: subtitle, symbolName: symbol, extraCount: 0)
                : .disconnected(deviceName: name, subtitle: subtitle, symbolName: symbol, extraCount: 0)
        )
        playFeedbackIfNeeded(connected: connected)
    }

    // MARK: - IOKit & Display Notification Handlers

    private func handleIOKitIteratorSignaled(_ iterator: io_iterator_t) {
        Self.drainIteratorOnly(iterator)
        guard hasCompletedInitialEnumeration else { return }
        rebuildSnapshot()
        scheduleDeviceDiffSettle()
        scheduleDelayedVolumeRefresh()
        scheduleSecondaryDisplayRefresh()
    }

    private func setupDisplayObservers() {
        let center = NotificationCenter.default
        for token in appNotificationObservers {
            center.removeObserver(token)
        }
        appNotificationObservers.removeAll()

        // Fired by macOS whenever an external HDMI / DisplayPort / Thunderbolt monitor
        // connects, disconnects, or changes resolution/refresh rate.
        let screenToken = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasCompletedInitialEnumeration else { return }
                self.rebuildSnapshot()
                self.scheduleDeviceDiffSettle()
                self.scheduleSecondaryDisplayRefresh()
            }
        }
        appNotificationObservers.append(screenToken)
    }

    private func scheduleSecondaryDisplayRefresh() {
        secondaryDisplayRefreshTask?.cancel()
        secondaryDisplayRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.95))
            guard !Task.isCancelled, let self, self.hasCompletedInitialEnumeration else { return }
            self.rebuildSnapshot()
            self.evaluateSettledDeviceChanges()
        }
    }

    // MARK: - Debounced Settle & Subtree Grouping

    private func scheduleDeviceDiffSettle() {
        deviceSettleTask?.cancel()
        let delay = settleWindowSeconds
        deviceSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.rebuildSnapshot()
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
    /// hub or dock with HDMI/DisplayPort and internal USB2/USB3 companions produces
    /// a single crisp HUD instead of multiple rapid-fire notifications.
    private static func summarizeDeviceBatch(_ batch: [USBDeviceItem], isConnected: Bool) -> USBHUDState? {
        guard !batch.isEmpty else { return nil }

        // If a user plugs in a hub alone (or a hub with an HDMI display), keep all meaningful items.
        let nonHubs = batch.filter { !$0.isHub }
        let candidates = nonHubs.isEmpty ? batch : batch

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.hasMountedStorage != rhs.hasMountedStorage {
                return lhs.hasMountedStorage
            }
            if lhs.isDisplayConnection != rhs.isDisplayConnection {
                return lhs.isDisplayConnection
            }
            let lhsSpeed = lhs.speed?.isSuperSpeedOrFaster ?? false
            let rhsSpeed = rhs.speed?.isSuperSpeedOrFaster ?? false
            if lhsSpeed != rhsSpeed {
                return lhsSpeed
            }
            if lhs.isHub != rhs.isHub {
                return !lhs.isHub
            }
            return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
        }

        guard let primary = sorted.first else { return nil }
        let extraCount = max(0, batch.count - 1)

        if isConnected {
            let subtitle: String
            if primary.isDisplayConnection {
                let proto = primary.displayShortProtocol ?? "Display"
                if let res = primary.displayResolutionSummary {
                    subtitle = "\(proto) Connected • \(res)"
                } else if let rate = primary.displayRateBadge {
                    subtitle = "\(proto) Connected • \(rate)"
                } else {
                    subtitle = "\(proto) Connected"
                }
            } else if let speedLabel = primary.speed?.shortLabel {
                if primary.hasHDMIOutput {
                    subtitle = "USB + HDMI • \(speedLabel)"
                } else {
                    subtitle = "USB Connected • \(speedLabel)"
                }
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
            let subtitle = primary.isDisplayConnection
                ? "\(primary.displayShortProtocol ?? "Display") Disconnected"
                : "USB Disconnected"
            return .disconnected(
                deviceName: primary.productName,
                subtitle: subtitle,
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

        for idx in updated.indices where !updated[idx].isDisplayConnection {
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

    // MARK: - Full Topology Snapshot Rebuild (USB + Physical Ports + DisplayPort/HDMI)

    private func rebuildSnapshot() {
        let screenBitsPerComponent = Self.readScreenBitsPerComponent()
        let volumeMap = Self.discoverUSBMountedVolumes()
        let (portContexts, activeDisplays) = Self.discoverPhysicalPortsAndDisplays(
            bitsPerComponent: screenBitsPerComponent
        )

        var usbIter: io_iterator_t = 0
        var rawUSBDevices: [USBDeviceItem] = []
        if IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &usbIter
        ) == KERN_SUCCESS {
            defer { IOObjectRelease(usbIter) }
            rawUSBDevices = Self.drainIteratorRetrying(usbIter) { service in
                Self.makeDevice(from: service, volumeMap: volumeMap, portContexts: portContexts)
            }.compactMap { $0 }
        }

        let unifiedDevices = Self.unifyAndCrossLinkTopology(
            rawUSBDevices: rawUSBDevices,
            portContexts: portContexts,
            activeDisplays: activeDisplays
        )

        let sorted = Self.sortedDevices(unifiedDevices)
        if allDevices != sorted {
            allDevices = sorted
        }
    }

    // MARK: - Physical Port (`IOPort` / `AppleHPMInterface`) & DisplayPort/HDMI Discovery

    @MainActor
    private static func readScreenBitsPerComponent() -> [CGDirectDisplayID: Int] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        var out: [CGDirectDisplayID: Int] = [:]
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { continue }
            let bps = screen.depth.bitsPerSample
            if bps == 8 || bps == 10 {
                out[id] = bps
            }
        }
        return out
    }

    private struct CGOnlineDisplayInfo: Sendable {
        let displayID: CGDirectDisplayID
        let vendorCode: String?
        let modelNumber: UInt32
        let serialNumber: UInt32
        let isBuiltin: Bool
        let currentSummary: String
        let maxSummary: String?
    }

    nonisolated private static func readCoreGraphicsOnlineDisplays(
        bitsPerComponent: [CGDirectDisplayID: Int]
    ) -> [CGOnlineDisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.compactMap { id -> CGOnlineDisplayInfo? in
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            guard !isBuiltin, let cgMode = CGDisplayCopyDisplayMode(id) else { return nil }
            let width = cgMode.pixelWidth
            let height = cgMode.pixelHeight
            guard width > 0, height > 0 else { return nil }
            let refresh = Int( round(cgMode.refreshRate) )
            let bpc = bitsPerComponent[id]
            let bpcSuffix = (bpc == 10) ? " • 10-bit" : ""
            let currentSummary = refresh > 0
                ? "\(width)×\(height) @ \(refresh) Hz\(bpcSuffix)"
                : "\(width)×\(height)\(bpcSuffix)"

            var maxSummary: String?
            if let allModes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
                let nativeModes = allModes.filter { $0.isUsableForDesktopGUI() }
                if let best = (nativeModes.isEmpty ? allModes : nativeModes).max(by: { lhs, rhs in
                    let areaL = lhs.pixelWidth * lhs.pixelHeight
                    let areaR = rhs.pixelWidth * rhs.pixelHeight
                    if areaL != areaR { return areaL < areaR }
                    return lhs.refreshRate < rhs.refreshRate
                }) {
                    let maxW = best.pixelWidth
                    let maxH = best.pixelHeight
                    let maxR = Int(round(best.refreshRate))
                    if maxW > 0 && maxH > 0 && (maxW != width || maxH != height || (maxR > 0 && abs(maxR - refresh) > 1)) {
                        maxSummary = maxR > 0 ? "\(maxW)×\(maxH) @ \(maxR) Hz" : "\(maxW)×\(maxH)"
                    }
                }
            }

            return CGOnlineDisplayInfo(
                displayID: id,
                vendorCode: decodeEDIDPNPVendor(CGDisplayVendorNumber(id)),
                modelNumber: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id),
                isBuiltin: isBuiltin,
                currentSummary: currentSummary,
                maxSummary: maxSummary
            )
        }
    }

    nonisolated private static func decodeEDIDPNPVendor(_ packed: UInt32) -> String? {
        let value = UInt16(truncatingIfNeeded: packed)
        let letters = [
            (value >> 10) & 0x1F,
            (value >> 5) & 0x1F,
            value & 0x1F
        ]
        var out = ""
        for code in letters {
            guard (1...26).contains(code) else { return nil }
            out.append(Character(UnicodeScalar(UInt8(code) + 0x40)))
        }
        return out
    }

    nonisolated private static func discoverPhysicalPortsAndDisplays(
        bitsPerComponent: [CGDirectDisplayID: Int]
    ) -> (ports: [PhysicalPortContext], displays: [ActiveDisplayConnection]) {
        let onlineDisplays = readCoreGraphicsOnlineDisplays(bitsPerComponent: bitsPerComponent)

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPort"),
            &iter
        ) == KERN_SUCCESS else {
            return ([], [])
        }
        defer { IOObjectRelease(iter) }

        var ports: [PhysicalPortContext] = []
        var activeDisplays: [ActiveDisplayConnection] = []

        var portService = IOIteratorNext(iter)
        while portService != 0 {
            defer {
                IOObjectRelease(portService)
                portService = IOIteratorNext(iter)
            }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(portService, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let rawPortName = (dict["PortDescription"] as? String)
                ?? (dict["Description"] as? String)
                ?? di_getIOName(portService)
                ?? "Port"
            let portNumber = (dict["PortNumber"] as? NSNumber)?.intValue
            let portTypeDescription = dict["PortTypeDescription"] as? String
            let humanPortName = humanizePortName(rawPortName, portType: portTypeDescription, portNumber: portNumber)

            let activeTransports = (dict["TransportsActive"] as? [String]) ?? []
            let supportedTransports = (dict["TransportsSupported"] as? [String]) ?? []
            let hpmBusIndex = resolveHPMBusIndex(for: portService)

            var usbProductPairs: [(vendorID: UInt16, productID: UInt16, signaling: String?)] = []
            var pdControllerSummary: String?

            // Inspect child transport nodes (USB2, USB3, DisplayPort, CC/SOP)
            var childIter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(portService, kIOServicePlane, &childIter) == KERN_SUCCESS {
                defer { IOObjectRelease(childIter) }
                var child = IOIteratorNext(childIter)
                while child != 0 {
                    defer {
                        IOObjectRelease(child)
                        child = IOIteratorNext(childIter)
                    }

                    var childProps: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(child, &childProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                          let cDict = childProps?.takeRetainedValue() as? [String: Any] else {
                        continue
                    }

                    var classBuf = [CChar](repeating: 0, count: 128)
                    let childClass = IOObjectGetClass(child, &classBuf) == KERN_SUCCESS
                        ? String(cString: classBuf)
                        : ""

                    if childClass.contains("IOPortTransportStateUSB") {
                        let isActive = (cDict["Active"] as? NSNumber)?.boolValue ?? true
                        if isActive,
                           let vid = (cDict["Vendor ID"] as? NSNumber)?.uint16Value,
                           let pid = (cDict["Product ID"] as? NSNumber)?.uint16Value,
                           vid != 0 {
                            let sig = cDict["SuperSpeedSignalingDescription"] as? String
                            let rate = cDict["DataRateDescription"] as? String
                            let sigSummary = [sig, rate].compactMap { $0 }.joined(separator: " • ")
                            usbProductPairs.append((vid, pid, sigSummary.isEmpty ? nil : sigSummary))
                        }
                    } else if childClass.contains("IOPortTransportStateCC") {
                        pdControllerSummary = inspectCCUSBPDSOP(under: child)
                    } else if childClass.contains("IOPortTransportStateDisplayPort") {
                        if let displayConn = parseDisplayPortTransport(
                            service: child,
                            dict: cDict,
                            fallbackHumanPortName: humanPortName,
                            fallbackPortType: portTypeDescription,
                            onlineDisplays: onlineDisplays
                        ) {
                            activeDisplays.append(displayConn)
                        }
                    }
                }
            }

            ports.append(
                PhysicalPortContext(
                    rawPortName: rawPortName,
                    humanPortName: humanPortName,
                    portNumber: portNumber,
                    portTypeDescription: portTypeDescription,
                    hpmBusIndex: hpmBusIndex,
                    activeTransports: activeTransports,
                    supportedTransports: supportedTransports,
                    usbPDControllerSummary: pdControllerSummary,
                    usbProductPairs: usbProductPairs
                )
            )
        }

        return (ports, activeDisplays)
    }

    nonisolated private static func resolveHPMBusIndex(for portService: io_service_t) -> Int? {
        var current: io_registry_entry_t = portService
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<4 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return nil
            }
            IOObjectRelease(current)
            current = parent

            if let name = di_getIOName(current)?.lowercased(), name.hasPrefix("hpm") {
                let digits = name.dropFirst(3).prefix { $0.isNumber }
                if let idx = Int(digits) {
                    return idx
                }
            }
        }
        return nil
    }

    nonisolated private static func inspectCCUSBPDSOP(under ccService: io_service_t) -> String? {
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(ccService, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIter) }

        var child = IOIteratorNext(childIter)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(childIter)
            }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(child, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let compName = (dict["ComponentName"] as? String) ?? di_getIOName(child) ?? ""
            guard compName == "SOP" || compName.contains("SOP") else { continue }

            let specRev = (dict["Specification Revision"] as? NSNumber)?.intValue
            let vid = (dict["Vendor ID"] as? NSNumber)?.uint16Value ?? 0
            let pid = (dict["Product ID"] as? NSNumber)?.uint16Value ?? 0

            var parts: [String] = []
            if let specRev, specRev > 0 {
                parts.append("USB-PD \(specRev).0")
            } else {
                parts.append("USB-PD")
            }
            if vid != 0 {
                let vendor = USBKnownVendors.name(for: vid)
                let hex = String(format: "0x%04X:0x%04X", vid, pid)
                if let vendor {
                    parts.append("\(vendor) (\(hex))")
                } else {
                    parts.append(hex)
                }
            }
            return parts.joined(separator: " • ")
        }
        return nil
    }

    nonisolated private static func parseDisplayPortTransport(
        service: io_service_t,
        dict: [String: Any],
        fallbackHumanPortName: String,
        fallbackPortType: String?,
        onlineDisplays: [CGOnlineDisplayInfo]
    ) -> ActiveDisplayConnection? {
        let isActive = (dict["Active"] as? NSNumber)?.boolValue ?? false
        let hpdHigh = (dict["HPD_StateDescription"] as? String)?.localizedCaseInsensitiveContains("High") ?? false
        let laneCount = (dict["LaneCount"] as? NSNumber)?.intValue
        guard isActive || (hpdHigh && (laneCount ?? 0) > 0) else {
            return nil
        }

        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            return nil
        }

        let metadata = dict["Metadata"] as? [String: Any]
        let rawProduct = (dict["ProductName"] as? String)
            ?? (metadata?["ProductName"] as? String)
        let rawManufacturer = (dict["ManufacturerName"] as? String)
            ?? (metadata?["ManufacturerName"] as? String)
        let productID = (dict["ProductID"] as? NSNumber)?.uint16Value
            ?? (metadata?["ProductID"] as? NSNumber)?.uint16Value
            ?? 0
        let serialNumInt = (dict["SerialNumber"] as? NSNumber)?.uint64Value
            ?? (metadata?["SerialNumber"] as? NSNumber)?.uint64Value
        let serialString = (serialNumInt != nil && serialNumInt != 0) ? String(serialNumInt!) : nil

        let dfpType = (metadata?["DFP Type Description"] as? String)
            ?? (dict["DFP Type Description"] as? String)
        let linkRateDesc = dict["LinkRateDescription"] as? String
        let maxLaneCount = (dict["MaxLaneCount"] as? NSNumber)?.intValue
        let isTunneled = (dict["Tunneled"] as? NSNumber)?.boolValue ?? false

        let parentPortType = (dict["ParentBuiltInPortTypeDescription"] as? String) ?? fallbackPortType
        let parentPortNum = (dict["ParentBuiltInPortNumber"] as? NSNumber)?.intValue
        let humanPort = parentPortNum != nil
            ? humanizePortName(fallbackHumanPortName, portType: parentPortType, portNumber: parentPortNum)
            : fallbackHumanPortName

        let year = (metadata?["Year of Manufacture"] as? NSNumber)?.intValue
        let week = (metadata?["Week of Manufacture"] as? NSNumber)?.intValue
        let manufactureDate: String? = {
            if let year, year > 1990 {
                if let week, week > 0 {
                    return "\(year) (Week \(week))"
                }
                return "\(year)"
            }
            return nil
        }()

        // Match CoreGraphics live resolution & refresh rate
        let matchedCG: CGOnlineDisplayInfo? = {
            let candidates = onlineDisplays.filter { cg in
                guard productID != 0 && cg.modelNumber == UInt32(productID) else { return false }
                if let mfg = rawManufacturer, let cgVendor = cg.vendorCode {
                    return mfg.caseInsensitiveCompare(cgVendor) == .orderedSame
                }
                return true
            }
            if candidates.count == 1 {
                return candidates[0]
            }
            if candidates.count > 1, let serialNumInt {
                if let bySerial = candidates.first(where: { $0.serialNumber == UInt32(truncatingIfNeeded: serialNumInt) }) {
                    return bySerial
                }
            }
            if onlineDisplays.count == 1 && productID == 0 {
                return onlineDisplays[0]
            }
            return candidates.first
        }()

        // Parse short rate badge (e.g. "8.1 Gbps" from "8.1 Gbps (HBR3)")
        let shortRateBadge: String? = {
            guard let linkRateDesc, !linkRateDesc.isEmpty else { return nil }
            if let parenRange = linkRateDesc.range(of: " (") {
                return String(linkRateDesc[..<parenRange.lowerBound])
            }
            return linkRateDesc
        }()

        let resolvedManufacturer = rawManufacturer.flatMap { USBKnownDisplayVendors.displayName(forPNP: $0) }
            ?? rawManufacturer
        let resolvedName: String = {
            if let rawProduct, !rawProduct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rawProduct.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let dfpType, !dfpType.isEmpty {
                return "\(dfpType) External Display"
            }
            return "External Display"
        }()

        return ActiveDisplayConnection(
            entryID: entryID,
            productName: resolvedName,
            manufacturerName: resolvedManufacturer,
            productID: productID,
            serialNumber: serialString,
            dfpType: dfpType,
            linkRateDescription: linkRateDesc,
            shortRateBadge: shortRateBadge,
            laneCount: laneCount,
            maxLaneCount: maxLaneCount,
            isTunneled: isTunneled,
            humanPortName: humanPort,
            parentPortType: parentPortType,
            manufactureDate: manufactureDate,
            resolutionSummary: matchedCG?.currentSummary,
            maxModeSummary: matchedCG?.maxSummary
        )
    }

    // MARK: - Companion Hub Unification & Cross-Linking

    nonisolated private static func unifyAndCrossLinkTopology(
        rawUSBDevices: [USBDeviceItem],
        portContexts: [PhysicalPortContext],
        activeDisplays: [ActiveDisplayConnection]
    ) -> [USBDeviceItem] {
        var devices = rawUSBDevices

        // 1. Merge Billboard devices onto sibling hub/device sharing containerID or portName
        let billboards = devices.filter(\.isBillboard)
        for bb in billboards {
            guard let summary = bb.billboardSummary else { continue }
            for idx in devices.indices where !devices[idx].isBillboard {
                let sameContainer = (bb.containerID != nil && devices[idx].containerID == bb.containerID)
                let samePort = (bb.portName != nil && devices[idx].portName == bb.portName && devices[idx].isHub)
                if sameContainer || samePort {
                    devices[idx].billboardSummary = summary
                }
            }
        }

        // 2. Unify companion USB 3.x + USB 2.x hub halves that represent the same physical hub
        //    (e.g. Genesys Logic USB3.1 Hub @ 0x01200000 + USB2.1 Hub @ 0x01100000 sharing kUSBContainerID).
        var mergedAwayIDs = Set<UInt64>()
        let externalHubIndices = devices.indices.filter { devices[$0].isHub && !devices[$0].isBuiltIn && !devices[$0].isBillboard }

        var hubGroups: [[Int]] = []
        var assignedHubIndices = Set<Int>()

        for i in externalHubIndices {
            guard !assignedHubIndices.contains(i) else { continue }
            let hubA = devices[i]
            var group = [i]
            assignedHubIndices.insert(i)

            for j in externalHubIndices where !assignedHubIndices.contains(j) {
                let hubB = devices[j]
                let aSuper = hubA.speed?.isSuperSpeedOrFaster ?? false
                let bSuper = hubB.speed?.isSuperSpeedOrFaster ?? false
                // Only merge a SuperSpeed hub half with its USB 2.0/1.1 companion half
                guard aSuper != bSuper else { continue }

                let sameContainer = (hubA.containerID != nil && hubA.containerID == hubB.containerID)
                let sameVendorAndPort = (
                    hubA.vendorID == hubB.vendorID
                    && hubA.busIndex != nil
                    && hubA.busIndex == hubB.busIndex
                    && hubNibbleDepth(hubA.locationID) == hubNibbleDepth(hubB.locationID)
                )
                if sameContainer || sameVendorAndPort {
                    group.append(j)
                    assignedHubIndices.insert(j)
                }
            }
            if group.count > 1 {
                hubGroups.append(group)
            }
        }

        for group in hubGroups {
            // Pick the faster (USB 3.x) hub as primary
            let sortedGroup = group.sorted { lhsIdx, rhsIdx in
                let rankL = devices[lhsIdx].speed?.rawRank ?? 0
                let rankR = devices[rhsIdx].speed?.rawRank ?? 0
                return rankL > rankR
            }
            guard let primaryIdx = sortedGroup.first else { continue }
            for companionIdx in sortedGroup.dropFirst() {
                let companion = devices[companionIdx]
                mergedAwayIDs.insert(companion.id)
                devices[primaryIdx].companionLocationIDs.append(companion.locationID)
                let compSpeed = companion.speed?.shortLabel ?? "USB 2.0"
                devices[primaryIdx].companionHubSummary = "\(companion.productName) (\(compSpeed) • \(companion.vendorProductHex))"
                if devices[primaryIdx].portName == nil {
                    devices[primaryIdx].portName = companion.portName
                }
                if devices[primaryIdx].portTransportsSummary == nil {
                    devices[primaryIdx].portTransportsSummary = companion.portTransportsSummary
                }
                if devices[primaryIdx].usbPDControllerSummary == nil {
                    devices[primaryIdx].usbPDControllerSummary = companion.usbPDControllerSummary
                }
            }
        }

        devices.removeAll { mergedAwayIDs.contains($0.id) }

        // 3. Map locationIDs (including merged companion locationIDs) to device indices for parent-child linking
        var hubIndexByLocationID: [UInt32: Int] = [:]
        for idx in devices.indices where devices[idx].isHub && !devices[idx].isBuiltIn {
            hubIndexByLocationID[devices[idx].locationID] = idx
            for compLoc in devices[idx].companionLocationIDs {
                hubIndexByLocationID[compLoc] = idx
            }
        }

        // 4. Link child USB devices to their parent hub and propagate physical port names
        for idx in devices.indices where !devices[idx].isBuiltIn && !devices[idx].isBillboard {
            let childLoc = devices[idx].locationID
            guard let parentLoc = USBDeviceItem.computeParentLocationID(childLoc),
                  let parentIdx = hubIndexByLocationID[parentLoc],
                  parentIdx != idx else {
                continue
            }

            let parentHub = devices[parentIdx]
            let portNum = USBDeviceItem.childHubPort(parent: parentLoc, child: childLoc)
            devices[idx].parentHubID = parentHub.id
            devices[idx].parentHubName = parentHub.productName
            devices[idx].hubPortNumber = portNum
            if devices[idx].portName == nil {
                devices[idx].portName = parentHub.portName
            }

            if !devices[parentIdx].childDeviceIDs.contains(devices[idx].id) {
                devices[parentIdx].childDeviceIDs.append(devices[idx].id)
            }

            let childLabel: String
            if let portNum {
                childLabel = "\(devices[idx].productName) (Port \(portNum))"
            } else {
                childLabel = devices[idx].productName
            }
            if !devices[parentIdx].connectedChildren.contains(childLabel) {
                devices[parentIdx].connectedChildren.append(childLabel)
            }
        }

        // 5. Convert active DisplayPort / HDMI connections into first-class `USBDeviceItem` entries
        //    and cross-link them with any USB Hub sitting on the same physical USB-C port!
        for disp in activeDisplays {
            let proto = disp.dfpType ?? (disp.isTunneled ? "Thunderbolt Display" : "DisplayPort")
            let isHDMI = proto.localizedCaseInsensitiveContains("HDMI")

            let connectionTypeLabel: String = {
                if disp.isTunneled {
                    return "\(proto) (Thunderbolt Tunnel)"
                }
                if let portType = disp.parentPortType, portType.localizedCaseInsensitiveContains("USB-C") {
                    if isHDMI {
                        return "HDMI (via USB-C DisplayPort Alt Mode)"
                    }
                    return "\(proto) (USB-C Alt Mode)"
                }
                return proto
            }()

            let laneSummary: String? = {
                guard let lanes = disp.laneCount, lanes > 0 else { return nil }
                if let maxLanes = disp.maxLaneCount, maxLanes > 0, maxLanes != lanes {
                    return "\(lanes)/\(maxLanes) lanes"
                }
                return "\(lanes) lane\(lanes == 1 ? "" : "s")"
            }()

            let linkDesc = [disp.linkRateDescription, laneSummary]
                .compactMap { $0 }
                .joined(separator: " • ")

            // Find if there's an external root USB hub on the same physical USB-C port
            var associatedHubIdx: Int?
            if let dispPort = disp.humanPortName {
                associatedHubIdx = devices.indices.first(where: { idx in
                    devices[idx].isHub
                    && !devices[idx].isBuiltIn
                    && devices[idx].portName == dispPort
                    && devices[idx].parentHubName == nil
                })
            }

            var parentHubIDForDisplay: UInt64?
            var parentHubNameForDisplay: String?
            if let hubIdx = associatedHubIdx {
                parentHubIDForDisplay = devices[hubIdx].id
                parentHubNameForDisplay = devices[hubIdx].productName
                let childBadge = "\(disp.productName) (\(proto))"
                devices[hubIdx].connectedChildren.insertOrContains(childBadge, at: 0)
                devices[hubIdx].childDeviceIDs.insertOrContains(disp.entryID, at: 0)

                let videoSummaryParts = [proto, disp.productName, disp.resolutionSummary ?? disp.shortRateBadge].compactMap { $0 }
                devices[hubIdx].videoOutputSummary = videoSummaryParts.joined(separator: " • ")
                if isHDMI {
                    devices[hubIdx].hasHDMIOutput = true
                } else {
                    devices[hubIdx].hasDisplayPortOutput = true
                }
            }

            let portCtx = portContexts.first { $0.humanPortName == disp.humanPortName }
            let transportsSummary = portCtx.flatMap { ctx in
                ctx.activeTransports.isEmpty ? nil : ctx.activeTransports.joined(separator: " + ")
            }

            let displayItem = USBDeviceItem(
                id: disp.entryID,
                locationID: 0,
                companionLocationIDs: [],
                vendorID: 0,
                productID: disp.productID,
                vendorName: disp.manufacturerName,
                productName: disp.productName,
                serialNumber: disp.serialNumber,
                usbVersion: nil,
                firmwareVersion: nil,
                speed: nil,
                busPowerMA: nil,
                currentMA: nil,
                portName: disp.humanPortName,
                busIndex: portCtx?.hpmBusIndex,
                isThunderboltTunnelled: disp.isTunneled,
                isHub: false,
                isBillboard: false,
                isBuiltIn: false,
                isDisplayConnection: true,
                deviceClass: nil,
                interfaceClasses: [],
                mountedVolumes: [],
                containerID: nil,
                driverName: "IOPortTransportStateDisplayPort",
                activeProcessName: nil,
                companionHubSummary: nil,
                parentHubID: parentHubIDForDisplay,
                parentHubName: parentHubNameForDisplay,
                hubPortNumber: nil,
                childDeviceIDs: [],
                connectedChildren: [],
                portTransportsSummary: transportsSummary,
                usbPDControllerSummary: portCtx?.usbPDControllerSummary,
                videoOutputSummary: nil,
                hasHDMIOutput: isHDMI,
                hasDisplayPortOutput: !isHDMI,
                billboardSummary: nil,
                displayConnectionType: connectionTypeLabel,
                displayShortProtocol: proto,
                displayRateBadge: disp.shortRateBadge,
                displayLinkDescription: linkDesc.isEmpty ? nil : linkDesc,
                displayResolutionSummary: disp.resolutionSummary,
                displayMaxModeSummary: disp.maxModeSummary,
                displayManufactureDate: disp.manufactureDate
            )
            devices.append(displayItem)
        }

        // Sort each hub's childDeviceIDs so DisplayPort/HDMI comes first, then hubPortNumber ascending
        let deviceByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        for idx in devices.indices where !devices[idx].childDeviceIDs.isEmpty {
            devices[idx].childDeviceIDs.sort { lhsID, rhsID in
                guard let lhs = deviceByID[lhsID], let rhs = deviceByID[rhsID] else { return false }
                if lhs.isDisplayConnection != rhs.isDisplayConnection {
                    return lhs.isDisplayConnection
                }
                let portL = lhs.hubPortNumber ?? Int.max
                let portR = rhs.hubPortNumber ?? Int.max
                if portL != portR {
                    return portL < portR
                }
                return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
            }
        }

        return devices
    }

    nonisolated private static func hubNibbleDepth(_ locationID: UInt32) -> Int {
        let hubPath = locationID & 0x00FF_FFFF
        var count = 0
        for shift in stride(from: 0, to: 24, by: 4) {
            if (hubPath >> shift) & 0xF != 0 {
                count += 1
            }
        }
        return count
    }

    // MARK: - Mounted USB Storage Volume Discovery

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

    // MARK: - IOKit USB Device Construction (Adapted from WhatCable)

    nonisolated private static func makeDevice(
        from service: io_service_t,
        volumeMap: [UInt64: [USBMountedVolume]],
        portContexts: [PhysicalPortContext]
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

        if vendorID == 0 && productID == 0 {
            return nil
        }

        let rawVendor = (dict["USB Vendor Name"] as? String)
            ?? (dict["kUSBVendorString"] as? String)
        let rawProduct = (dict["USB Product Name"] as? String)
            ?? (dict["kUSBProductString"] as? String)
            ?? di_getIOName(service)
            ?? "USB Device"
        let trimmedProduct = rawProduct.trimmingCharacters(in: .whitespacesAndNewlines)
        let productName = USBKnownVendors.refinedProductName(
            vendorID: vendorID,
            productID: productID,
            rawName: trimmedProduct.isEmpty ? "USB Device" : trimmedProduct
        )
        let serialNumber = ((dict["USB Serial Number"] as? String)
            ?? (dict["kUSBSerialNumberString"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let speedRaw = (dict["Device Speed"] as? NSNumber)?.uint8Value
            ?? (dict["USBSpeed"] as? NSNumber)?.uint8Value
        let bcdUSB = (dict["bcdUSB"] as? NSNumber)?.uint16Value
        let bcdDevice = (dict["bcdDevice"] as? NSNumber)?.uint16Value
        let busPower = (dict["Bus Power Available"] as? NSNumber).map { $0.intValue * 2 }
        let requestedPower = (dict["Requested Power"] as? NSNumber).map { $0.intValue * 2 }
            ?? (dict["PortCurrentAllocation"] as? NSNumber).map { $0.intValue }
        let deviceClass = (dict["bDeviceClass"] as? NSNumber)?.uint8Value
        let containerID = (dict["kUSBContainerID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let exclusiveOwner = (dict["UsbExclusiveOwner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var classBuf = [CChar](repeating: 0, count: 128)
        let ioClassName = IOObjectGetClass(service, &classBuf) == KERN_SUCCESS
            ? String(cString: classBuf)
            : nil

        let childInspection = inspectDeviceChildren(under: service)
        let interfaceClasses = childInspection.interfaceClasses

        let busIndexFromLoc: Int? = locationID != 0 ? Int((locationID >> 24) & 0xFF) : nil
        let ancestry = classifyPortAncestry(for: service, fallbackBusIndex: busIndexFromLoc)

        // Resolve physical port name and HPM context via:
        // 1) Ancestor UsbIOPort (handling both String and UTF-8 Data with NUL terminator)
        // 2) HPM IOPortTransportStateUSB2/USB3 matching (vendorID, productID)
        // 3) HPM busIndex matching (hpm<N> == locationID >> 24)
        let matchedPortContext: PhysicalPortContext? = {
            if let rawPort = ancestry.rawPortName {
                if let byRaw = portContexts.first(where: { $0.rawPortName.caseInsensitiveCompare(rawPort) == .orderedSame }) {
                    return byRaw
                }
            }
            if let byVIDPID = portContexts.first(where: { ctx in
                ctx.usbProductPairs.contains(where: { $0.vendorID == vendorID && $0.productID == productID })
            }) {
                return byVIDPID
            }
            if let busIdx = ancestry.busIndex {
                if let byBus = portContexts.first(where: { $0.hpmBusIndex == busIdx }) {
                    return byBus
                }
            }
            return nil
        }()

        let resolvedPortName = matchedPortContext?.humanPortName
            ?? ancestry.humanPortName
            ?? (ancestry.isThunderboltTunnelled ? "Thunderbolt" : nil)

        let activeTransportsSummary: String? = {
            guard let ctx = matchedPortContext, !ctx.activeTransports.isEmpty else { return nil }
            return ctx.activeTransports.joined(separator: " + ")
        }()

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
            || (productName.localizedCaseInsensitiveContains("Headset") && builtInFlag)
        )
        let isBuiltIn = builtInFlag || nonRemovableFlag || isInternalAppleDevice || ancestry.hasInternalParent

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
            companionLocationIDs: [],
            vendorID: vendorID,
            productID: productID,
            vendorName: rawVendor,
            productName: productName.isEmpty ? "USB Device" : productName,
            serialNumber: (serialNumber?.isEmpty == false) ? serialNumber : nil,
            usbVersion: bcdUSB.map { formatBCD($0) },
            firmwareVersion: bcdDevice.map { formatBCD($0) },
            speed: speedRaw.map { USBDeviceSpeed(rawValue: $0) },
            busPowerMA: busPower,
            currentMA: requestedPower,
            portName: resolvedPortName,
            busIndex: ancestry.busIndex,
            isThunderboltTunnelled: ancestry.isThunderboltTunnelled,
            isHub: isHub,
            isBillboard: isBillboard,
            isBuiltIn: isBuiltIn,
            isDisplayConnection: false,
            deviceClass: deviceClass,
            interfaceClasses: interfaceClasses,
            mountedVolumes: volumeMap[entryID] ?? [],
            containerID: (containerID?.isEmpty == false) ? containerID : nil,
            driverName: exclusiveOwner ?? childInspection.driverName,
            activeProcessName: childInspection.activeProcessName,
            companionHubSummary: nil,
            parentHubName: nil,
            hubPortNumber: nil,
            connectedChildren: [],
            portTransportsSummary: activeTransportsSummary,
            usbPDControllerSummary: matchedPortContext?.usbPDControllerSummary,
            videoOutputSummary: nil,
            hasHDMIOutput: false,
            hasDisplayPortOutput: false,
            billboardSummary: childInspection.billboardSummary
        )
    }

    private struct ChildInspectionResult {
        var interfaceClasses: Set<UInt8> = []
        var driverName: String?
        var activeProcessName: String?
        var billboardSummary: String?
    }

    nonisolated private static func inspectDeviceChildren(under deviceService: io_service_t) -> ChildInspectionResult {
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return ChildInspectionResult()
        }
        defer { IOObjectRelease(childIter) }

        var result = ChildInspectionResult()
        var child = IOIteratorNext(childIter)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(childIter)
            }

            var classBuf = [CChar](repeating: 0, count: 128)
            let className = IOObjectGetClass(child, &classBuf) == KERN_SUCCESS
                ? String(cString: classBuf)
                : ""

            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                if let prop = IORegistryEntryCreateCFProperty(child, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                    result.interfaceClasses.insert(prop.uint8Value)
                }
                if result.driverName == nil,
                   let owner = IORegistryEntryCreateCFProperty(child, "UsbExclusiveOwner" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    result.driverName = owner
                }
            } else if className.contains("UserClient") {
                if let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    // Format: "pid 1234, ProcessName"
                    if let commaRange = creator.range(of: ", ") {
                        let proc = String(creator[commaRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !proc.isEmpty {
                            result.activeProcessName = proc
                        }
                    }
                }
            } else if className.contains("BillboardDevice") {
                let failed = (IORegistryEntryCreateCFProperty(child, "UsbBillboardAltModeFailed" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
                result.billboardSummary = failed ? "Alt Mode Negotiation Failed" : "USB-C Billboard Alt Mode"
            }
        }
        return result
    }

    private struct PortAncestryResult {
        var rawPortName: String?
        var humanPortName: String?
        var busIndex: Int?
        var isThunderboltTunnelled: Bool
        var hasInternalParent: Bool
    }

    nonisolated private static func classifyPortAncestry(
        for service: io_service_t,
        fallbackBusIndex: Int?
    ) -> PortAncestryResult {
        var current: io_registry_entry_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        var rawPortName: String?
        var humanPortName: String?
        var busIndex = fallbackBusIndex
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

            if busIndex == nil, let name = di_getIOName(current)?.lowercased(), name.hasPrefix("usb-drd") {
                let digits = name.dropFirst("usb-drd".count).prefix { $0.isNumber }
                if let idx = Int(digits) {
                    busIndex = idx
                }
            }

            if rawPortName == nil, let ioPortPath = extractUsbIOPortPath(from: current) {
                let lastComponent = ioPortPath.split(separator: "/").last.map(String.init) ?? ioPortPath
                rawPortName = lastComponent
                humanPortName = humanizePortName(lastComponent, portType: nil, portNumber: nil)
            } else if rawPortName == nil, let name = di_getIOName(current), name.hasPrefix("Port-") {
                rawPortName = name
                humanPortName = humanizePortName(name, portType: nil, portNumber: nil)
            }

            if let builtIn = IORegistryEntryCreateCFProperty(current, "Built-In" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
               builtIn,
               className.contains("USBHub") {
                if let nonRemovable = IORegistryEntryCreateCFProperty(current, "non-removable" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
                   nonRemovable {
                    hasInternalParent = true
                }
            }
        }

        return PortAncestryResult(
            rawPortName: rawPortName,
            humanPortName: humanPortName,
            busIndex: busIndex,
            isThunderboltTunnelled: isThunderboltTunnelled,
            hasInternalParent: hasInternalParent
        )
    }

    /// Reads `"UsbIOPort"` from an IOKit entry, handling both `String` and `Data` (UTF-8 with NUL byte)
    /// just like WhatCable's `USBWatcher.usbIOPortPath(from:)`.
    nonisolated private static func extractUsbIOPortPath(from entry: io_registry_entry_t) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(entry, "UsbIOPort" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let str = cf as? String {
            let trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n "))
            return trimmed.isEmpty ? nil : trimmed
        }
        if let data = cf as? Data, let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n "))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    nonisolated private static func humanizePortName(
        _ raw: String,
        portType: String?,
        portNumber: Int?
    ) -> String {
        if let portType, !portType.isEmpty, let portNumber {
            if portType.localizedCaseInsensitiveContains("USB-C") {
                return "USB-C Port \(portNumber)"
            }
            if portType.localizedCaseInsensitiveContains("HDMI") {
                return "HDMI Port"
            }
            return "\(portType) \(portNumber)"
        }
        if let atRange = raw.range(of: "@") {
            let indexStr = String(raw[atRange.upperBound...])
            if raw.localizedCaseInsensitiveContains("USB-C") {
                return "USB-C Port \(indexStr)"
            }
            if raw.localizedCaseInsensitiveContains("HDMI") {
                return "HDMI Port"
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
            // 1. Mounted storage drives first
            if lhs.hasMountedStorage != rhs.hasMountedStorage {
                return lhs.hasMountedStorage
            }
            // 2. Active external displays (HDMI / DisplayPort) next
            if lhs.isDisplayConnection != rhs.isDisplayConnection {
                return lhs.isDisplayConnection
            }
            // 3. SuperSpeed hubs/devices before low/full-speed peripherals
            let lhsSuper = lhs.speed?.isSuperSpeedOrFaster ?? false
            let rhsSuper = rhs.speed?.isSuperSpeedOrFaster ?? false
            if lhsSuper != rhsSuper {
                return lhsSuper
            }
            // 4. Alphabetical by product name
            return lhs.productName.localizedStandardCompare(rhs.productName) == .orderedAscending
        }
    }

    nonisolated private static func drainIteratorOnly(_ iterator: io_iterator_t) {
        guard iterator != 0 else { return }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
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

private extension Array where Element: Equatable {
    @discardableResult
    mutating func insertOrContains(_ element: Element, at index: Int) -> Bool {
        if contains(element) {
            return true
        }
        insert(element, at: Swift.min(index, count))
        return false
    }
}

// MARK: - Well-Known Display PNP Vendor Codes

private enum USBKnownDisplayVendors {
    static func displayName(forPNP code: String) -> String? {
        table[code.uppercased()]
    }

    private static let table: [String: String] = [
        "APP": "Apple",
        "MSI": "MSI",
        "DEL": "Dell",
        "GSM": "LG",
        "LGD": "LG Display",
        "SAM": "Samsung",
        "ASU": "ASUS",
        "ACI": "ASUS",
        "BNQ": "BenQ",
        "ACR": "Acer",
        "AOC": "AOC",
        "PHL": "Philips",
        "HWP": "HP",
        "LEN": "Lenovo",
        "VSC": "ViewSonic",
        "GBT": "Gigabyte",
        "SNY": "Sony",
        "EIZ": "EIZO",
        "NEC": "NEC"
    ]
}

// MARK: - Well-Known USB Vendor IDs Fallback

private enum USBKnownVendors {
    static func name(for vendorID: UInt16) -> String? {
        table[vendorID]
    }

    static func refinedProductName(vendorID: UInt16, productID: UInt16, rawName: String) -> String {
        if vendorID == 0x046D {
            switch productID {
            case 0xC52B: return "USB Receiver (Unifying)"
            case 0xC534: return "USB Receiver (Nano)"
            case 0xC548: return "USB Receiver (Logi Bolt)"
            case 0xC539, 0xC53A, 0xC547: return "USB Receiver (Lightspeed)"
            default: break
            }
        }
        return rawName
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
        0x048D: "ITE Tech",
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
