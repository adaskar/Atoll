/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Defaults
import SwiftUI

enum USBConnectionHUDMetrics {
    static func isPresented(
        state: USBHUDState,
        notchState: NotchState,
        hideOnClosed: Bool,
        isLocked: Bool
    ) -> Bool {
        notchState == .closed
            && state.isVisible
            && Defaults[.enableUSBDeviceFeature]
            && Defaults[.showUSBConnectionHUD]
            && !hideOnClosed
            && !isLocked
    }

    static func size(
        for state: USBHUDState,
        closedNotchSize: CGSize,
        effectiveClosedNotchHeight: CGFloat
    ) -> CGSize? {
        switch state {
        case .hidden:
            return nil
        case .connected, .disconnected:
            return CGSize(
                width: max(closedNotchSize.width + 230, 460),
                height: closedNotchSize.height
            )
        }
    }
}

struct USBConnectionHUD: View {
    let state: USBHUDState
    let closedNotchSize: CGSize
    let effectiveClosedNotchHeight: CGFloat

    private let connectedAccent = Color(red: 0.36, green: 0.88, blue: 0.42)
    private let disconnectedAccent = Color(red: 1.0, green: 0.65, blue: 0.24)

    var body: some View {
        if let size = USBConnectionHUDMetrics.size(
            for: state,
            closedNotchSize: closedNotchSize,
            effectiveClosedNotchHeight: effectiveClosedNotchHeight
        ) {
            content(totalWidth: size.width)
                .frame(width: size.width, height: size.height)
                .accessibilityElement(children: .contain)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    @ViewBuilder
    private func content(totalWidth: CGFloat) -> some View {
        switch state {
        case .hidden:
            EmptyView()
        case let .connected(deviceName, subtitle, symbolName, extraCount):
            wingContent(
                deviceName: deviceName,
                subtitle: subtitle,
                symbolName: symbolName,
                extraCount: extraCount,
                isConnected: true,
                totalWidth: totalWidth
            )
        case let .disconnected(deviceName, subtitle, symbolName, extraCount):
            wingContent(
                deviceName: deviceName,
                subtitle: subtitle,
                symbolName: symbolName,
                extraCount: extraCount,
                isConnected: false,
                totalWidth: totalWidth
            )
        }
    }

    private func wingContent(
        deviceName: String,
        subtitle: String,
        symbolName: String,
        extraCount: Int,
        isConnected: Bool,
        totalWidth: CGFloat
    ) -> some View {
        let wingWidth = max(0, (totalWidth - closedNotchSize.width) / 2)
        let accent = isConnected ? connectedAccent : disconnectedAccent

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))

                if extraCount > 0 {
                    Text("+\(extraCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(accent.opacity(0.16), in: Capsule())
                }
            }
            .padding(.leading, 18)
            .frame(
                width: wingWidth,
                height: closedNotchSize.height,
                alignment: .leading
            )

            Color.clear
                .frame(
                    width: closedNotchSize.width,
                    height: closedNotchSize.height
                )

            VStack(alignment: .trailing, spacing: 1) {
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isConnected ? .secondary : disconnectedAccent.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(deviceName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            }
            .padding(.trailing, 18)
            .frame(
                width: wingWidth,
                height: closedNotchSize.height,
                alignment: .trailing
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subtitle), \(deviceName)")
        .accessibilityIdentifier(isConnected ? "USBConnectionHUD.Connected" : "USBConnectionHUD.Disconnected")
    }
}

