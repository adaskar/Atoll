/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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
import Defaults
import SwiftUI

private struct USBPopoverContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct USBDevicesPopover: View {
    @ObservedObject private var manager = USBDeviceManager.shared
    @Default(.usbTreeViewEnabled) private var isTreeViewEnabled
    @State private var expandedDeviceIDs: Set<UInt64> = []
    @State private var collapsedHubBranchIDs: Set<UInt64> = []
    @State private var highlightedDeviceID: UInt64?
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var measuredListHeight: CGFloat = 0

    private let maxListHeight: CGFloat = 450

    private var estimatedListHeight: CGFloat {
        let devices = manager.displayedDevices
        guard !devices.isEmpty else { return 0 }

        var total: CGFloat = 0
        for (index, device) in devices.enumerated() {
            if index > 0 {
                total += 8
            }
            var rowHeight: CGFloat = 60
            let subDevices = manager.childDevices(for: device)
            if !isTreeViewEnabled && !subDevices.isEmpty {
                rowHeight += CGFloat(subDevices.count) * 28 + 28
            }
            if !device.mountedVolumes.isEmpty {
                rowHeight += CGFloat(device.mountedVolumes.count) * 42 + 6
            }
            if expandedDeviceIDs.contains(device.id) {
                rowHeight += 125
            }
            total += rowHeight
        }
        return total
    }

