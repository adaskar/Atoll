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
        var resolvedIsPlaying: Bool?

        var isRunning: Bool {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return app.bundleIdentifier == bundleIdentifier
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
    private static var silenceCheckAt: TimeInterval?
    private static var commandGraceUntil: TimeInterval = 0
    private static var audioActivePIDs: Set<Int32> = []
    private static var silentSince: [Int32: TimeInterval] = [:]
    private static var deadBrowserIdentity: [Int32: Identity] = [:]
    private static var lastActiveSafariTabPIDs: Set<Int32> = []
    private static var safariTabClosed = false
    /// Set before the watch starts; the one-shot reader does not use selection.
    static var includeOtherPlayers = false

    static func noteCommandSent() {
        let currentTabs = activeSafariWebContentPIDs(in: NSWorkspace.shared.runningApplications)
        lock.lock()
        commandGraceUntil = ProcessInfo.processInfo.systemUptime + 2.5
        lastActiveSafariTabPIDs = currentTabs
        safariTabClosed = false
        lock.unlock()
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
        let now = ProcessInfo.processInfo.systemUptime
        var next: TimeInterval?
        if selection != nil, let releaseAt, releaseAt > now {
            next = releaseAt
        }
        if let silenceCheckAt, silenceCheckAt > now {
            next = next.map { min($0, silenceCheckAt) } ?? silenceCheckAt
        }
        return next
    }

    static func choose(_ requested: NotchPlaybackSource.Selection?) {
        lock.lock(); defer { lock.unlock() }
        guard requested == nil || sources.contains(where: { $0.selection == requested && $0.hasTrack }) else { return }
        selection = requested
        releaseAt = nil
    }

    private struct Identity: Equatable {
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
        let runningApps = NSWorkspace.shared.runningApplications
        let currentSafariTabPIDs = activeSafariWebContentPIDs(in: runningApps)
        let musicPIDs = runningApps.filter { isMusicApp($0) }.map(\.processIdentifier)
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
        struct CandidateMetrics {
            let identity: Identity?
            let hasPausedTrack: Bool
            let duration: Double
            let estimatedElapsed: Double
        }
        var candidates: [(Target, NotchPlaybackSource, CandidateMetrics)] = []
        // A rate the player has not updated would rank a paused song as
        // playing. Its own state wins where it answers in time.
        var states: [Int32: Bool] = [:]
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
            if let parentID = candidate.applicationBundleIdentifier {
                let parentApps = NSRunningApplication.runningApplications(withBundleIdentifier: parentID)
                if parentApps.isEmpty || parentApps.allSatisfy({ $0.isTerminated }) {
                    continue
                }
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
                let candidateIdentity = Identity(dict)
                let isMusic = isMusicApp(app, parentBundleIdentifier: candidate.applicationBundleIdentifier)
                let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                let ratePlaying = rate > 0
                let hasTitle = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
                let elapsed = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
                let timestamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
                let age = timestamp.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                let estimatedElapsed = elapsed + (ratePlaying ? age * max(0, rate) : 0)
                let hasLiveTimeline = isMusic || (duration > 0 && elapsed > 0 && estimatedElapsed <= duration + 1.5) || (duration <= 0 && elapsed > 0)
                let source = NotchPlaybackSource(pid: candidate.pid, bundleIdentifier: candidate.bundleIdentifier,
                    isMusicApp: isMusic,
                    isPlaying: ratePlaying,
                    hasTrack: hasTitle && (ratePlaying || hasLiveTimeline),
                    displayName: presentation[candidate.pid]?.name ?? app.localizedName)
                let metrics = CandidateMetrics(
                    identity: candidateIdentity,
                    hasPausedTrack: hasTitle && hasLiveTimeline,
                    duration: duration,
                    estimatedElapsed: estimatedElapsed
                )
                resultsLock.lock()
                candidates.append((candidate, source, metrics))
                resultsLock.unlock()
                group.leave()
            }
        }
        // Keep completed reads when an unrelated client misses the deadline.
        _ = group.wait(timeout: .now() + 1)
        _ = stateReads.wait(timeout: .now() + 0.2)
        let now = ProcessInfo.processInfo.systemUptime
        resultsLock.lock()
        let rawCandidates = candidates
        let currentStates = states
        resultsLock.unlock()
        lock.lock()
        if !lastActiveSafariTabPIDs.subtracting(currentSafariTabPIDs).isEmpty {
            safariTabClosed = true
        }
        var nextSilenceCheck: TimeInterval?
        let ready = rawCandidates.map { candidate, source, metrics -> (Target, NotchPlaybackSource) in
            let mrPlaying = currentStates[candidate.pid] ?? source.isPlaying
            if source.isMusicApp {
                return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                       isMusicApp: true, isPlaying: mrPlaying,
                                                       hasTrack: source.hasTrack, displayName: source.displayName))
            }
            let isSafariCandidate = candidate.bundleIdentifier.hasPrefix("com.apple.WebKit")
                || candidate.applicationBundleIdentifier == "com.apple.Safari"
                || candidate.bundleIdentifier == "com.apple.Safari"
            let audioRunning = isAudioOutputRunning(
                for: candidate.pid,
                bundleIdentifier: candidate.applicationBundleIdentifier ?? candidate.bundleIdentifier
            )
            if audioRunning {
                if currentStates[candidate.pid] == false && !source.isPlaying {
                    let drainDeadline = now + 0.25
                    nextSilenceCheck = nextSilenceCheck.map { min($0, drainDeadline) } ?? drainDeadline
                    return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                           isMusicApp: false, isPlaying: false,
                                                           hasTrack: metrics.hasPausedTrack,
                                                           displayName: source.displayName))
                }
                audioActivePIDs.insert(candidate.pid)
                silentSince[candidate.pid] = nil
                deadBrowserIdentity[candidate.pid] = nil
                if isSafariCandidate {
                    lastActiveSafariTabPIDs = currentSafariTabPIDs
                    safariTabClosed = false
                }
                return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                       isMusicApp: false, isPlaying: true,
                                                       hasTrack: source.hasTrack || metrics.hasPausedTrack,
                                                       displayName: source.displayName))
            }
            if (metrics.identity != nil && deadBrowserIdentity[candidate.pid] == metrics.identity)
                || (isSafariCandidate && safariTabClosed && now >= commandGraceUntil) {
                if let id = metrics.identity { deadBrowserIdentity[candidate.pid] = id }
                audioActivePIDs.remove(candidate.pid)
                silentSince[candidate.pid] = nil
                return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                       isMusicApp: false, isPlaying: false,
                                                       hasTrack: false, displayName: source.displayName))
            }
            if mrPlaying {
                // MediaRemote claims this browser/helper is actively playing,
                // but CoreAudio reports zero audio output.
                if (metrics.duration > 0 && metrics.estimatedElapsed > metrics.duration + 1.5)
                    || (!audioActivePIDs.contains(candidate.pid) && now >= commandGraceUntil) {
                    if let id = metrics.identity { deadBrowserIdentity[candidate.pid] = id }
                    audioActivePIDs.remove(candidate.pid)
                    silentSince[candidate.pid] = nil
                    return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                           isMusicApp: false, isPlaying: false,
                                                           hasTrack: false, displayName: source.displayName))
                }
                let grace: TimeInterval = (now < commandGraceUntil) ? 2.5 : 0.25
                let started = silentSince[candidate.pid] ?? now
                silentSince[candidate.pid] = started
                let deadline = started + grace
                if now < deadline {
                    nextSilenceCheck = nextSilenceCheck.map { min($0, deadline) } ?? deadline
                    return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                           isMusicApp: false, isPlaying: true,
                                                           hasTrack: source.hasTrack || metrics.hasPausedTrack,
                                                           displayName: source.displayName))
                }
                // Grace expired while MediaRemote still claims playing and CoreAudio is silent:
                // this is a dead zombie session from a closed browser tab.
                if let id = metrics.identity { deadBrowserIdentity[candidate.pid] = id }
                audioActivePIDs.remove(candidate.pid)
                return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                       isMusicApp: false, isPlaying: false,
                                                       hasTrack: false, displayName: source.displayName))
            } else {
                silentSince[candidate.pid] = nil
                let hasTrack = (now < commandGraceUntil) ? (source.hasTrack || metrics.hasPausedTrack) : metrics.hasPausedTrack
                if hasTrack && isSafariCandidate {
                    let checkDeadline = now + 1.0
                    nextSilenceCheck = nextSilenceCheck.map { min($0, checkDeadline) } ?? checkDeadline
                }
                return (candidate, NotchPlaybackSource(pid: source.pid, bundleIdentifier: source.bundleIdentifier,
                                                       isMusicApp: false, isPlaying: false,
                                                       hasTrack: hasTrack,
                                                       displayName: source.displayName))
            }
        }
        silenceCheckAt = nextSilenceCheck
        if let selection {
            let app = NSRunningApplication(processIdentifier: selection.pid)
            let ended = app == nil || app?.isTerminated == true || app?.bundleIdentifier != selection.bundleIdentifier
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
        chosen.resolvedIsPlaying = source?.isPlaying
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
        return NotchPlaybackSource.isMusicApplication(bundleIdentifier: app.bundleIdentifier,
                                                      parentBundleIdentifier: parentBundleIdentifier, category: category)
    }

    private static func makeTarget(_ app: NSRunningApplication) -> Target? {
        guard !app.isTerminated, let identifier = app.bundleIdentifier,
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

    private static func activeSafariWebContentPIDs(in applications: [NSRunningApplication]) -> Set<Int32> {
        Set(
            applications.compactMap { app -> Int32? in
                guard !app.isTerminated,
                      app.bundleIdentifier == "com.apple.WebKit.WebContent" else { return nil }
                let name = app.localizedName ?? ""
                guard !name.contains("(Cached)"), !name.contains("(Prewarmed)") else { return nil }
                return app.processIdentifier
            }
        )
    }

    static func isAudioOutputRunning(for pid: Int32, bundleIdentifier: String? = nil) -> Bool {
        var pidValue = pid_t(pid)
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var translateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translateAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &processObject
        ) == noErr, processObject != kAudioObjectUnknown {
            if isAudioProcessRunningOutput(processObject) {
                return true
            }
        }

        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &listSize
        ) == noErr, listSize > 0 else { return false }

        let count = Int(listSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &listSize,
            &objects
        ) == noErr else { return false }

        for obj in objects where isAudioProcessRunningOutput(obj) {
            var objPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &objPID) == noErr, objPID == pid {
                return true
            }

            var bundleRef: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(obj, &bundleAddr, 0, nil, &bundleSize, &bundleRef) == noErr,
               let objBundle = bundleRef?.takeRetainedValue() as String?, !objBundle.isEmpty {
                if objBundle == bundleIdentifier || objBundle.hasPrefix(bundleIdentifier + ".") {
                    return true
                }
            }
        }

        return false
    }

    private static func isAudioProcessRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(objectID, &outAddr, 0, nil, &size, &running) == noErr, running != 0 {
            return true
        }
        return false
    }
}
