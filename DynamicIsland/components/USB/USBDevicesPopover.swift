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
    @State private var expandedDeviceIDs: Set<UInt64> = []
    @State private var measuredListHeight: CGFloat = 0

    private let maxListHeight: CGFloat = 420

    private var estimatedListHeight: CGFloat {
        let devices = manager.displayedDevices
        guard !devices.isEmpty else { return 0 }

        var total: CGFloat = 0
        for (index, device) in devices.enumerated() {
            if index > 0 {
                total += 8
            }
            // Base row height (title + subtitle + padding)
            var rowHeight: CGFloat = 56
            if device.powerSummaryText != nil || device.usbVersion != nil {
                rowHeight += 26
            }
            if !device.mountedVolumes.isEmpty {
                rowHeight += CGFloat(device.mountedVolumes.count) * 42 + 6
            }
            if expandedDeviceIDs.contains(device.id) {
                var detailLines = 2 // VID:PID + Location ID
                if device.speed != nil { detailLines += 1 }
                if device.serialNumber != nil { detailLines += 1 }
                if device.busPowerMA != nil { detailLines += 1 }
                rowHeight += CGFloat(detailLines) * 18 + 20
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
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.displayedDevices) { device in
                            USBDeviceRowView(
                                device: device,
                                isExpanded: expandedDeviceIDs.contains(device.id),
                                isEjecting: manager.ejectingDeviceIDs.contains(device.id),
                                onToggleExpand: {
                                    withAnimation(.smooth(duration: 0.2)) {
                                        if expandedDeviceIDs.contains(device.id) {
                                            expandedDeviceIDs.remove(device.id)
                                        } else {
                                            expandedDeviceIDs.insert(device.id)
                                        }
                                    }
                                },
                                onEject: {
                                    manager.ejectDevice(device)
                                },
                                onOpenVolume: { volume in
                                    manager.openVolumeInFinder(volume)
                                }
                            )
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
        .padding(16)
        .frame(width: 340)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(12)
        )
        .onAppear {
            manager.refreshMountedVolumes()
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

struct USBDeviceRowView: View {
    let device: USBDeviceItem
    let isExpanded: Bool
    let isEjecting: Bool
    var isDarkCardStyle: Bool = false
    let onToggleExpand: () -> Void
    let onEject: () -> Void
    let onOpenVolume: (USBMountedVolume) -> Void

    private var iconAccent: Color {
        if device.hasMountedStorage {
            return .orange
        }
        if device.speed?.isSuperSpeedOrFaster == true {
            return .cyan
        }
        if device.isHub {
            return .purple
        }
        return .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    HStack(spacing: 5) {
                        Text(device.productName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(isDarkCardStyle ? .white : .primary)
                            .lineLimit(1)

                        if device.isHub {
                            Text("Hub")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }

                    HStack(spacing: 4) {
                        if let vendor = device.resolvedVendorName {
                            Text(vendor)
                                .lineLimit(1)
                        }
                        if let vendor = device.resolvedVendorName, device.portName != nil {
                            Text("•")
                                .accessibilityHidden(true)
                            let _ = vendor
                        }
                        if let portName = device.portName {
                            Text(portName)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if let speed = device.speed {
                        Text(speed.shortLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(speed.isSuperSpeedOrFaster ? Color.cyan : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (speed.isSuperSpeedOrFaster ? Color.cyan : Color.primary).opacity(0.12),
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
                    .help(isExpanded ? "Hide details" : "Show technical details")
                }
            }

            // Power & USB version badges
            if device.powerSummaryText != nil || device.usbVersion != nil {
                HStack(spacing: 6) {
                    if let usbVersion = device.usbVersion {
                        metadataPill(icon: "bolt.horizontal", text: "USB \(usbVersion)")
                    }
                    if let power = device.powerSummaryText {
                        metadataPill(icon: "bolt.fill", text: power)
                    }
                }
            }

            // Mounted storage volumes
            if !device.mountedVolumes.isEmpty {
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

            // Expandable technical details (WhatCable-style inspection)
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                        .padding(.vertical, 2)
                    detailLine(label: "VID : PID", value: device.vendorProductHex)
                    if let speed = device.speed {
                        detailLine(label: "Link Speed", value: "\(speed.generationLabel) (\(speed.shortLabel))")
                    }
                    if let serial = device.serialNumber {
                        detailLine(label: "Serial", value: serial)
                    }
                    detailLine(label: "Location ID", value: String(format: "0x%08X", device.locationID))
                    if let busPower = device.busPowerMA {
                        let req = device.currentMA ?? 0
                        detailLine(label: "Power Budget", value: "\(req) mA requested / \(busPower) mA available")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDarkCardStyle ? Color.white.opacity(0.07) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(isDarkCardStyle ? 0.08 : 0.05), lineWidth: 1)
        )
    }

    private func metadataPill(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func detailLine(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(isDarkCardStyle ? .white.opacity(0.9) : .primary)
                .lineLimit(1)
        }
    }
}

