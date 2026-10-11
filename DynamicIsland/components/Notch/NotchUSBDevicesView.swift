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
            manager.refreshMountedVolumes()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: device.sfSymbol)
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.productName)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(device.resolvedVendorName ?? device.usbVersion.map { "USB \($0)" } ?? "USB Device")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let speed = device.speed {
                            Text(speed.shortLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
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
                    if let usbVersion = device.usbVersion {
                        GridRow {
                            Text("Standard")
                                .foregroundStyle(.secondary)
                            Text("USB \(usbVersion)")
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    if let speed = device.speed {
                        GridRow {
                            Text("Link Speed")
                                .foregroundStyle(.secondary)
                            Text("\(speed.generationLabel) (\(speed.shortLabel))")
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    if let power = device.powerSummaryText {
                        GridRow {
                            Text("Power")
                                .foregroundStyle(.secondary)
                            Text(power)
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    GridRow {
                        Text("VID : PID")
                            .foregroundStyle(.secondary)
                        Text(device.vendorProductHex)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    if let serial = device.serialNumber {
                        GridRow {
                            Text("Serial")
                                .foregroundStyle(.secondary)
                            Text(serial)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
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
}


