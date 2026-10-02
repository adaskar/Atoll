/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import SwiftUI
import Lottie
import LottieUI
import Defaults

struct LottieAnimationView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.selectedVisualizer) var selectedVisualizer

    private var shouldAnimate: Bool {
        vm.notchState == .open && !vm.hideOnClosed && musicManager.isPlaying
    }

    var body: some View {
        if shouldAnimate {
            if let selectedVisualizer {
                LottieView(
                    state: LUStateData(
                        type: .loadedFrom(selectedVisualizer.url),
                        speed: selectedVisualizer.speed,
                        loopMode: .loop
                    )
                )
            } else {
                LottieView(
                    state: LUStateData(
                        type: .loadedFrom(URL(string: "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json")!),
                        speed: 1.0,
                        loopMode: .loop
                    )
                )
            }
        }
    }
}

#Preview {
    LottieAnimationView()
        .environmentObject(DynamicIslandViewModel())
}
