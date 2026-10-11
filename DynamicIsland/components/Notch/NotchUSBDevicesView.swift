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

struct NotchUSBDevicesView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var manager = USBDeviceManager.shared
    @Default(.usbTreeViewEnabled) private var isTreeViewEnabled
    @State private var hoveredDeviceID: UInt64?
    @State private var expandedDeviceIDs: Set<UInt64> = []
    @State private var collapsedHubBranchIDs: Set<UInt64> = []
    @State private var highlightedDeviceID: UInt64?
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false

    var minCardWidth: CGFloat = 215

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minCardWidth, maximum: .infinity), spacing: 8)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let error = manager.lastEjectError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(.smooth) {
                            manager.lastEjectError = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if manager.displayedDevices.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if isTreeViewEnabled {
                            VStack(spacing: 8) {
                                ForEach(manager.displayedTreeNodes) { node in
                                    USBNotchTreeGroupView(
                                        node: node,
                                        hoveredDeviceID: $hoveredDeviceID,
                                        expandedDeviceIDs: $expandedDeviceIDs,
                                        collapsedHubBranchIDs: $collapsedHubBranchIDs,
                                        highlightedDeviceID: highlightedDeviceID,
                                        ejectingDeviceIDs: manager.ejectingDeviceIDs,
                                        onEject: { dev in manager.ejectDevice(dev) },
                                        onOpenVolume: { vol in manager.openVolumeInFinder(vol) }
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        } else {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(manager.displayedDevices) { device in
                                    USBNotchGridCard(
                                        device: device,
                                        subDevices: manager.childDevices(for: device),
                                        isTreeMode: false,
                                        treeChildCount: 0,
                                        isTreeBranchCollapsed: false,
                                        isHovered: hoveredDeviceID == device.id,
                                        isExpanded: expandedDeviceIDs.contains(device.id),
                                        isHighlighted: highlightedDeviceID == device.id,
                                        isEjecting: manager.ejectingDeviceIDs.contains(device.id),
                                        onToggleExpand: {
                                            toggleExpand(for: device.id)
                                        },
                                        onToggleTreeBranch: nil,
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
                                    .contentShape(Rectangle())
                                    .onHover { hovering in
                                        if hovering { hoveredDeviceID = device.id }
                                        else if hoveredDeviceID == device.id { hoveredDeviceID = nil }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { updateSuppression(for: $0) }
        .onDisappear {
            updateSuppression(for: false)
        }
        .onAppear {
            manager.refreshDevices()
        }
    }

    private func toggleExpand(for id: UInt64) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedDeviceIDs.contains(id) {
                expandedDeviceIDs.remove(id)
            } else {
                expandedDeviceIDs.insert(id)
            }
        }
    }

    private func focusAndHighlightDevice(_ targetID: UInt64, using proxy: ScrollViewProxy) {
        highlightClearTask?.cancel()
        withAnimation(.easeInOut(duration: 0.22)) {
            expandedDeviceIDs.insert(targetID)
            highlightedDeviceID = targetID
            proxy.scrollTo(targetID, anchor: .center)
        }
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                if highlightedDeviceID == targetID {
                    highlightedDeviceID = nil
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("USB Devices")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            if !manager.displayedDevices.isEmpty {
                Text("\(manager.displayedDevices.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }

            Spacer()

            // Tree vs Cards layout toggle (synced with Settings)
            HStack(spacing: 2) {
                notchLayoutModeButton(
                    title: "Tree",
                    icon: "list.bullet.indent",
                    isSelected: isTreeViewEnabled
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isTreeViewEnabled = true
                    }
                }
                notchLayoutModeButton(
                    title: "Cards",
                    icon: "square.grid.2x2",
                    isSelected: !isTreeViewEnabled
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isTreeViewEnabled = false
                    }
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.08), in: Capsule())

            if manager.hiddenHubCount > 0 || manager.showHubsOverride {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        manager.showHubsOverride.toggle()
                    }
                } label: {
                    Text(manager.showHubsOverride ? "Hide Hubs" : "Show \(manager.hiddenHubCount) Hub\(manager.hiddenHubCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    manager.refreshDevices()
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(.blue)
                    .frame(width: 16, height: 16)
                    .padding(5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .help("Refresh USB devices")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func notchLayoutModeButton(
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
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isSelected ? Color.blue.opacity(0.35) : Color.clear,
                in: Capsule()
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help(title == "Tree" ? "Group sub-devices under their parent hub" : "Show all devices as individual cards")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.3))
            Text("No USB devices connected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Plug in a USB device to see it here")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

// MARK: - Notch Tree Group View (Hierarchical Hub -> Connected Sub-Devices)

struct USBNotchTreeGroupView: View {
    let node: USBDeviceTreeNode
    @Binding var hoveredDeviceID: UInt64?
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
            USBNotchGridCard(
                device: node.device,
                subDevices: [],
                isTreeMode: true,
                treeChildCount: node.children.count,
                isTreeBranchCollapsed: isBranchCollapsed,
                isHovered: hoveredDeviceID == node.device.id,
                isExpanded: expandedDeviceIDs.contains(node.device.id),
                isHighlighted: highlightedDeviceID == node.device.id,
                isEjecting: ejectingDeviceIDs.contains(node.device.id),
                onToggleExpand: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if expandedDeviceIDs.contains(node.device.id) {
                            expandedDeviceIDs.remove(node.device.id)
                        } else {
                            expandedDeviceIDs.insert(node.device.id)
                        }
                    }
                },
                onToggleTreeBranch: {
                    withAnimation(.easeInOut(duration: 0.16)) {
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
            .onHover { hovering in
                if hovering { hoveredDeviceID = node.device.id }
                else if hoveredDeviceID == node.device.id { hoveredDeviceID = nil }
            }

            if !node.children.isEmpty && !isBranchCollapsed {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { index, childNode in
                        let isLast = index == node.children.count - 1
                        HStack(alignment: .top, spacing: 0) {
                            USBNotchTreeConnectorRail(
                                isLast: isLast,
                                accentColor: childNode.device.isDisplayConnection ? .mint : .blue
                            )
                            .frame(width: 24)

                            USBNotchTreeGroupView(
                                node: childNode,
                                hoveredDeviceID: $hoveredDeviceID,
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
                .padding(.leading, 12)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct USBNotchTreeConnectorRail: View {
    let isLast: Bool
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            let midY: CGFloat = 22
            let centerX: CGFloat = 8
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: centerX, y: -6))
                    path.addLine(to: CGPoint(x: centerX, y: isLast ? midY : geo.size.height + 6))

                    path.move(to: CGPoint(x: centerX, y: midY))
                    path.addLine(to: CGPoint(x: geo.size.width - 2, y: midY))
                }
                .stroke(
                    Color.white.opacity(0.24),
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

// MARK: - Notch USB Card / Tree Row

struct USBNotchGridCard: View {
    let device: USBDeviceItem
    var subDevices: [USBDeviceItem] = []
    var isTreeMode: Bool = false
    var treeChildCount: Int = 0
    var isTreeBranchCollapsed: Bool = false
    let isHovered: Bool
    let isExpanded: Bool
    var isHighlighted: Bool = false
    let isEjecting: Bool
    let onToggleExpand: () -> Void
    var onToggleTreeBranch: (() -> Void)? = nil
    var onSelectSubDevice: ((USBDeviceItem) -> Void)? = nil
    var onSelectParentHub: ((UInt64) -> Void)? = nil
    let onEject: () -> Void
    let onOpenVolume: (USBMountedVolume) -> Void

    private var subtitleText: String {
        var parts: [String] = []
        if let vendor = device.resolvedVendorName {
            parts.append(vendor)
        } else if let usbVersion = device.usbVersion {
            parts.append("USB \(usbVersion)")
        }
        if !isTreeMode || device.parentHubID == nil {
            if let port = device.portName {
                parts.append(port)
            }
        }
        if let res = device.displayResolutionSummary {
            parts.append(res)
        }
        return parts.isEmpty ? "USB Device" : parts.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardMainHeaderRow

            if !isTreeMode, let parentHubName = device.parentHubName {
                parentHubBanner(parentHubName: parentHubName)
            }

            if !isTreeMode && !subDevices.isEmpty {
                subDevicesInspectorList
            }

            if !device.mountedVolumes.isEmpty {
                mountedVolumesRow
            }

            if isExpanded {
                expandedDetailsGrid
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var iconForegroundColor: Color {
        if device.isDisplayConnection { return .mint }
        if device.isHub { return .purple }
        return .blue
    }

    private var cardBackground: some View {
        let fillOpacity: Double = isHighlighted ? 0.22 : (isHovered ? 0.12 : 0.08)
        let fillColor: Color = isHighlighted ? Color.blue.opacity(fillOpacity) : Color.white.opacity(fillOpacity)
        let strokeColor: Color = isHighlighted ? Color.cyan.opacity(0.85) : Color.blue.opacity(0.2)
        let strokeWidth: CGFloat = isHighlighted ? 1.6 : 1.0
        return RoundedRectangle(cornerRadius: 12)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
    }

    private var cardMainHeaderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: device.sfSymbol)
                .font(.system(size: 16))
                .foregroundColor(iconForegroundColor)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                titleBadgesRow

                HStack(spacing: 6) {
                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let badge = device.primarySpeedBadge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(device.isHighBandwidthBadge ? Color.cyan : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isTreeMode && treeChildCount > 0, let onToggleTreeBranch {
                Button(action: onToggleTreeBranch) {
                    HStack(spacing: 3) {
                        Text("\(treeChildCount) connected")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        Image(systemName: isTreeBranchCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.18), in: Capsule())
                }
                .buttonStyle(PlainButtonStyle())
                .help(isTreeBranchCollapsed ? "Expand connected sub-devices" : "Collapse sub-devices")
            }

            if device.hasMountedStorage {
                ejectButtonView
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
    }

    private var titleBadgesRow: some View {
        HStack(spacing: 5) {
            if isTreeMode, device.parentHubID != nil, let portBadge = device.hubPortBadge {
                compactTag(portBadge, tint: device.isDisplayConnection ? .mint : .blue)
            }

            Text(device.productName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .multilineTextAlignment(.leading)

            if device.isHub {
                compactTag("Hub", tint: .purple)
            }
            if !isTreeMode || device.parentHubID == nil {
                if device.isDisplayConnection, let proto = device.displayShortProtocol {
                    compactTag(proto, tint: .mint)
                } else if device.hasHDMIOutput {
                    compactTag("HDMI", tint: .mint)
                } else if device.hasDisplayPortOutput {
                    compactTag("DP", tint: .mint)
                }
            }
        }
    }

    private var ejectButtonView: some View {
        Button(action: onEject) {
            if isEjecting {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "eject.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEjecting)
        .help("Eject \(device.productName)")
    }

    private func parentHubBanner(parentHubName: String) -> some View {
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
                    .lineLimit(1)
                if let portBadge = device.hubPortBadge {
                    Text("•")
                    Text(portBadge)
                        .font(.system(size: 9.5, weight: .bold))
                }
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.backward.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(Color.purple.opacity(0.95))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PlainButtonStyle())
        .help("Connected via \(parentHubName). Click to highlight parent hub.")
    }

    private var subDevicesInspectorList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("Connected Sub-Devices (\(subDevices.count))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            }

            VStack(spacing: 3) {
                ForEach(subDevices) { child in
                    subDeviceInspectorRow(child)
                }
            }
        }
        .padding(6)
        .background(Color.purple.opacity(0.09))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.purple.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func subDeviceInspectorRow(_ child: USBDeviceItem) -> some View {
        let accent: Color = child.isDisplayConnection ? .mint : .purple
        let iconTint: Color = child.isDisplayConnection ? .mint : .blue
        return Button {
            onSelectSubDevice?(child)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: child.sfSymbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 16, height: 16)

                if let portBadge = child.hubPortBadge {
                    Text(portBadge)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.2), in: Capsule())
                }

                Text(child.productName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 2)

                if let badge = child.primarySpeedBadge {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(child.isHighBandwidthBadge ? Color.cyan : .secondary)
                }

                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(PlainButtonStyle())
        .help("Jump to and inspect \(child.productName)")
    }

    private var mountedVolumesRow: some View {
        HStack(spacing: 6) {
            ForEach(device.mountedVolumes) { volume in
                Button {
                    onOpenVolume(volume)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                        Text(volume.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        if let cap = volume.capacitySummary {
                            Text(cap)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Open \(volume.name) in Finder")
            }
        }
    }

    private var expandedDetailsGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .overlay(Color.white.opacity(0.08))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                if device.isDisplayConnection {
                    if let connType = device.displayConnectionType {
                        gridRow(label: "Connection", value: connType)
                    }
                    if let res = device.displayResolutionSummary {
                        gridRow(label: "Active Mode", value: res)
                    }
                    if let link = device.displayLinkDescription {
                        gridRow(label: "DP Link", value: link)
                    }
                    if let port = device.portName {
                        gridRow(label: "Port", value: port)
                    }
                    if let route = device.parentRouteSummary {
                        gridRow(label: "Hub Route", value: route)
                    }
                    if let pd = device.usbPDControllerSummary {
                        gridRow(label: "Adapter PD", value: pd)
                    }
                    if let serial = device.serialNumber {
                        gridRow(label: "Serial", value: serial, monospaced: true)
                    }
                } else {
                    if let usbVersion = device.usbVersion {
                        gridRow(label: "Standard", value: "USB \(usbVersion)")
                    }
                    if let speed = device.speed {
                        gridRow(label: "Link Speed", value: "\(speed.generationLabel) (\(speed.shortLabel))")
                    }
                    if let companion = device.companionHubSummary {
                        gridRow(label: "Companion", value: companion)
                    }
                    if let video = device.videoOutputSummary {
                        gridRow(label: "Video Out", value: video)
                    }
                    if let port = device.portName {
                        if let transports = device.portTransportsSummary {
                            gridRow(label: "Port", value: "\(port) (\(transports))")
                        } else {
                            gridRow(label: "Port", value: port)
                        }
                    }
                    if let pd = device.usbPDControllerSummary, device.isHub {
                        gridRow(label: "USB-PD Chip", value: pd)
                    }
                    if let route = device.parentRouteSummary {
                        gridRow(label: "Parent Hub", value: route)
                    }
                    if let power = device.powerSummaryText {
                        gridRow(label: "Power", value: power)
                    }
                    gridRow(label: "VID : PID", value: device.vendorProductHex, monospaced: true)
                    if let fw = device.firmwareVersion {
                        gridRow(label: "Firmware", value: "v\(fw)", monospaced: true)
                    }
                    if let serial = device.serialNumber {
                        gridRow(label: "Serial", value: serial, monospaced: true)
                    }
                }
            }
            .font(.system(size: 10))
            .padding(.top, 2)
        }
    }

    private func compactTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
    }

    private func gridRow(label: String, value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(size: 10, design: .monospaced) : .system(size: 10))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
    }
}
