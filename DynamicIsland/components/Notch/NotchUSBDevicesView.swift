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
    @State private var hoveredDeviceID: UInt64?
    @State private var expandedDeviceIDs: Set<UInt64> = []
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false

    var minCardWidth: CGFloat = 210

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
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(manager.displayedDevices) { device in
                            USBNotchGridCard(
                                device: device,
                                isHovered: hoveredDeviceID == device.id,
                                isExpanded: expandedDeviceIDs.contains(device.id),
                                isEjecting: manager.ejectingDeviceIDs.contains(device.id),
                                onToggleExpand: {
                                    withAnimation(.easeInOut(duration: 0.16)) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { updateSuppression(for: $0) }
        .onDisappear {
            updateSuppression(for: false)
        }
        .onAppear {
            manager.refreshDevices()
        }
    }

    private var header: some View {
        HStack {
            Text("USB Devices")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
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

struct USBNotchGridCard: View {
    let device: USBDeviceItem
    let isHovered: Bool
    let isExpanded: Bool
    let isEjecting: Bool
    let onToggleExpand: () -> Void
    let onEject: () -> Void
    let onOpenVolume: (USBMountedVolume) -> Void

    private var subtitleText: String {
        var parts: [String] = []
        if let vendor = device.resolvedVendorName {
            parts.append(vendor)
        } else if let usbVersion = device.usbVersion {
            parts.append("USB \(usbVersion)")
        }
        if let port = device.portName {
            parts.append(port)
        }
        if let res = device.displayResolutionSummary {
            parts.append(res)
        } else if let parentHub = device.parentHubName {
            parts.append("via \(parentHub)")
        }
        return parts.isEmpty ? "USB Device" : parts.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: device.sfSymbol)
                    .font(.system(size: 16))
                    .foregroundColor(device.isDisplayConnection ? .mint : .blue)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(device.productName)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)

                        if device.isHub {
                            compactTag("Hub", tint: .purple)
                        }
                        if device.isDisplayConnection, let proto = device.displayShortProtocol {
                            compactTag(proto, tint: .mint)
                        } else if device.hasHDMIOutput {
                            compactTag("HDMI", tint: .mint)
                        } else if device.hasDisplayPortOutput {
                            compactTag("DP", tint: .mint)
                        }
                    }

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

                if device.hasMountedStorage {
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
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)

            if !device.connectedChildren.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(device.connectedChildren, id: \.self) { childName in
                            HStack(spacing: 3) {
                                Image(systemName: childName.contains("HDMI") || childName.contains("Display") ? "display" : "arrow.turn.down.right")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(childName)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(childName.contains("HDMI") || childName.contains("Display") ? Color.mint : .white.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            if !device.mountedVolumes.isEmpty {
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

            if isExpanded {
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
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isHovered ? 0.12 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private func compactTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: Capsule())
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
