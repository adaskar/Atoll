// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreAudio
import Foundation
import ObjectiveC

/// The watched surface owns its destination independently of the system's
/// latest player. Reads and commands use this same path, without changing the
/// system-wide player or requesting automation permission.
enum NotchNativePlayback {
    struct Target {
        let pid: Int32
        let bundleIdentifier: String
        let path: NSObject
        var itemIdentifier: String?
        var allowsDirectCommands = false
        var requiresCurrentPlayer = false
        var playPauseCommand: Int32 = 2
        var applicationBundleIdentifier: String?

        var isRunning: Bool {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return resolvedBundleIdentifier(for: app) == bundleIdentifier
        }
    }

    static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    private static let callbacks = DispatchQueue(label: "com.vorssaint.now-playing-selection-callbacks")
    private static let lock = NSLock()
    private static var selected: Target?
    private static var identity: Identity?
    private static var context: NotchPlaybackContext?
    private static var sources: [NotchPlaybackSource] = []
    private static var selection: NotchPlaybackSource.Selection?
    /// System uptime at which the chosen source, still without a track, is
    /// released. A monotonic clock, so changing the time cannot stretch it.
    private static var releaseAt: TimeInterval?
    /// Tracks when a browser/web-helper candidate claiming `isPlaying` first
    /// stopped outputting audio, so closed tabs are cleared after a short drain
    /// grace period without false-dropping during brief buffer underruns.
    private static var silentSince: [Int32: TimeInterval] = [:]
    private static var nextSilenceCheck: TimeInterval?
    private static var commandGraceUntil: TimeInterval = 0
    private static var audioActivePIDs: Set<Int32> = []
    private static var deadBrowserIdentity: [Int32: Identity] = [:]
    /// Set before the watch starts; the one-shot reader does not use selection.
    static var includeOtherPlayers = false

    static func noteCommandSent(grace: TimeInterval = 2.5) {
        lock.lock(); defer { lock.unlock() }
        commandGraceUntil = ProcessInfo.processInfo.systemUptime + grace
        silentSince.removeAll()
        deadBrowserIdentity.removeAll()
    }

