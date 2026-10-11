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
    @State private var expandedDeviceIDs: Set<UInt64> = []
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: .infinity), spacing: 10)
    ]

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
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(manager.displayedDevices) { device in
                            USBDeviceRowView(
                                device: device,
                                isExpanded: expandedDeviceIDs.contains(device.id),
                                isEjecting: manager.ejectingDeviceIDs.contains(device.id),
                                isDarkCardStyle: true,
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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
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
        HStack(spacing: 10) {
            Text("USB Devices")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            if !manager.displayedDevices.isEmpty {
                Text("\(manager.displayedDevices.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }

            Spacer()

            if manager.hiddenHubCount > 0 || manager.showHubsOverride {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        manager.showHubsOverride.toggle()
                    }
                } label: {
                    Text(manager.showHubsOverride ? "Hide Hubs" : "Show \(manager.hiddenHubCount) Hub\(manager.hiddenHubCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    manager.refreshDevices()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh USB devices")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.gray.opacity(0.6))
            Text("No external USB devices connected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.gray)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }
}