    private var resolvedListHeight: CGFloat {
        let target = measuredListHeight > 0 ? measuredListHeight : estimatedListHeight
        return min(max(target, 60), maxListHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()
                .padding(.horizontal, -8)

            if let error = manager.lastEjectError {
                ejectErrorBanner(error)
            }

            if manager.displayedDevices.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            if isTreeViewEnabled {
                                ForEach(manager.displayedTreeNodes) { node in
                                    USBPopoverTreeNodeView(
                                        node: node,
                                        expandedDeviceIDs: $expandedDeviceIDs,
                                        collapsedHubBranchIDs: $collapsedHubBranchIDs,
                                        highlightedDeviceID: highlightedDeviceID,
                                        ejectingDeviceIDs: manager.ejectingDeviceIDs,
                                        onEject: { dev in manager.ejectDevice(dev) },
                                        onOpenVolume: { vol in manager.openVolumeInFinder(vol) }
                                    )
                                }
                            } else {
                                ForEach(manager.displayedDevices) { device in
                                    USBDeviceRowView(
                                        device: device,
                                        subDevices: manager.childDevices(for: device),
                                        isExpanded: expandedDeviceIDs.contains(device.id),
                                        isHighlighted: highlightedDeviceID == device.id,
                                        isEjecting: manager.ejectingDeviceIDs.contains(device.id),
                                        onToggleExpand: {
                                            toggleExpand(for: device.id)
                                        },
                                        onSelectSubDevice: { subDevice in
                                            focusAndHighlightDevice(subDevice.id, using: proxy)
                                        },
                                        onSelectParentHub: { parentID in
                                            focusAndHighlightDevice(parentID, using: proxy)
                                        },
                                        onEject: {
                                            manager.ejectDevice(device)
                                        },
                                        onOpenVolume: { volume in
                                            manager.openVolumeInFinder(volume)
                                        }
                                    )
                                    .id(device.id)
                                }
                            }
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(key: USBPopoverContentHeightKey.self, value: geo.size.height)
                            }
                        )
                    }
                    .onPreferenceChange(USBPopoverContentHeightKey.self) { newHeight in
                        if abs(measuredListHeight - newHeight) > 0.5 {
                            measuredListHeight = newHeight
                        }
                    }
                    .frame(height: resolvedListHeight)
                    .animation(.smooth(duration: 0.2), value: resolvedListHeight)
                }
            }
        }
        .padding(16)
        .frame(width: 368)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(12)
        )
        .onAppear {
            manager.refreshDevices()
        }
    }

    private func toggleExpand(for id: UInt64) {
        withAnimation(.smooth(duration: 0.2)) {
            if expandedDeviceIDs.contains(id) {
                expandedDeviceIDs.remove(id)
            } else {
                expandedDeviceIDs.insert(id)
            }
        }
    }

    private func focusAndHighlightDevice(_ targetID: UInt64, using proxy: ScrollViewProxy) {
        highlightClearTask?.cancel()
        withAnimation(.smooth(duration: 0.24)) {
            expandedDeviceIDs.insert(targetID)
            highlightedDeviceID = targetID
            proxy.scrollTo(targetID, anchor: .center)
        }
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) {
                if highlightedDeviceID == targetID {
                    highlightedDeviceID = nil
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .foregroundStyle(.secondary)
            Text("USB Devices")
                .font(.system(size: 13, weight: .semibold))

            if !manager.displayedDevices.isEmpty {
                Text("\(manager.displayedDevices.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }

            Spacer()

            // Tree vs Cards layout toggle (synced with Settings)
            HStack(spacing: 2) {
                layoutModeButton(
                    title: "Tree",
                    icon: "list.bullet.indent",
                    isSelected: isTreeViewEnabled
                ) {
                    withAnimation(.smooth(duration: 0.2)) {
                        isTreeViewEnabled = true
                    }
                }
                layoutModeButton(
                    title: "Cards",
                    icon: "rectangle.grid.1x2",
                    isSelected: !isTreeViewEnabled
                ) {
                    withAnimation(.smooth(duration: 0.2)) {
                        isTreeViewEnabled = false
                    }
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.07), in: Capsule())

            if manager.hiddenHubCount > 0 || manager.showHubsOverride {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        manager.showHubsOverride.toggle()
                    }
                } label: {
                    Text(manager.showHubsOverride ? "Hide Hubs" : "Show \(manager.hiddenHubCount) Hub\(manager.hiddenHubCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    manager.refreshDevices()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh USB devices")
        }
    }

    private func layoutModeButton(
        title: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                isSelected ? Color.primary.opacity(0.14) : Color.clear,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(title == "Tree" ? "Group sub-devices under their parent hub" : "Show all devices as individual cards")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))
            Text("No external USB devices connected.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }

    private func ejectErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                withAnimation(.smooth) {
                    manager.lastEjectError = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Popover Tree View Node (Hierarchical Parent Hub -> Connected Sub-Devices)

struct USBPopoverTreeNodeView: View {
    let node: USBDeviceTreeNode
    @Binding var expandedDeviceIDs: Set<UInt64>
    @Binding var collapsedHubBranchIDs: Set<UInt64>
    let highlightedDeviceID: UInt64?
    let ejectingDeviceIDs: Set<UInt64>
    let onEject: (USBDeviceItem) -> Void
    let onOpenVolume: (USBMountedVolume) -> Void

    private var isBranchCollapsed: Bool {
        collapsedHubBranchIDs.contains(node.device.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            USBDeviceRowView(
                device: node.device,
                subDevices: [],
                isTreeMode: true,
                treeChildCount: node.children.count,
                isTreeBranchCollapsed: isBranchCollapsed,
                isExpanded: expandedDeviceIDs.contains(node.device.id),
                isHighlighted: highlightedDeviceID == node.device.id,
                isEjecting: ejectingDeviceIDs.contains(node.device.id),
                onToggleExpand: {
                    withAnimation(.smooth(duration: 0.2)) {
                        if expandedDeviceIDs.contains(node.device.id) {
                            expandedDeviceIDs.remove(node.device.id)
                        } else {
                            expandedDeviceIDs.insert(node.device.id)
                        }
                    }
                },
                onToggleTreeBranch: {
                    withAnimation(.smooth(duration: 0.2)) {
                        if collapsedHubBranchIDs.contains(node.device.id) {
                            collapsedHubBranchIDs.remove(node.device.id)
                        } else {
                            collapsedHubBranchIDs.insert(node.device.id)
                        }
                    }
                },
                onSelectSubDevice: nil,
                onSelectParentHub: nil,
                onEject: { onEject(node.device) },
                onOpenVolume: onOpenVolume
            )
            .id(node.device.id)

            if !node.children.isEmpty && !isBranchCollapsed {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { index, childNode in
                        let isLast = index == node.children.count - 1
                        HStack(alignment: .top, spacing: 0) {
                            USBTreeConnectorRail(
                                isLast: isLast,
                                accentColor: childAccentColor(for: childNode.device)
                            )
                            .frame(width: 22)

                            USBPopoverTreeNodeView(
                                node: childNode,
                                expandedDeviceIDs: $expandedDeviceIDs,
                                collapsedHubBranchIDs: $collapsedHubBranchIDs,
                                highlightedDeviceID: highlightedDeviceID,
                                ejectingDeviceIDs: ejectingDeviceIDs,
                                onEject: onEject,
                                onOpenVolume: onOpenVolume
                            )
                        }
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func childAccentColor(for item: USBDeviceItem) -> Color {
        if item.isDisplayConnection { return .mint }
        if item.hasMountedStorage { return .orange }
        if item.speed?.isSuperSpeedOrFaster == true { return .cyan }
        if item.isHub { return .purple }
        return .blue
    }
}

// MARK: - Visual Tree Connector Rail (`├─` / `└─` with Node Dot)

struct USBTreeConnectorRail: View {
    let isLast: Bool
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            let midY: CGFloat = 24
            let centerX: CGFloat = 8
            ZStack(alignment: .topLeading) {
                Path { path in
                    // Vertical trunk from top to either midY (last child) or full height
                    path.move(to: CGPoint(x: centerX, y: -6))
                    path.addLine(to: CGPoint(x: centerX, y: isLast ? midY : geo.size.height + 6))

                    // Horizontal elbow branch to child card
                    path.move(to: CGPoint(x: centerX, y: midY))
                    path.addLine(to: CGPoint(x: geo.size.width - 2, y: midY))
                }
                .stroke(
                    Color.primary.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )

                Circle()
                    .fill(accentColor)
                    .frame(width: 5, height: 5)
                    .offset(x: centerX - 2.5, y: midY - 2.5)
            }
        }
    }
}

// MARK: - USB Device Card / Tree Row View

struct USBDeviceRowView: View {
    let device: USBDeviceItem
    var subDevices: [USBDeviceItem] = []
    var isTreeMode: Bool = false
    var treeChildCount: Int = 0
    var isTreeBranchCollapsed: Bool = false
    let isExpanded: Bool
    var isHighlighted: Bool = false
    let isEjecting: Bool
    var isDarkCardStyle: Bool = false
    let onToggleExpand: () -> Void
    var onToggleTreeBranch: (() -> Void)? = nil
    var onSelectSubDevice: ((USBDeviceItem) -> Void)? = nil
    var onSelectParentHub: ((UInt64) -> Void)? = nil
    let onEject: () -> Void
    let onOpenVolume: (USBMountedVolume) -> Void

    private var iconAccent: Color {
        if device.hasMountedStorage {
            return .orange
        }
        if device.isDisplayConnection {
            return .mint
        }
        if device.speed?.isSuperSpeedOrFaster == true {
            return .cyan
        }
        if device.isHub {
            return .purple
        }
        return .blue
    }

    private var subtitleComponents: [String] {
        var parts: [String] = []
        if let vendor = device.resolvedVendorName {
            parts.append(vendor)
        }
        if !isTreeMode || device.parentHubID == nil {
            if let portName = device.portName {
                parts.append(portName)
            }
        }
        if isTreeMode, let res = device.displayResolutionSummary {
            parts.append(res)
        }
        return parts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowMainHeader

            if !isTreeMode, let parentHubName = device.parentHubName {
                parentHubRouteBanner(parentHubName: parentHubName)
            } else if hasMetadataPills {
                metadataPillsScrollRow
            }

            if !isTreeMode && !subDevices.isEmpty {
                subDevicesInspectorSection
            }

            if !device.mountedVolumes.isEmpty {
                mountedVolumesSection
            }

            if isExpanded {
                expandedDetailsSection
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isHighlighted
                        ? iconAccent.opacity(0.14)
                        : (isDarkCardStyle ? Color.white.opacity(0.07) : Color.primary.opacity(0.05))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHighlighted
                        ? iconAccent.opacity(0.75)
                        : Color.white.opacity(isDarkCardStyle ? 0.08 : 0.05),
                    lineWidth: isHighlighted ? 1.5 : 1
                )
        )
    }

    private var hasMetadataPills: Bool {
        device.displayResolutionSummary != nil
            || device.usbVersion != nil
            || device.powerSummaryText != nil
            || device.companionHubSummary != nil
    }

    private var rowMainHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconAccent.opacity(0.16))
                    .frame(width: 32, height: 32)

                Image(systemName: device.sfSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                titleBadgesRow

                if !subtitleComponents.isEmpty {
                    Text(subtitleComponents.joined(separator: " • "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            trailingActionsRow
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
    }

    private var titleBadgesRow: some View {
        HStack(spacing: 5) {
            if isTreeMode, device.parentHubID != nil, let portBadge = device.hubPortBadge {
                roleBadge(portBadge, tint: device.isDisplayConnection ? .mint : .blue)
            }

            Text(device.productName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isDarkCardStyle ? .white : .primary)
                .lineLimit(1)

            if device.isHub {
                roleBadge("Hub", tint: .purple)
            }
            if !isTreeMode || device.parentHubID == nil {
                if device.isDisplayConnection, let proto = device.displayShortProtocol {
                    roleBadge(proto, tint: .mint)
                } else if device.hasHDMIOutput {
                    roleBadge("HDMI", tint: .mint)
                } else if device.hasDisplayPortOutput {
                    roleBadge("DP", tint: .mint)
                }
            }
        }
    }

    private var trailingActionsRow: some View {
        HStack(spacing: 5) {
            if isTreeMode && treeChildCount > 0, let onToggleTreeBranch {
                Button(action: onToggleTreeBranch) {
                    HStack(spacing: 3) {
                        Image(systemName: isTreeBranchCollapsed ? "point.3.connected.trianglepath.dotted" : "list.bullet.indent")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("\(treeChildCount)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        Image(systemName: isTreeBranchCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(isTreeBranchCollapsed ? "Expand \(treeChildCount) connected sub-devices" : "Collapse sub-devices")
            }

            if let badge = device.primarySpeedBadge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(device.isHighBandwidthBadge ? Color.cyan : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (device.isHighBandwidthBadge ? Color.cyan : Color.primary).opacity(0.12),
                        in: Capsule()
                    )
            }

            if device.hasMountedStorage {
                Button(action: onEject) {
                    if isEjecting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isDarkCardStyle ? .white : .primary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.1), in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isEjecting)
                .help("Eject \(device.productName)")
            }

            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide technical details" : "Show technical details")
        }
    }

    private func parentHubRouteBanner(parentHubName: String) -> some View {
        HStack(spacing: 6) {
            Button {
                if let parentID = device.parentHubID {
                    onSelectParentHub?(parentID)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8.5, weight: .bold))
                    Text(parentHubName)
                        .font(.system(size: 9.5, weight: .semibold))
                    if let portBadge = device.hubPortBadge {
                        Text("•")
                        Text(portBadge)
                            .font(.system(size: 9.5, weight: .bold))
                    }
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.purple.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Connected through \(parentHubName). Click to highlight hub.")

            if let res = device.displayResolutionSummary {
                metadataPill(icon: "sparkles.tv", text: res)
            } else if let usbVersion = device.usbVersion {
                metadataPill(icon: "bolt.horizontal", text: "USB \(usbVersion)")
            }
            if let power = device.powerSummaryText {
                metadataPill(icon: "bolt.fill", text: power)
            }
        }
    }

    private var metadataPillsScrollRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !isTreeMode, let res = device.displayResolutionSummary {
                    metadataPill(icon: "sparkles.tv", text: res)
                }
                if let link = device.displayLinkDescription {
                    metadataPill(icon: "cable.connector.horizontal", text: link)
                }
                if let usbVersion = device.usbVersion {
                    metadataPill(icon: "bolt.horizontal", text: "USB \(usbVersion)")
                }
                if device.companionHubSummary != nil {
                    metadataPill(icon: "arrow.triangle.branch", text: "+ USB 2.0 Companion")
                }
                if let power = device.powerSummaryText {
                    metadataPill(icon: "bolt.fill", text: power)
                }
            }
        }
    }

    private var subDevicesInspectorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("Connected Sub-Devices (\(subDevices.count))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Click to inspect")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 2)

            VStack(spacing: 4) {
                ForEach(subDevices) { child in
                    Button {
                        onSelectSubDevice?(child)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: child.sfSymbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(child.isDisplayConnection ? Color.mint : Color.blue)
                                .frame(width: 18, height: 18)
                                .background(
                                    (child.isDisplayConnection ? Color.mint : Color.blue).opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )

                            if let portBadge = child.hubPortBadge {
                                Text(portBadge)
                                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(child.isDisplayConnection ? Color.mint : Color.purple)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        (child.isDisplayConnection ? Color.mint : Color.purple).opacity(0.14),
                                        in: Capsule()
                                    )
                            }

                            Text(child.productName)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if let res = child.displayResolutionSummary {
                                Text(res)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if let speed = child.primarySpeedBadge {
                                Text(speed)
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(child.isHighBandwidthBadge ? Color.cyan : .secondary)
                            }

                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Jump to and inspect \(child.productName)")
                }
            }
        }
        .padding(6)
        .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.15), lineWidth: 1)
        )
    }

    private var mountedVolumesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(device.mountedVolumes) { volume in
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(volume.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isDarkCardStyle ? .white : .primary)
                            .lineLimit(1)
                        if let summary = volume.capacitySummary {
                            Text(summary)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        onOpenVolume(volume)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                            Text("Open")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(volume.name) in Finder")
                }
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var expandedDetailsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.vertical, 2)

            if device.isDisplayConnection {
                if let connType = device.displayConnectionType {
                    detailLine(label: "Connection", value: connType)
                }
                if let res = device.displayResolutionSummary {
                    detailLine(label: "Active Mode", value: res)
                }
                if let maxMode = device.displayMaxModeSummary {
                    detailLine(label: "Native Top Mode", value: maxMode)
                }
                if let link = device.displayLinkDescription {
                    detailLine(label: "DisplayPort Link", value: link)
                }
                if let port = device.portName {
                    detailLine(label: "Physical Port", value: port)
                }
                if let route = device.parentRouteSummary {
                    detailLine(label: "Hub Route", value: route)
                }
                if let pd = device.usbPDControllerSummary {
                    detailLine(label: "Adapter PD", value: pd)
                }
                if device.productID != 0 {
                    detailLine(label: "EDID Product", value: device.vendorProductHex)
                }
                if let mfgDate = device.displayManufactureDate {
                    detailLine(label: "Manufactured", value: mfgDate)
                }
                if let serial = device.serialNumber {
                    detailLine(label: "Serial", value: serial)
                }
            } else {
                detailLine(label: "VID : PID", value: device.vendorProductHex)
                if let speed = device.speed {
                    detailLine(label: "Link Speed", value: "\(speed.generationLabel) (\(speed.shortLabel))")
                }
                if let companion = device.companionHubSummary {
                    detailLine(label: "Companion Hub", value: companion)
                }
                if let video = device.videoOutputSummary {
                    detailLine(label: "Video Alt Mode", value: video)
                }
                if let port = device.portName {
                    if let transports = device.portTransportsSummary {
                        detailLine(label: "Physical Port", value: "\(port) (\(transports))")
                    } else {
                        detailLine(label: "Physical Port", value: port)
                    }
                }
                if let pd = device.usbPDControllerSummary, device.isHub {
                    detailLine(label: "USB-PD Chip", value: pd)
                }
                if let route = device.parentRouteSummary {
                    detailLine(label: "Parent Hub", value: route)
                }
                if !device.connectedChildren.isEmpty {
                    detailLine(label: "Downstream", value: device.connectedChildren.joined(separator: ", "))
                }
                if let fw = device.firmwareVersion {
                    detailLine(label: "Firmware", value: "v\(fw)")
                }
                if let serial = device.serialNumber {
                    detailLine(label: "Serial", value: serial)
                }
                detailLine(label: "Location ID", value: String(format: "0x%08X", device.locationID))
                if let busPower = device.busPowerMA {
                    let req = device.currentMA ?? 0
                    detailLine(label: "Power Budget", value: "\(req) mA requested / \(busPower) mA available")
                }
                if let proc = device.activeProcessName {
                    detailLine(label: "Active App", value: proc)
                } else if let driver = device.driverName {
                    detailLine(label: "Driver", value: driver)
                }
                if let bb = device.billboardSummary {
                    detailLine(label: "Billboard", value: bb)
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func roleBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func metadataPill(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func detailLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(isDarkCardStyle ? .white.opacity(0.9) : .primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