    static var pendingSilenceCheck: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let nextSilenceCheck, nextSilenceCheck > ProcessInfo.processInfo.systemUptime else { return nil }
        return nextSilenceCheck
    }

    /// Returns the CoreAudio process object IDs associated with `pid` (and, for
    /// Safari/WebKit, any `com.apple.WebKit.*` or `com.apple.Safari` process).
    static func audioObjectIDs(for pid: Int32, bundleIdentifier: String?) -> [AudioObjectID] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &dataSize,
            &objects
        ) == noErr else {
            return []
        }

        let isSafariFamily = (bundleIdentifier?.hasPrefix("com.apple.WebKit") == true)
            || (bundleIdentifier == "com.apple.Safari")

        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var matched: [AudioObjectID] = []
        for obj in objects {
            var procPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(obj, &pidAddress, 0, nil, &pidSize, &procPID) == noErr else {
                continue
            }
            let matchesTarget: Bool
            if procPID == pid {
                matchesTarget = true
            } else if isSafariFamily,
                      let app = NSRunningApplication(processIdentifier: procPID),
                      let bid = resolvedBundleIdentifier(for: app),
                      bid.hasPrefix("com.apple.WebKit") || bid == "com.apple.Safari" {
                matchesTarget = true
            } else {
                matchesTarget = false
            }
            if matchesTarget {
                matched.append(obj)
            }
        }
        return matched
    }

    /// Checks via CoreAudio HAL whether the given PID (or any WebKit/Safari helper
    /// when inspecting Safari) is actively outputting audio.
    private static func isAudioOutputRunning(for pid: Int32, bundleIdentifier: String?) -> Bool {
        let objects = audioObjectIDs(for: pid, bundleIdentifier: bundleIdentifier)
        guard !objects.isEmpty else { return false }

        var outAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for obj in objects {
            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(obj, &outAddress, 0, nil, &runSize, &isRunning) == noErr,
               isRunning != 0 {
                return true
            }
        }
        return false
    }

    static var sourceReply: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var reply: [String: Any] = ["sources": sources.map(\.reply), "sourceIsAutomatic": selection == nil]
        // The chosen source stays marked while the automatic player fills a gap.
        reply["selectedPID"] = selection?.pid
        return reply
    }

    /// When the chosen source, waiting for its next track, is due for release.
    /// Nil once that time has passed, so a failed read never repeats at once.
    static var pendingRelease: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard selection != nil, let releaseAt, releaseAt > ProcessInfo.processInfo.systemUptime else { return nil }
        return releaseAt
    }

    static func choose(_ requested: NotchPlaybackSource.Selection?) {
        lock.lock(); defer { lock.unlock() }
        guard requested == nil || sources.contains(where: { $0.selection == requested && $0.hasTrack }) else { return }
        selection = requested
        releaseAt = nil
    }

    private struct Identity: Equatable, Hashable {
        let item: String?
        let metadata: [String]

        init?(_ info: [String: Any]) {
            let title = (info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let identifier = info["itemIdentifier"] as? String
                ?? info["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"] as? String
            item = identifier.flatMap { NotchPlaybackCommand.validIdentifier($0) ? $0 : nil }
            if item != nil { metadata = []; return }
            let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue
            metadata = [title, info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
                        info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
                        duration.flatMap { $0.isFinite ? String($0.rounded()) : nil } ?? ""]
        }
    }

    static var target: Target? {
        lock.lock()
        defer { lock.unlock() }
        return selected
    }

    private static func playPauseCommand(for info: [String: Any]) -> Int32 {
        // The player's own state outranks a rate it has not updated yet.
        let rate = (info["isPlaying"] as? Bool).map { $0 ? 1 : 0 }
            ?? (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
        guard let rate, rate.isFinite else { return 2 }
        if rate > 0, info["canPause"] as? Bool == true { return 1 }
        if rate == 0, info["canPlay"] as? Bool == true { return 0 }
        return 2
    }

    static func select() -> Target? {
        var discovered = false
        defer {
            if !discovered {
                // A failed scan is not evidence that the chosen player ended.
                lock.lock(); sources = []; lock.unlock()
            }
        }
        typealias ReadClient = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
        typealias ReadClients = @convention(c) (DispatchQueue, @escaping @convention(block) (NSArray?) -> Void) -> Void
        typealias PID = @convention(c) (AnyObject) -> Int32
        typealias ClientString = @convention(c) (AnyObject) -> Unmanaged<CFString>?
        guard let getClient = function(handle, "MRMediaRemoteGetNowPlayingClient", as: ReadClient.self),
              let getPID = function(handle, "MRNowPlayingClientGetProcessIdentifier", as: PID.self) else { return nil }
        let group = DispatchGroup()
        let clientsGroup = DispatchGroup()
        let resultsLock = NSLock()
        var systemPID: Int32?
        var clientPIDs: [Int32] = []
        var clientPresentation: [Int32: (name: String?, application: String?)] = [:]
        let getName = function(handle, "MRNowPlayingClientGetDisplayName", as: ClientString.self)
        let getParent = function(handle, "MRNowPlayingClientGetParentAppBundleIdentifier", as: ClientString.self)
        group.enter()
        getClient(callbacks) { client in
            resultsLock.lock()
            systemPID = client.map(getPID)
            resultsLock.unlock()
            group.leave()
        }
        // Browsers need to remain discoverable when a music app owns the
        // system's current player. Enumerate registered clients, not all apps.
        if let getClients = function(handle, "MRMediaRemoteGetNowPlayingClients", as: ReadClients.self) {
            clientsGroup.enter()
            getClients(callbacks) { clients in
                resultsLock.lock()
                clientPIDs = (clients as? [AnyObject] ?? []).prefix(16).map(getPID)
                for client in (clients as? [AnyObject] ?? []).prefix(16) {
                    clientPresentation[getPID(client)] = (getName?(client)?.takeUnretainedValue() as String?,
                                                         getParent?(client)?.takeUnretainedValue() as String?)
                }
                resultsLock.unlock()
                clientsGroup.leave()
            }
        }
        guard group.wait(timeout: .now() + 0.5) == .success else { return nil }
        // Failure to enumerate extra sources must not hide the known player.
        _ = clientsGroup.wait(timeout: .now() + 0.2)
        resultsLock.lock()
        let currentPID = systemPID
        let registeredPIDs = clientPIDs
        let presentation = clientPresentation
        resultsLock.unlock()
        let chosenPID = lock.withLock { selection?.pid }
        let musicPIDs = NSWorkspace.shared.runningApplications.filter { isMusicApp($0) }.map(\.processIdentifier)
        var applications: [NSRunningApplication] = []
        // A bounded fan-out; no timers or queries survive the adapter process.
        // Past the bound, only the least likely clients are skipped: chosen,
        // current and followed players first, then music apps, then the rest.
        for pid in [chosenPID, currentPID, target?.pid].compactMap({ $0 }) + musicPIDs + registeredPIDs {
            guard applications.count < 16 else { break }
            if pid > 0, !applications.contains(where: { $0.processIdentifier == pid }),
               let current = NSRunningApplication(processIdentifier: pid) {
                applications.append(current)
            }
        }
        var candidates: [(Target, NotchPlaybackSource)] = []
        // A rate the player has not updated would rank a paused song as
        // playing. Its own state wins where it answers in time.
        var states: [Int32: Bool] = [:]
        var candidateInfos: [Int32: [String: Any]] = [:]
        let stateReads = DispatchGroup()
        for app in applications {
            guard var candidate = makeTarget(app) else { continue }
            // A browser can publish through a web content helper. Keep its exact
            // process for routing, and use the parent app only for presentation/opening.
            candidate.applicationBundleIdentifier = presentation[candidate.pid]?.application
                .flatMap { NotchPlaybackCommand.validIdentifier($0) ? $0 : nil }
            if candidate.applicationBundleIdentifier == nil,
               candidate.bundleIdentifier.hasPrefix("com.apple.WebKit"),
               !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty {
                candidate.applicationBundleIdentifier = "com.apple.Safari"
            }
            // If the parent application (e.g. Safari) has quit while a shared helper
            // (e.g. com.apple.WebKit.GPU) is still alive, skip this candidate.
            if let parentID = candidate.applicationBundleIdentifier,
               parentID != candidate.bundleIdentifier,
               NSRunningApplication.runningApplications(withBundleIdentifier: parentID).allSatisfy({ $0.isTerminated }) {
                continue
            }
            stateReads.enter()
            readPlaybackState(candidate, queue: callbacks) { isPlaying in
                resultsLock.lock()
                states[candidate.pid] = isPlaying
                resultsLock.unlock()
                stateReads.leave()
            }
            group.enter()
            readInfo(candidate, artwork: false, queue: callbacks) { info in
                let dict = (info as? [String: Any]) ?? [:]
                let isMusic = isMusicApp(app, parentBundleIdentifier: candidate.applicationBundleIdentifier)
                let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
                let elapsed = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
                let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                let sampleDate = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
                let age = sampleDate.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                let estimatedElapsed = elapsed + age * max(0, rate)
                // Browsers/WebKit often leave dormant media widgets (duration > 0, elapsed == 0, rate == 0)
                // or finished/closed tabs whose extrapolated elapsed time has blown past duration.
                let hasLiveTimeline = isMusic
                    || (duration > 0 && elapsed > 0 && estimatedElapsed <= duration + 1.5)
                    || (duration <= 0 && elapsed > 0)
                let source = NotchPlaybackSource(pid: candidate.pid, bundleIdentifier: candidate.bundleIdentifier,
                    isMusicApp: isMusic,
                    isPlaying: rate > 0,
                    hasTrack: !title.isEmpty && hasLiveTimeline,
                    displayName: presentation[candidate.pid]?.name ?? app.localizedName)
                resultsLock.lock()
                candidateInfos[candidate.pid] = dict
                candidates.append((candidate, source))
                resultsLock.unlock()
                group.leave()
            }
        }
        // Keep completed reads when an unrelated client misses the deadline.
        _ = group.wait(timeout: .now() + 1)
        _ = stateReads.wait(timeout: .now() + 0.2)
        let now = ProcessInfo.processInfo.systemUptime
        let activePIDs = Set(applications.map(\.processIdentifier))
        let ready: [(Target, NotchPlaybackSource)] = resultsLock.withLock {
            lock.lock()
            defer { lock.unlock() }
            silentSince = silentSince.filter { activePIDs.contains($0.key) }
            audioActivePIDs = audioActivePIDs.intersection(activePIDs)
            deadBrowserIdentity = deadBrowserIdentity.filter { activePIDs.contains($0.key) }
            nextSilenceCheck = nil
            return candidates.map { candidate, source in
                let mrPlaying = states[candidate.pid] ?? source.isPlaying
                let currentIdentity = candidateInfos[candidate.pid].flatMap(Identity.init)

                var resolvedPlaying = mrPlaying
                var resolvedHasTrack = source.hasTrack

                if !source.isMusicApp && resolvedHasTrack {
                    let audioRunning = isAudioOutputRunning(
                        for: candidate.pid,
                        bundleIdentifier: candidate.applicationBundleIdentifier ?? candidate.bundleIdentifier
                    )

                    if mrPlaying {
                        if audioRunning || now < commandGraceUntil {
                            silentSince.removeValue(forKey: candidate.pid)
                            if audioRunning {
                                audioActivePIDs.insert(candidate.pid)
                                deadBrowserIdentity.removeValue(forKey: candidate.pid)
                            } else {
                                let checkDeadline = commandGraceUntil + 0.05
                                nextSilenceCheck = nextSilenceCheck.map { min($0, checkDeadline) } ?? checkDeadline
                            }
                            resolvedPlaying = true
                        } else {
                            let wasAudioActive = audioActivePIDs.contains(candidate.pid)
                            let firstSilent = silentSince[candidate.pid] ?? {
                                silentSince[candidate.pid] = now
                                return now
                            }()
                            let silentDuration = now - firstSilent
                            if !wasAudioActive || silentDuration >= 0.25 {
                                // Browser/WebKit helper still claims playing in MediaRemote,
                                // but CoreAudio confirms zero audio output (either never
                                // active in this session or drained for >= 0.25s).
                                resolvedPlaying = false
                                resolvedHasTrack = false
                                audioActivePIDs.remove(candidate.pid)
                                silentSince.removeValue(forKey: candidate.pid)
                                if let currentIdentity {
                                    deadBrowserIdentity[candidate.pid] = currentIdentity
                                }
                            } else {
                                resolvedPlaying = true
                                let checkDeadline = firstSilent + 0.25
                                nextSilenceCheck = nextSilenceCheck.map { min($0, checkDeadline) } ?? checkDeadline
                            }
                        }
                    } else {
                        if audioRunning {
                            audioActivePIDs.insert(candidate.pid)
                            deadBrowserIdentity.removeValue(forKey: candidate.pid)
                            // MediaRemote briefly reports paused before updating state, or is lagging.
                            let firstMismatch = silentSince[candidate.pid] ?? {
                                silentSince[candidate.pid] = now
                                return now
                            }()
                            if now - firstMismatch < 0.25 {
                                resolvedPlaying = true
                                let checkDeadline = firstMismatch + 0.25
                                nextSilenceCheck = nextSilenceCheck.map { min($0, checkDeadline) } ?? checkDeadline
                            } else {
                                resolvedPlaying = false
                            }
                        } else {
                            silentSince.removeValue(forKey: candidate.pid)
                            resolvedPlaying = false
                            let wasPreviouslySelected = (candidate.pid == selected?.pid)
                            if let deadID = deadBrowserIdentity[candidate.pid], deadID == currentIdentity {
                                resolvedHasTrack = false
                            } else if !audioActivePIDs.contains(candidate.pid) && !wasPreviouslySelected && now >= commandGraceUntil {
                                // Ignore stale paused browser sessions that never actively played audio.
                                resolvedHasTrack = false
                            }
                        }
                    }
                } else {
                    silentSince.removeValue(forKey: candidate.pid)
                    if !resolvedHasTrack {
                        audioActivePIDs.remove(candidate.pid)
                    }
                }

                guard resolvedPlaying != source.isPlaying || resolvedHasTrack != source.hasTrack else {
                    return (candidate, source)
                }
                return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                       isMusicApp: source.isMusicApp, isPlaying: resolvedPlaying,
                                                       hasTrack: resolvedHasTrack, displayName: source.displayName))
            }
        }
        lock.lock()
        if let selection {
            let app = NSRunningApplication(processIdentifier: selection.pid)
            let ended = app == nil || app?.isTerminated == true
                || app.flatMap(resolvedBundleIdentifier(for:)) != selection.bundleIdentifier
            let lostTrack = ready.contains { $0.1.selection == selection && !$0.1.hasTrack }
            if ready.contains(where: { $0.1.selection == selection && $0.1.hasTrack }) { releaseAt = nil }
            // A browser clears its track between videos. The choice outlasts
            // five seconds without one, while the automatic player fills in.
            if lostTrack, releaseAt == nil { releaseAt = now + 5 }
            let expired = releaseAt.map { now >= $0 } == true
            if ended || expired {
                self.selection = nil
                releaseAt = nil
            }
        }
        let requested = selection
        let bridging = requested != nil && releaseAt != nil
        // The chooser keeps the chosen row, and its checkmark, during a gap.
        sources = ready.map(\.1).filter { $0.hasTrack || bridging && $0.selection == requested }
            .sorted { $0.pid < $1.pid }
        lock.unlock()
        discovered = true
        // An unanswered selected player stays selected, but exposes no stale
        // controls. The empty surface still lets the user choose another one.
        if let requested, !bridging,
           !ready.contains(where: { $0.1.selection == requested && $0.1.hasTrack }) { return nil }
        let source = NotchPlaybackSource.preferred(in: ready.map(\.1), previousPID: target?.pid,
                                                   systemPID: currentPID, selection: requested,
                                                   includeOtherPlayers: includeOtherPlayers)
        guard var chosen = ready.first(where: { $0.1 == source })?.0 else { return nil }
        typealias IsSystemPlayer = @convention(c) (AnyObject, Selector) -> Bool
        let systemPlayer = ["isSystemMediaApplication", "isSystemPodcastsApplication", "isSystemBooksApplication"].contains { name in
            let selector = NSSelectorFromString(name)
            guard chosen.path.responds(to: selector) else { return false }
            return unsafeBitCast(chosen.path.method(for: selector), to: IsSystemPlayer.self)(chosen.path, selector)
        }
        // A third-party player without Automation can receive native commands
        // while it owns the system session. Recheck that ownership at delivery.
        chosen.requiresCurrentPlayer = !systemPlayer && chosen.pid == currentPID
        chosen.allowsDirectCommands = (systemPlayer
            && stringConstant("kMRMediaRemoteOptionNowPlayingContentItemID") != nil)
            || chosen.requiresCurrentPlayer
        return chosen
    }

    @discardableResult
    static func publish(_ target: Target?, info: [String: Any] = [:]) -> NotchPlaybackContext? {
        lock.lock()
        defer { lock.unlock() }
        guard var target, let next = Identity(info) else {
            selected = target; identity = nil; context = nil
            return nil
        }
        // Position and play/pause updates do not end a recording. Without an
        // item ID, use only observable recording metadata for its revision.
        if selected?.pid != target.pid || selected?.bundleIdentifier != target.bundleIdentifier
            || identity != next {
            context = NotchPlaybackContext(pid: target.pid, revision: UUID())
        }
        target.itemIdentifier = next.item
        // Some players expose Play and Pause separately. Use the command for
        // the displayed state, keeping Toggle for players without either one.
        target.playPauseCommand = playPauseCommand(for: info)
        selected = target
        identity = next
        return context
    }

    /// A supported-command callback may finish after the metadata snapshot.
    /// Update only the same selected path and recording, without polling again.
    static func updatePlayPauseCommand(for target: Target, info: [String: Any]) {
        guard let next = Identity(info) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var current = selected, current.path === target.path,
              current.pid == target.pid, current.bundleIdentifier == target.bundleIdentifier,
              identity == next else { return }
        current.playPauseCommand = playPauseCommand(for: info)
        selected = current
    }

    static func validatedTarget(for requested: NotchPlaybackContext) -> Target? {
        lock.lock()
        let target = context == requested ? selected : nil
        let expected = identity
        lock.unlock()
        guard let target, let expected, target.isRunning else { return nil }
        // The actual player can advance before its change notification reaches
        // our reader. Re-read this path without changing music source selection.
        let group = DispatchGroup()
        let resultLock = NSLock()
        var fresh: Identity?
        group.enter()
        readInfo(target, artwork: false, queue: callbacks) { info in
            resultLock.lock()
            fresh = (info as? [String: Any]).flatMap(Identity.init)
            resultLock.unlock()
            group.leave()
        }
        guard group.wait(timeout: .now() + 1) == .success else { return nil }
        resultLock.lock()
        let matches = fresh == expected
        resultLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        guard matches, context == requested, identity == expected,
              let current = selected, current.path === target.path, current.isRunning else { return nil }
        return current
    }

    static func readInfo(_ target: Target, artwork: Bool, queue: DispatchQueue,
                         completion: @escaping (NSDictionary?) -> Void) {
        typealias Read = @convention(c) (AnyObject, Bool, DispatchQueue,
            @escaping @convention(block) (NSDictionary?, UnsafeRawPointer?) -> Void) -> Void
        typealias CopyArtwork = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFData>?
        guard target.isRunning,
              let read = function(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer", as: Read.self) else {
            completion(nil); return
        }
        read(target.path, artwork, queue) { info, cover in
            guard let info else { completion(nil); return }
            let result = info.mutableCopy() as! NSMutableDictionary
            if let cover, let copy = function(handle, "MRNowPlayingArtworkCopyImageData", as: CopyArtwork.self),
               let data = copy(cover)?.takeRetainedValue() {
                result["kMRMediaRemoteNowPlayingInfoArtworkData"] = data as Data
            }
            completion(result)
        }
    }

    static func supportedCommands(_ target: Target, queue: DispatchQueue, completion: @escaping (NSArray?) -> Void) {
        typealias Read = @convention(c) (AnyObject, DispatchQueue, @escaping @convention(block) (NSArray?) -> Void) -> Void
        guard let read = function(handle, "MRMediaRemoteGetSupportedCommandsForPlayer", as: Read.self) else {
            completion(nil); return
        }
        read(target.path, queue, completion)
    }

    /// Whether the player says it is playing, as the system's Now Playing
    /// shows it. Nil when the state is unknown or cannot be read.
    static func readPlaybackState(_ target: Target, queue: DispatchQueue, completion: @escaping (Bool?) -> Void) {
        typealias Read = @convention(c) (AnyObject, DispatchQueue, @escaping @convention(block) (UInt32) -> Void) -> Void
        guard target.isRunning,
              let read = function(handle, "MRMediaRemoteGetPlaybackStateForPlayer", as: Read.self) else {
            completion(nil); return
        }
        read(target.path, queue) { state in
            // 1 playing; 2 paused, 3 stopped, 4 interrupted. Unknown (0)
            // and seeking (5) leave the rate to decide.
            switch state {
            case 1: completion(true)
            case 2, 3, 4: completion(false)
            default: completion(nil)
            }
        }
    }

    private static func currentPlayerPID() -> Int32? {
        typealias Read = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
        typealias PID = @convention(c) (AnyObject) -> Int32
        guard let read = function(handle, "MRMediaRemoteGetNowPlayingClient", as: Read.self),
              let getPID = function(handle, "MRNowPlayingClientGetProcessIdentifier", as: PID.self) else { return nil }
        let group = DispatchGroup()
        let resultLock = NSLock()
        var pid: Int32?
        group.enter()
        read(callbacks) { client in
            resultLock.lock()
            pid = client.map(getPID)
            resultLock.unlock()
            group.leave()
        }
        guard group.wait(timeout: .now() + 0.5) == .success else { return nil }
        return resultLock.withLock { pid }
    }

    @discardableResult
    static func send(_ command: Int32, options: CFDictionary? = nil, to target: Target) -> Bool {
        typealias Send = @convention(c) (Int32, CFDictionary?, AnyObject, UInt32, DispatchQueue,
            @escaping @convention(block) (UInt32, NSArray?) -> Void) -> Bool
        guard target.isRunning, target.allowsDirectCommands,
              !target.requiresCurrentPlayer || currentPlayerPID() == target.pid,
              let send = function(handle, "MRMediaRemoteSendCommandToPlayer", as: Send.self) else { return false }
        // The service may redirect unprivileged requests to the global player.
        // Scope to the recording when possible; an unidentified recording is
        // allowed only while this process remains the current system player.
        var scoped = (options as? [String: Any]) ?? [:]
        if let item = target.itemIdentifier,
           let itemKey = stringConstant("kMRMediaRemoteOptionNowPlayingContentItemID") {
            scoped[itemKey] = item
        } else if !target.requiresCurrentPlayer { return false }
        let settings = scoped.isEmpty ? nil : scoped as CFDictionary
        let group = DispatchGroup()
        let resultLock = NSLock()
        var delivered = false
        group.enter()
        guard send(command, settings, target.path, 0, callbacks, { error, responses in
            resultLock.lock()
            delivered = error == 0 && (responses as? [NSNumber])?.contains(where: { $0.intValue == 0 }) == true
            resultLock.unlock()
            group.leave()
        }) else { return false }
        guard group.wait(timeout: .now() + 2) == .success else { return false }
        return resultLock.withLock { delivered }
    }

    static func stringConstant(_ name: String) -> String? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return symbol.assumingMemoryBound(to: NSString?.self).pointee as String?
    }

    private static func isMusicApp(_ app: NSRunningApplication, parentBundleIdentifier: String? = nil) -> Bool {
        let category = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        return NotchPlaybackSource.isMusicApplication(bundleIdentifier: resolvedBundleIdentifier(for: app),
                                                      parentBundleIdentifier: parentBundleIdentifier, category: category)
    }

    private static func resolvedBundleIdentifier(for app: NSRunningApplication) -> String? {
        app.bundleIdentifier ?? app.bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    private static func makeTarget(_ app: NSRunningApplication) -> Target? {
        guard !app.isTerminated, let identifier = resolvedBundleIdentifier(for: app),
              let pathClass = NSClassFromString("MRPlayerPath"),
              let clientClass = NSClassFromString("MRClient"),
              class_getClassMethod(pathClass, NSSelectorFromString("localPlayerPath")) != nil,
              class_getInstanceMethod(clientClass, NSSelectorFromString("initWithBundleIdentifier:")) != nil,
              let localPath = (pathClass as AnyObject).perform(NSSelectorFromString("localPlayerPath"))?.takeUnretainedValue() as? NSObject,
              let path = localPath.copy() as? NSObject,
              let allocation = (clientClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue(),
              let client = allocation.perform(NSSelectorFromString("initWithBundleIdentifier:"), with: identifier)?.takeUnretainedValue() as? NSObject else { return nil }
        // The native local path is shared. Only mutate our own copy, otherwise
        // constructing the next candidate redirects previously selected paths.
        typealias SetPID = @convention(c) (AnyObject, Selector, Int32) -> Void
        let setPID = NSSelectorFromString("setProcessIdentifier:")
        guard client.responds(to: setPID), path.responds(to: NSSelectorFromString("setClient:")),
              path.responds(to: NSSelectorFromString("setPlayer:")) else { return nil }
        unsafeBitCast(client.method(for: setPID), to: SetPID.self)(client, setPID, app.processIdentifier)
        path.perform(NSSelectorFromString("setClient:"), with: client)
        // Nil resolves this app's active player; "default" is a different player
        // for apps which publish multiple sessions.
        path.perform(NSSelectorFromString("setPlayer:"), with: nil)
        return Target(pid: app.processIdentifier, bundleIdentifier: identifier, path: path)
    }
}

