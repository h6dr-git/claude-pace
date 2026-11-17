import Foundation

@main
struct UsageProviderSelectionTestMain {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static var failures = 0

    static func main() throws {
        try testFreshOfficialCodexEntitlementDrivesPrimaryRing()
        try testTenMinuteBoundaryRemainsFresh()
        try testSnapshotOlderThanTenMinutesIsUnavailable()
        testMissingSnapshotIsUnavailable()
        try testMissingAndFarFutureCaptureTimesAreUnavailable()
        try testProviderTransitionSuppressesFreshCodexSnapshot()
        testProviderEnvironmentParsingIsExplicitOptInAndFailClosed()
        try testMalformedOrUnofficialEntitlementIsUnavailable()
        try testOfficialUnlimitedEntitlementIsUsableWithoutRateWindow()
        testUnavailablePresentationIsExplicitAndDoesNotClaimUsage()
        testClaudeProviderParsingIsExplicitOptInAndFailClosed()
        testClaudeModeShowsFreshUsableSnapshot()
        testClaudeModeWithoutUsableReadingNamesTheCause()
        testBrokenCollectorDoesNotBlankAStillFreshReading()
        try testClaudeModeIgnoresFreshCodexSnapshot()
        testUnknownCollectorSchemaIsTreatedAsBlocked()
        testClaudeUnavailablePresentationDoesNotClaimUsage()
        testEndedWindowsDropTheirPercentage()
        testWindowReadingNamesWhyThereIsNoNumber()
        testFreshnessMarksOldReadings()
        testClaudeModeIngestsClaudeHistoryOnly()
        try testFiveHourAbsenceDecodesAndCarriesThrough()
        try testAutoRingPicksTheTightestLimit()
        testRingTieBreaks()
        try testPinnedRingFallsBackToAuto()
        try testRingSettingsParsing()
        testPlanningLineArithmetic()
        try testModelBucketsAreFirstClass()
        testOnlyABucketStillDrivesTheRing()
        testFooterModelOnlyForStatusLineReadings()
        try testNoFiveHourLimitLineReplacesEndedWindowText()
        try testRingSubmenuOptions()
        try testCompositionKeepsOtherProvidersAsTheyWere()
        try testPreviewText()

        guard failures == 0 else {
            fputs("FAIL: \(failures) usage-provider assertions failed\n", stderr)
            exit(1)
        }
        print("PASS: AI Usage provider-selection assertions")
    }

    private static func expect(
        _ actual: PrimaryUsageDecision,
        equals expected: PrimaryUsageDecision,
        _ name: String
    ) {
        if actual != expected {
            failures += 1
            fputs("FAIL: \(name): expected \(expected), got \(actual)\n", stderr)
        }
    }

    private static func expect(_ condition: Bool, _ name: String) {
        if !condition {
            failures += 1
            fputs("FAIL: \(name)\n", stderr)
        }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        if actual != expected {
            failures += 1
            fputs("FAIL: \(name)\n  expected: \(expected)\n  actual:   \(actual)\n", stderr)
        }
    }

    private static func testFreshOfficialCodexEntitlementDrivesPrimaryRing() throws {
        let snapshot = try makeSnapshot(capturedAt: now.timeIntervalSince1970 - 599)
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: snapshot,
                now: now
            ),
            equals: .codex,
            "fresh Codex snapshot"
        )
    }

    private static func testTenMinuteBoundaryRemainsFresh() throws {
        let snapshot = try makeSnapshot(
            capturedAt: now.timeIntervalSince1970
                - PrimaryUsageSelector.maximumCodexSnapshotAge
        )
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: snapshot,
                now: now
            ),
            equals: .codex,
            "ten-minute boundary"
        )
    }

    private static func testSnapshotOlderThanTenMinutesIsUnavailable() throws {
        let snapshot = try makeSnapshot(
            capturedAt: now.timeIntervalSince1970
                - PrimaryUsageSelector.maximumCodexSnapshotAge - 1
        )
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: snapshot,
                now: now
            ),
            equals: .grokUnavailable(.staleCodexSnapshot),
            "stale Codex snapshot"
        )
    }

    private static func testMissingSnapshotIsUnavailable() {
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: nil,
                now: now
            ),
            equals: .grokUnavailable(.missingCodexSnapshot),
            "missing Codex snapshot"
        )
    }

    private static func testMissingAndFarFutureCaptureTimesAreUnavailable() throws {
        let missing = try makeSnapshot(capturedAt: nil)
        let future = try makeSnapshot(
            capturedAt: now.timeIntervalSince1970
                + PrimaryUsageSelector.maximumClockSkew + 1
        )
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: missing,
                now: now
            ),
            equals: .grokUnavailable(.staleCodexSnapshot),
            "missing capture timestamp"
        )
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: future,
                now: now
            ),
            equals: .grokUnavailable(.staleCodexSnapshot),
            "future capture timestamp"
        )
    }

    private static func testProviderTransitionSuppressesFreshCodexSnapshot() throws {
        let snapshot = try makeSnapshot(capturedAt: now.timeIntervalSince1970)
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .grokTransition,
                codexSnapshot: snapshot,
                now: now
            ),
            equals: .grokUnavailable(.providerTransition),
            "provider transition hides fresh Codex"
        )
        expect(
            !PrimaryUsageProviderMode.grokTransition.shouldPollCodex,
            "provider transition stops Codex polling"
        )
        expect(
            !PrimaryUsageProviderMode.grokTransition.shouldIngestCodexHistory,
            "provider transition stops Codex session ingestion"
        )
        expect(
            PrimaryUsageProviderMode.codex.shouldIngestCodexHistory,
            "Codex mode keeps Codex session ingestion"
        )
    }

    private static func testProviderEnvironmentParsingIsExplicitOptInAndFailClosed() {
        expect(
            PrimaryUsageProviderMode.from(environment: [:]) == .grokTransition,
            "missing provider setting fails closed"
        )
        expect(
            PrimaryUsageProviderMode.from(
                environment: [PrimaryUsageProviderMode.environmentKey: "   \n"]
            ) == .grokTransition,
            "blank provider setting fails closed"
        )
        expect(
            PrimaryUsageProviderMode.from(
                environment: [PrimaryUsageProviderMode.environmentKey: "grok"]
            ) == .grokTransition,
            "Grok provider setting"
        )
        expect(
            PrimaryUsageProviderMode.from(
                environment: [PrimaryUsageProviderMode.environmentKey: "unexpected"]
            ) == .grokTransition,
            "unknown explicit provider fails closed"
        )
        expect(
            PrimaryUsageProviderMode.from(
                environment: [PrimaryUsageProviderMode.environmentKey: "  CoDeX  "]
            ) == .codex,
            "only an explicit Codex provider setting enables Codex"
        )
        expect(
            PrimaryUsageProviderMode.codex.shouldPollCodex,
            "explicit Codex mode enables Codex polling"
        )
        expect(
            PrimaryUsageProviderMode.codex.shouldIngestCodexHistory,
            "explicit Codex mode enables Codex session ingestion"
        )
    }

    private static func testMalformedOrUnofficialEntitlementIsUnavailable() throws {
        let invalidPercent = try makeSnapshot(
            capturedAt: now.timeIntervalSince1970,
            usedPercent: 101
        )
        let unofficial = try makeSnapshot(
            source: "copied-cache",
            capturedAt: now.timeIntervalSince1970
        )
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: invalidPercent,
                now: now
            ),
            equals: .grokUnavailable(.invalidCodexEntitlement),
            "invalid entitlement"
        )
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: unofficial,
                now: now
            ),
            equals: .grokUnavailable(.invalidCodexEntitlement),
            "unofficial entitlement source"
        )
    }

    private static func testOfficialUnlimitedEntitlementIsUsableWithoutRateWindow() throws {
        let snapshot = try makeSnapshot(
            capturedAt: now.timeIntervalSince1970,
            usedPercent: nil,
            unlimited: true
        )
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .codex,
                codexSnapshot: snapshot,
                now: now
            ),
            equals: .codex,
            "official unlimited entitlement"
        )
    }

    private static func testUnavailablePresentationIsExplicitAndDoesNotClaimUsage() {
        expect(
            GrokUsageUnavailablePresentation.toolTip
                == "Grok 사용량: 공식 기계판독 불가",
            "explicit Grok unavailable message"
        )
        expect(
            !GrokUsageUnavailablePresentation.toolTip.contains("%"),
            "unavailable message does not invent a percentage"
        )
    }

    // MARK: - Claude provider

    private static func testClaudeProviderParsingIsExplicitOptInAndFailClosed() {
        expect(
            PrimaryUsageProviderMode.from(
                environment: [PrimaryUsageProviderMode.environmentKey: "  ClAuDe  "]
            ) == .claude,
            "only an explicit Claude provider setting enables Claude"
        )
        expect(
            PrimaryUsageProviderMode.claude.shouldPollClaude,
            "explicit Claude mode enables Claude polling"
        )
        // The whole point of the Grok-era fail-closed rule: switching the
        // primary provider must not quietly restart Codex account access.
        expect(
            !PrimaryUsageProviderMode.claude.shouldPollCodex,
            "Claude mode does not poll Codex"
        )
        expect(
            !PrimaryUsageProviderMode.claude.shouldIngestCodexHistory,
            "Claude mode does not ingest Codex sessions"
        )
        expect(
            !PrimaryUsageProviderMode.codex.shouldPollClaude,
            "Codex mode does not poll Claude"
        )
        expect(
            !PrimaryUsageProviderMode.grokTransition.shouldPollClaude,
            "Grok transition does not poll Claude"
        )
    }

    private static func testClaudeModeShowsFreshUsableSnapshot() {
        expect(
            decideClaude(makeClaudeSnapshot(capturedAt: now.timeIntervalSince1970)),
            equals: .claude,
            "fresh Claude snapshot"
        )
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970
                        - PrimaryUsageSelector.maximumClaudeSnapshotAge
                )
            ),
            equals: .claude,
            "24-hour boundary remains usable"
        )
        // Weekly-only output is the shape `/usage` prints between session
        // windows; it must still drive the ring instead of reading as 0%.
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970,
                    fiveHour: nil,
                    sevenDay: RLWindow(used_percentage: 41, resets_at: now.timeIntervalSince1970 + 3600)
                )
            ),
            equals: .claude,
            "weekly-only reading is usable"
        )
    }

    private static func testClaudeModeWithoutUsableReadingNamesTheCause() {
        expect(
            decideClaude(nil),
            equals: .claudeUnavailable(.missingSnapshot),
            "missing Claude snapshot"
        )
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970
                        - PrimaryUsageSelector.maximumClaudeSnapshotAge - 1
                )
            ),
            equals: .claudeUnavailable(.staleSnapshot),
            "stale Claude snapshot"
        )
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970
                        + PrimaryUsageSelector.maximumClockSkew + 1
                )
            ),
            equals: .claudeUnavailable(.staleSnapshot),
            "future Claude capture timestamp"
        )
        // A null percentage is "no reading", and a percentage without a reset
        // instant has no window to measure — neither may render as 0% used.
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970,
                    fiveHour: RLWindow(used_percentage: nil, resets_at: now.timeIntervalSince1970 + 60),
                    sevenDay: nil
                )
            ),
            equals: .claudeUnavailable(.noUsableWindow),
            "null percentage is not a reading"
        )
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970,
                    fiveHour: RLWindow(used_percentage: 12, resets_at: nil),
                    sevenDay: nil
                )
            ),
            equals: .claudeUnavailable(.noUsableWindow),
            "percentage without a reset instant is not a reading"
        )
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970,
                    fiveHour: RLWindow(used_percentage: 140, resets_at: now.timeIntervalSince1970 + 60),
                    sevenDay: nil
                )
            ),
            equals: .claudeUnavailable(.noUsableWindow),
            "out-of-range percentage is not a reading"
        )
        // With nothing to show, the actionable collector fault outranks the
        // symptom: say "log the CLI back in", not "no snapshot".
        expect(
            decideClaude(nil, collector: makeCollectorState("signed-out")),
            equals: .claudeUnavailable(.collectorBlocked(.signedOut)),
            "signed-out collector named ahead of the missing snapshot"
        )
        expect(
            decideClaude(
                makeClaudeSnapshot(
                    capturedAt: now.timeIntervalSince1970
                        - PrimaryUsageSelector.maximumClaudeSnapshotAge - 1
                ),
                collector: makeCollectorState("no-limits")
            ),
            equals: .claudeUnavailable(.collectorBlocked(.noLimits)),
            "no-limits collector named ahead of staleness"
        )
    }

    private static func testBrokenCollectorDoesNotBlankAStillFreshReading() {
        // The number is the last real account reading; the failure is reported
        // as its own menu line rather than by erasing it.
        expect(
            decideClaude(
                makeClaudeSnapshot(capturedAt: now.timeIntervalSince1970),
                collector: makeCollectorState("signed-out")
            ),
            equals: .claude,
            "fresh reading survives a broken collector"
        )
        expect(
            makeCollectorState("ok").parsedStatus?.blocksCollection == false,
            "ok collector does not block"
        )
        expect(
            makeCollectorState("signed-out").parsedStatus?.blocksCollection == true,
            "signed-out collector blocks"
        )
        // A `claude` call that hit the poll's time limit is named as such.
        expect(
            makeCollectorState("timed-out").parsedStatus == .timedOut,
            "timed-out collector status is recognised"
        )
        expect(
            makeCollectorState("timed-out").parsedStatus?.blocksCollection == true,
            "timed-out collector blocks"
        )
    }

    private static func testClaudeModeIgnoresFreshCodexSnapshot() throws {
        let codex = try makeSnapshot(capturedAt: now.timeIntervalSince1970)
        expect(
            PrimaryUsageSelector.decide(
                providerMode: .claude,
                codexSnapshot: codex,
                claudeSnapshot: nil,
                claudeCollectorState: nil,
                now: now
            ),
            equals: .claudeUnavailable(.missingSnapshot),
            "Claude mode never falls back to a fresh Codex snapshot"
        )
    }

    private static func testUnknownCollectorSchemaIsTreatedAsBlocked() {
        // A file from a future or foreign writer must not be read as success.
        let foreign = ClaudeCollectorState(
            schema: "something-else.v9", status: "ok",
            capturedAt: now.timeIntervalSince1970, detail: nil
        )
        expect(foreign.parsedStatus == nil, "foreign schema yields no status")
        expect(
            decideClaude(nil, collector: foreign),
            equals: .claudeUnavailable(.missingSnapshot),
            "foreign collector schema falls through to snapshot reasons"
        )
        let unknownStatus = makeCollectorState("teleported")
        expect(
            unknownStatus.parsedStatus?.blocksCollection == true,
            "unknown collector status blocks collection"
        )
    }

    private static func testClaudeUnavailablePresentationDoesNotClaimUsage() {
        expect(
            ClaudeUsageUnavailablePresentation.toolTip
                == "Claude 사용량: 공식 조회값 없음",
            "explicit Claude unavailable message"
        )
        expect(
            !ClaudeUsageUnavailablePresentation.toolTip.contains("%"),
            "Claude unavailable message does not invent a percentage"
        )
    }

    private static func testEndedWindowsDropTheirPercentage() {
        let t = now.timeIntervalSince1970
        let ended = RLWindow(used_percentage: 45, resets_at: t - 60).endingIfPast(at: now)
        expect(ended.used_percentage == nil, "ended window drops its percentage instead of reading 0%")
        expect(ended.resets_at == t - 60, "ended window keeps when it ended")
        expect(!ended.isUsable, "ended window is not a reading")
        expect(
            RLWindow(used_percentage: 45, resets_at: t).endingIfPast(at: now).used_percentage == nil,
            "a window ends exactly at its reset instant"
        )

        let open = RLWindow(used_percentage: 45, resets_at: t + 60).endingIfPast(at: now)
        expect(open.used_percentage == 45 && open.resets_at == t + 60, "open window is left as read")
        let noReset = RLWindow(used_percentage: 12, resets_at: nil).endingIfPast(at: now)
        expect(noReset.used_percentage == 12 && noReset.resets_at == nil, "window without a reset is left as read")

        // A day-old capture whose 5-hour window has ended still drives the ring
        // from the weekly window — never from an invented 0% (the old roll-forward
        // showed "5시간 0%" with a made-up reset for exactly this snapshot).
        let fiveEnded = makeClaudeSnapshot(
            capturedAt: t - 22 * 3600,
            fiveHour: RLWindow(used_percentage: 45, resets_at: t - 21 * 3600),
            sevenDay: RLWindow(used_percentage: 62, resets_at: t + 86_400)
        ).droppingEndedWindows(at: now)
        expect(fiveEnded.usableFiveHour == nil, "ended 5-hour window is not drawn")
        expect(fiveEnded.usableSevenDay?.used_percentage == 62, "weekly reading is still usable")
        expect(decideClaude(fiveEnded), equals: .claude, "weekly reading keeps Claude on screen")

        let allEnded = makeClaudeSnapshot(
            capturedAt: t - 22 * 3600,
            fiveHour: RLWindow(used_percentage: 45, resets_at: t - 21 * 3600),
            sevenDay: RLWindow(used_percentage: 62, resets_at: t - 3600)
        ).droppingEndedWindows(at: now)
        expect(
            decideClaude(allEnded),
            equals: .claudeUnavailable(.noUsableWindow),
            "every window ended is no reading, not 0%"
        )
    }

    private static func testWindowReadingNamesWhyThereIsNoNumber() {
        let t = now.timeIntervalSince1970
        let endedAfterPoll = makeClaudeSnapshot(
            capturedAt: t - 3600,
            fiveHour: RLWindow(used_percentage: 45, resets_at: t - 60)
        )
        expect(
            endedAfterPoll.reading(endedAfterPoll.fiveHour, at: now) == .endedSinceLastPoll(endedAt: t - 60),
            "window that ended after the last poll waits for the next one"
        )
        let dropped = endedAfterPoll.droppingEndedWindows(at: now)
        expect(
            dropped.reading(dropped.fiveHour, at: now) == .endedSinceLastPoll(endedAt: t - 60),
            "an ended window stays recognisable after its percentage is dropped"
        )

        // `/usage` omits the session line between 5-hour windows, so a poll after
        // the reset keeps the old window: nothing is open right now.
        let polledAfterReset = makeClaudeSnapshot(
            capturedAt: t - 30,
            fiveHour: RLWindow(used_percentage: 45, resets_at: t - 60)
        )
        expect(
            polledAfterReset.reading(polledAfterReset.fiveHour, at: now) == .noOpenWindow(endedAt: t - 60),
            "poll after the reset without a new window means none is open"
        )

        let open = makeClaudeSnapshot(
            capturedAt: t,
            fiveHour: RLWindow(used_percentage: 22, resets_at: t + 600)
        )
        expect(
            open.reading(open.fiveHour, at: now) == .current(used: 22, resetsAt: t + 600),
            "open window is a current reading"
        )
        expect(open.reading(nil, at: now) == .unavailable, "missing window is unavailable")
        expect(
            open.reading(RLWindow(used_percentage: 140, resets_at: t + 600), at: now) == .unavailable,
            "out-of-range percentage stays unavailable"
        )
    }

    private static func testFreshnessMarksOldReadings() {
        let t = now.timeIntervalSince1970
        expect(
            SnapshotFreshness.of(makeClaudeSnapshot(capturedAt: t), at: now) == .fresh,
            "new reading is fresh"
        )
        expect(
            SnapshotFreshness.of(makeClaudeSnapshot(capturedAt: t - SnapshotFreshness.staleAfter), at: now) == .fresh,
            "ten-minute boundary is still fresh"
        )
        expect(
            SnapshotFreshness.of(makeClaudeSnapshot(capturedAt: t - SnapshotFreshness.staleAfter - 1), at: now).isStale,
            "past ten minutes the reading is stale"
        )
        expect(
            SnapshotFreshness.of(makeClaudeSnapshot(capturedAt: t - 22 * 3600), at: now) == .stale(age: 22 * 3600),
            "stale reading reports its age"
        )
        expect(SnapshotFreshness.of(nil, at: now) == .unknown, "no snapshot has unknown freshness")
        expect(
            SnapshotFreshness.of(makeClaudeSnapshot(capturedAt: nil), at: now) == .unknown,
            "snapshot without a capture time has unknown freshness"
        )
        expect(!SnapshotFreshness.unknown.isStale, "unknown freshness is not reported as stale")
    }

    private static func testClaudeModeIngestsClaudeHistoryOnly() {
        expect(
            PrimaryUsageProviderMode.claude.shouldIngestClaudeHistory,
            "Claude mode collects Claude Code session records"
        )
        expect(
            !PrimaryUsageProviderMode.codex.shouldIngestClaudeHistory,
            "Codex mode leaves Claude session logs alone"
        )
        expect(
            !PrimaryUsageProviderMode.grokTransition.shouldIngestClaudeHistory,
            "transition mode collects nothing"
        )
    }

    // MARK: - Accounts without a 5-hour limit, model buckets, the ring

    /// The user's snapshot.json as captured on 2026-11-17 (Ultra account, no
    /// 5-hour limit any more; the ended window is the last one seen on 11/14).
    private static let realSnapshotJSON = """
    {"capturedAt": 1794875663, "fiveHour": {"used_percentage": 9, "resets_at": 1794637200.0}, \
    "sevenDay": {"used_percentage": 60, "resets_at": 1794978000.0}, "sevenDayOpus": null, \
    "sevenDaySonnet": null, "model": "Opus 5 (1M context)", "raw_rate_limits": {}, \
    "modelWindows": {"Fable": {"used_percentage": 91, "resets_at": 1794978000.0}}, "source": "usage-poll"}
    """
    /// Two minutes after that capture.
    private static let realNow = Date(timeIntervalSince1970: 1_794_875_663 + 120)
    private static let absentSince: Double = 1_794_637_260

    private static func decodeSnapshot(_ json: String) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    }

    /// The same reading once the collector has concluded there is no 5-hour limit.
    private static func absentSnapshot() throws -> Snapshot {
        try decodeSnapshot(
            realSnapshotJSON
                .replacingOccurrences(of: #""fiveHour": {"used_percentage": 9, "resets_at": 1794637200.0}"#, with: #""fiveHour": null"#)
                .replacingOccurrences(of: #""source": "usage-poll"}"#, with: #""source": "usage-poll", "fiveHourAbsentSince": 1794637260}"#)
        )
    }

    private static func texts(_ entries: [MenuEntry]) -> [String] {
        entries.compactMap { entry in
            switch entry {
            case .header(let text), .line(let text): return text
            case .bar(_, _, let text): return text
            case .separator: return nil
            }
        }
    }

    /// The rows from `header` up to the next separator.
    private static func section(_ header: String, in entries: [MenuEntry]) -> [MenuEntry]? {
        guard let start = entries.firstIndex(of: .header(header)) else { return nil }
        let rest = entries[entries.index(after: start)...]
        return Array(rest.prefix { $0 != .separator })
    }

    private static func barTexts(_ entries: [MenuEntry]) -> [String] {
        entries.compactMap { if case .bar(_, _, let text) = $0 { return text } else { return nil } }
    }

    private static func dayText(_ epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    private static func clockText(_ epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    private static func okCollector(at epoch: Double) -> ClaudeCollectorState {
        ClaudeCollectorState(schema: "claude-collector-state.v1", status: "ok", capturedAt: epoch, detail: "")
    }

    private static func testFiveHourAbsenceDecodesAndCarriesThrough() throws {
        let absent = try absentSnapshot()
        expectEqual(absent.fiveHourAbsentSince, absentSince, "fiveHourAbsentSince decodes")
        expect(absent.hasNoFiveHourLimit, "the key marks an account without a 5-hour limit")
        expect(absent.fiveHour == nil, "no 5-hour window alongside the key")
        expectEqual(absent.source, "usage-poll", "source decodes")
        let later = absent.droppingEndedWindows(at: Date(timeIntervalSince1970: 1_795_000_000))
        expectEqual(later.fiveHourAbsentSince, absentSince, "the key survives droppingEndedWindows")
        expectEqual(later.source, "usage-poll", "source survives droppingEndedWindows")
        expect(later.modelWindows?["Fable"]?.used_percentage == nil, "and ended buckets still lose their percentage")

        let today = try decodeSnapshot(realSnapshotJSON)
        expect(today.fiveHourAbsentSince == nil && !today.hasNoFiveHourLimit, "no key: today's 5-hour handling")

        // A wrong-typed extra must not cost the reading.
        let odd = try decodeSnapshot(realSnapshotJSON.replacingOccurrences(
            of: #""source": "usage-poll"}"#, with: #""source": 7, "fiveHourAbsentSince": "soon"}"#
        ))
        expect(odd.fiveHourAbsentSince == nil && odd.source == nil, "malformed extras read as absent")
        expectEqual(odd.sevenDay?.used_percentage, 60, "malformed extras keep the rest of the snapshot")

        // The key wins over a leftover 5-hour reading: nothing to draw for 5h.
        let t = now.timeIntervalSince1970
        let contradictory = Snapshot(
            capturedAt: t, fiveHour: RLWindow(used_percentage: 22, resets_at: t + 3600),
            sevenDay: RLWindow(used_percentage: 5, resets_at: t + 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil,
            fiveHourAbsentSince: t - 600, source: "usage-poll"
        )
        expect(contradictory.usableFiveHour == nil, "no 5-hour reading while the key is set")
        expect(!texts(UsageView(snapshot: contradictory, now: now).entries).contains("5시간"), "no 5-hour section")
    }

    private static func testAutoRingPicksTheTightestLimit() throws {
        let collector = okCollector(at: 1_794_875_663)
        let stored = try decodeSnapshot(realSnapshotJSON)
        let absent = try absentSnapshot()
        for (name, snapshot) in [("as stored", stored), ("absent key", absent)] {
            let choice = RingChoice.choose(.auto, in: snapshot, at: realNow)
            expectEqual(choice?.window, .model("Fable"), "\(name): auto ring picks Fable")
            expectEqual(choice?.candidate.used, 91, "\(name): at 91%")
            expect(choice?.fellBackFrom == nil, "\(name): auto never reports a fallback")

            let composition = MenuComposition.compose(
                providerMode: .claude, claudeSnapshot: snapshot, collectorState: collector, now: realNow
            )
            expectEqual(composition.ring?.window, .model("Fable"), "\(name): the menu bar draws Fable")
            expectEqual(composition.ring?.used, 91, "\(name): the menu bar draws 91%")
            expect(composition.ring?.dimmed == false, "\(name): a two-minute-old reading is not dimmed")
            expect(composition.toolTip.hasPrefix("AI Usage · Claude · 링 Fable 주간 91% · 주 60%"), "\(name): tooltip names the ring: \(composition.toolTip)")
            expect(texts(composition.entries).contains("Fable 주간 · 링"), "\(name): the Fable section is marked")
            expect(texts(composition.entries).contains("주간 (7일)"), "\(name): the weekly section is not")
        }

        // Older than ten minutes: still the same window, drawn faded.
        let stale = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: try absentSnapshot(),
            now: realNow.addingTimeInterval(20 * 60)
        )
        expect(stale.ring?.dimmed == true, "a stale reading dims the ring")
        expect(stale.toolTip.hasSuffix(" · 갱신 멈춤"), "a stale reading says so in the tooltip")
    }

    private static func testRingTieBreaks() {
        let t = now.timeIntervalSince1970
        func snapshot(week: Double?, five: Double?, models: [String: Double]) -> Snapshot {
            Snapshot(
                capturedAt: t,
                fiveHour: five.map { RLWindow(used_percentage: $0, resets_at: t + 3600) },
                sevenDay: week.map { RLWindow(used_percentage: $0, resets_at: t + 86_400) },
                sevenDayOpus: nil, sevenDaySonnet: nil,
                modelWindows: models.mapValues { RLWindow(used_percentage: $0, resets_at: t + 86_400) },
                model: nil
            )
        }
        func pick(_ s: Snapshot) -> RingWindow? { RingChoice.choose(.auto, in: s, at: now)?.window }
        expectEqual(pick(snapshot(week: 50, five: 50, models: ["Fable": 50])), .week, "tie: weekly first")
        expectEqual(pick(snapshot(week: 40, five: 50, models: ["Fable": 50])), .five, "tie: 5-hour before buckets")
        expectEqual(pick(snapshot(week: 40, five: nil, models: ["Beta": 70, "Alpha": 70])), .model("Alpha"), "tie: buckets by name")
        expectEqual(pick(snapshot(week: 10, five: 20, models: ["Fable": 30])), .model("Fable"), "the highest used% wins")
        expectEqual(pick(snapshot(week: 61, five: 9, models: ["Fable": 60])), .week, "the highest used% wins over the tie order")
        expect(pick(snapshot(week: nil, five: nil, models: [:])) == nil, "nothing usable: no ring window (drawn as ?)")
        expect(
            pick(snapshot(week: nil, five: nil, models: ["Fable": 140])) == nil,
            "an out-of-range bucket is not a reading"
        )
    }

    private static func testPinnedRingFallsBackToAuto() throws {
        let absent = try absentSnapshot()

        let five = RingChoice.choose(.pinned(.five), in: absent, at: realNow)
        expectEqual(five?.window, .model("Fable"), "pinned 5-hour without one falls back to auto")
        expectEqual(five?.fellBackFrom, .five, "and says what it fell back from")
        let fiveEntries = UsageView(snapshot: absent, now: realNow, ring: five).entries
        expect(texts(fiveEntries).contains("링: 5시간 지금 값 없음 · 자동으로 표시"), "the menu says so in one line")

        let gone = RingChoice.choose(.pinned(.model("Opus")), in: absent, at: realNow)
        expectEqual(gone?.window, .model("Fable"), "pinned bucket that is gone falls back")
        expectEqual(gone?.fellBackFrom, .model("Opus"), "naming the missing bucket")
        expect(
            texts(UsageView(snapshot: absent, now: realNow, ring: gone).entries).contains("링: Opus 주간 지금 값 없음 · 자동으로 표시"),
            "fallback line names the bucket"
        )

        let week = RingChoice.choose(.pinned(.week), in: absent, at: realNow)
        expectEqual(week?.window, .week, "a usable pinned window is kept even when another is higher")
        expect(week?.fellBackFrom == nil, "no fallback for a usable pinned window")
        let weekEntries = UsageView(snapshot: absent, now: realNow, ring: week).entries
        expect(texts(weekEntries).contains("주간 (7일) · 링"), "the pinned weekly section is marked")
        expect(!texts(weekEntries).contains { $0.hasPrefix("링:") }, "no fallback line when the pin holds")

        let fable = RingChoice.choose(.pinned(.model("fable")), in: absent, at: realNow)
        expectEqual(fable?.window, .model("Fable"), "bucket names match case-insensitively")
        expect(fable?.fellBackFrom == nil, "a case-insensitive match is no fallback")

        // An ended pinned window is not usable either.
        let t = now.timeIntervalSince1970
        let ended = Snapshot(
            capturedAt: t - 3600, fiveHour: RLWindow(used_percentage: 45, resets_at: t - 60),
            sevenDay: RLWindow(used_percentage: 30, resets_at: t + 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil
        )
        let endedChoice = RingChoice.choose(.pinned(.five), in: ended, at: now)
        expect(endedChoice?.window == .week && endedChoice?.fellBackFrom == .five, "an ended pinned window falls back")

        let composition = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: absent, ringSetting: .pinned(.five), now: realNow
        )
        expectEqual(composition.ring?.window, .model("Fable"), "composition draws the fallback window")
        expect(texts(composition.entries).contains("링: 5시간 지금 값 없음 · 자동으로 표시"), "composition carries the fallback line")
    }

    private static func testRingSettingsParsing() throws {
        func ring(_ text: String?) -> RingSetting { ClaudePaceSettings.ring(from: text.map { Data($0.utf8) }) }
        expectEqual(ring(nil), .auto, "missing settings file means auto")
        expectEqual(ring(""), .auto, "empty settings file means auto")
        expectEqual(ring("{not json"), .auto, "garbage means auto")
        expectEqual(ring("[\"week\"]"), .auto, "a non-object means auto")
        expectEqual(ring(#"{"ring":"week"}"#), .auto, "no schema means auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v2","ring":"week"}"#), .auto, "another schema means auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":"weekly"}"#), .auto, "an unknown value means auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":"model:"}"#), .auto, "a bucket without a name means auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":"model:  "}"#), .auto, "a blank bucket name means auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":7}"#), .auto, "a non-string ring means auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1"}"#), .auto, "no ring means auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":"auto"}"#), .auto, "auto")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":"week"}"#), .pinned(.week), "week")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":"five"}"#), .pinned(.five), "five")
        expectEqual(ring(#"{"schema":"claudepace-settings.v1","ring":"model:Fable"}"#), .pinned(.model("Fable")), "a bucket")

        for setting: RingSetting in [.auto, .pinned(.week), .pinned(.five), .pinned(.model("Fable \"4\" / 1M"))] {
            let data = ClaudePaceSettings.data(setting: setting, over: nil)
            expectEqual(ClaudePaceSettings.ring(from: data), setting, "\(setting.rawValue) round-trips")
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            expect(object?["schema"] as? String == "claudepace-settings.v1", "\(setting.rawValue): written with the v1 schema")
        }
        let kept = ClaudePaceSettings.data(
            setting: .pinned(.week),
            over: Data(#"{"schema":"claudepace-settings.v1","ring":"auto","later":true}"#.utf8)
        )
        let keptObject = kept.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        expect(keptObject?["later"] as? Bool == true, "other keys of a v1 file survive a ring change")
        expect(keptObject?["ring"] as? String == "week", "the ring itself is replaced")

        // The store writes through a temporary file and leaves only settings.json.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudepace-settings-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClaudePaceSettingsStore(home: home.path)
        expectEqual(store.loadRing(), .auto, "no settings file yet: auto")
        expect(store.saveRing(.pinned(.model("Fable"))), "saving the ring succeeds")
        expectEqual(store.loadRing(), .pinned(.model("Fable")), "the saved ring reads back")
        let directory = store.url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        expectEqual(files, ["settings.json"], "only settings.json is left behind")
        expectEqual(store.url.path, home.path + "/Library/Application Support/ClaudePace/settings.json", "settings path")
    }

    private static func testPlanningLineArithmetic() {
        let day: TimeInterval = 86_400
        let hour: TimeInterval = 3600
        expectEqual(UsageView.planningLine(used: 60, remaining: 2 * day), "남은 40% · 리셋까지 하루 20%씩", "a day or more left: per day")
        expectEqual(UsageView.planningLine(used: 60, remaining: 1.5 * day), "남은 40% · 리셋까지 하루 26.7%씩", "one decimal at most")
        expectEqual(UsageView.planningLine(used: 0, remaining: 3 * day), "남은 100% · 리셋까지 하루 33.3%씩", "rounded to one decimal")
        expectEqual(UsageView.planningLine(used: 66, remaining: day), "남은 34% · 리셋까지 하루 34%씩", "exactly 24h left is still per day")
        expectEqual(UsageView.planningLine(used: 91, remaining: 3 * hour), "남은 9% · 리셋까지 시간당 3%씩", "under a day left: per hour")
        expectEqual(UsageView.planningLine(used: 90, remaining: 4 * hour), "남은 10% · 리셋까지 시간당 2.5%씩", "per-hour decimals")
        expectEqual(UsageView.planningLine(used: 70, remaining: 10 * hour), "남은 30% · 리셋까지 시간당 3%씩", "a whole rate drops .0")
        expectEqual(UsageView.planningLine(used: 99, remaining: 23 * hour), "남은 1% · 리셋까지 시간당 0.1% 미만", "a rate that rounds to nothing is not 0%")
        expect(UsageView.planningLine(used: 100, remaining: 2 * day) == nil, "used up: no line")
        expect(UsageView.planningLine(used: 99.6, remaining: 2 * day) == nil, "shown as 100%: no line")
        expect(UsageView.planningLine(used: 40, remaining: 0) == nil, "no time left: no line")
        expect(UsageView.planningLine(used: 40, remaining: 30) == nil, "under a minute left: no line")

        let weekly = UsageView(snapshot: try? absentSnapshot(), now: realNow).entries
        let weekSection = section("주간 (7일)", in: weekly) ?? []
        expect(texts(weekSection).last?.hasPrefix("남은 40% · 리셋까지 하루 ") == true, "the weekly section ends with its planning line")
        let fableSection = section("Fable 주간", in: weekly) ?? []
        expect(texts(fableSection).last?.hasPrefix("남은 9% · 리셋까지 하루 ") == true, "every bucket gets its planning line")
    }

    private static func testModelBucketsAreFirstClass() throws {
        let t = now.timeIntervalSince1970
        let weekReset = t + 2 * 86_400
        let snapshot = Snapshot(
            capturedAt: t,
            fiveHour: nil,
            sevenDay: RLWindow(used_percentage: 60, resets_at: weekReset),
            sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: [
                "Fable": RLWindow(used_percentage: 91, resets_at: weekReset),
                "Opus": RLWindow(used_percentage: 30, resets_at: weekReset + 86_400),
                "Broken": RLWindow(used_percentage: 140, resets_at: weekReset)
            ],
            model: nil
        )
        let entries = UsageView(snapshot: snapshot, now: now).entries
        let fable = section("Fable 주간", in: entries)
        expect(fable != nil, "a bucket gets its own section")
        expect(barTexts(fable ?? []).first?.hasPrefix("사용 91% · 예상 ") == true, "with a bar like the weekly one: \(fable ?? [])")
        expect(!texts(fable ?? []).contains { $0.hasPrefix("리셋까지") }, "no reset line when it shares the weekly reset")
        let opus = section("Opus 주간", in: entries) ?? []
        expect(texts(opus).contains { $0.hasPrefix("리셋까지 3일 (\(clockText(weekReset + 86_400))) · 경과 ") }, "a different reset gets its own line: \(opus)")
        expect(!texts(entries).contains { $0.contains("Broken") }, "an out-of-range bucket is not shown")
        expect(!texts(entries).contains("모델별 주간"), "no more text-only bucket block")
        if let fableIndex = entries.firstIndex(of: .header("Fable 주간")),
           let opusIndex = entries.firstIndex(of: .header("Opus 주간")) {
            expect(fableIndex < opusIndex, "buckets in name order")
        }

        // Ended since the last poll: no percentage, says when it reset.
        let endedAt = t - 60
        let endedBucket = Snapshot(
            capturedAt: t - 3600, fiveHour: nil,
            sevenDay: RLWindow(used_percentage: 60, resets_at: t + 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: ["Fable": RLWindow(used_percentage: 91, resets_at: endedAt)],
            model: nil
        )
        let endedSection = section("Fable 주간", in: UsageView(snapshot: endedBucket, now: now).entries) ?? []
        expectEqual(endedSection, [.line("\(clockText(endedAt))에 리셋됨 · 새 값은 다음 조회 때")], "an ended bucket shows no percentage")

        // Not refreshed by a poll after its reset: `/usage` no longer prints it.
        let vanished = Snapshot(
            capturedAt: t - 60, fiveHour: nil,
            sevenDay: RLWindow(used_percentage: 60, resets_at: t + 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: ["Opus": RLWindow(used_percentage: 30, resets_at: t - 7200)],
            model: nil
        )
        expect(!texts(UsageView(snapshot: vanished, now: now).entries).contains { $0.contains("Opus") }, "a bucket /usage stopped printing is hidden")

        // The statusLine era's fixed fields are buckets too; a keyed one wins a clash.
        let legacy = Snapshot(
            capturedAt: t, fiveHour: nil, sevenDay: nil,
            sevenDayOpus: RLWindow(used_percentage: 30, resets_at: t + 86_400),
            sevenDaySonnet: RLWindow(used_percentage: 12, resets_at: t + 86_400),
            modelWindows: ["Opus": RLWindow(used_percentage: 45, resets_at: t + 86_400)],
            model: nil
        )
        expectEqual(legacy.modelBuckets.map(\.name), ["Opus", "Sonnet"], "legacy fields merge into the buckets")
        let legacyEntries = UsageView(snapshot: legacy, now: now).entries
        expect(barTexts(section("Opus 주간", in: legacyEntries) ?? []).first?.hasPrefix("사용 45%") == true, "the keyed bucket wins a name clash")
        expect(barTexts(section("Sonnet 주간", in: legacyEntries) ?? []).first?.hasPrefix("사용 12%") == true, "legacy Sonnet still shows")
        expect(!texts(legacyEntries).contains("한도 값 없음 — 공식 조회에서 퍼센트를 받지 못함"), "buckets count as readings")
    }

    private static func testOnlyABucketStillDrivesTheRing() {
        let t = now.timeIntervalSince1970
        let onlyBucket = Snapshot(
            capturedAt: t, fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: ["Fable": RLWindow(used_percentage: 91, resets_at: t + 86_400)],
            model: nil
        )
        expect(onlyBucket.hasUsableWindow, "a usable bucket is a usable window")
        expect(decideClaude(onlyBucket), equals: .claude, "a bucket-only reading keeps Claude on screen")
        let composition = MenuComposition.compose(providerMode: .claude, claudeSnapshot: onlyBucket, now: now)
        expectEqual(composition.ring?.window, .model("Fable"), "and drives the ring")
        let ended = Snapshot(
            capturedAt: t - 3600, fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: ["Fable": RLWindow(used_percentage: 91, resets_at: t - 60)],
            model: nil
        ).droppingEndedWindows(at: now)
        expect(!ended.hasUsableWindow, "an ended bucket is no reading")
    }

    private static func testFooterModelOnlyForStatusLineReadings() {
        let t = now.timeIntervalSince1970
        func snapshot(source: String?) -> Snapshot {
            Snapshot(
                capturedAt: t - 120, fiveHour: nil,
                sevenDay: RLWindow(used_percentage: 41, resets_at: t + 86_400),
                sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil,
                model: "Opus 5 (1M context)", source: source
            )
        }
        let polled = MenuComposition.compose(providerMode: .claude, claudeSnapshot: snapshot(source: "usage-poll"), now: now)
        expect(!texts(polled.entries).contains { $0.contains("Opus 5 (1M context)") }, "the poll's leftover model is not in the footer")
        expect(texts(polled.entries).contains("2분 전 갱신"), "the footer keeps its age")
        expect(!polled.toolTip.contains("Opus 5"), "nor in the tooltip")

        let statusLine = MenuComposition.compose(providerMode: .claude, claudeSnapshot: snapshot(source: nil), now: now)
        expect(texts(statusLine.entries).contains("2분 전 갱신 · Opus 5 (1M context)"), "a statusLine reading names its model")
        expect(statusLine.toolTip.hasSuffix(" · Opus 5 (1M context)"), "in the tooltip too")
    }

    private static func testNoFiveHourLimitLineReplacesEndedWindowText() throws {
        let absent = try absentSnapshot()
        let expectedLine = "5시간 한도 없는 계정 · 주간 한도만 적용 (\(dayText(absentSince)) 확인)"
        let forbidden = ["창 끝남", "지금 열린 창 없음", "다음 메시지부터"]
        for polled in [true, false] {
            let lines = texts(UsageView(snapshot: absent, polled: polled, now: realNow).entries)
            expect(lines.contains(expectedLine), "polled \(polled): one line says there is no 5-hour limit")
            expect(!lines.contains { line in forbidden.contains { line.contains($0) } }, "polled \(polled): no ended-window text")
            expect(!lines.contains("5시간"), "polled \(polled): no 5-hour section")
        }
        let composition = MenuComposition.compose(providerMode: .claude, claudeSnapshot: absent, now: realNow)
        expect(barTexts(composition.entries).count == 2, "only the weekly and Fable bars")

        // Without the key, today's 5-hour handling stays exactly as it was.
        let today = try decodeSnapshot(realSnapshotJSON)
        let todayLines = texts(UsageView(snapshot: today, now: realNow).entries)
        expect(
            todayLines.contains("지금 열린 창 없음 (\(clockText(1_794_637_200))에 끝남) · 다음 메시지부터 새로 시작"),
            "no key: the ended window still reads as before"
        )
        let t = now.timeIntervalSince1970
        let pro = Snapshot(
            capturedAt: t, fiveHour: RLWindow(used_percentage: 22, resets_at: t + 7200),
            sevenDay: RLWindow(used_percentage: 5, resets_at: t + 3 * 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil, source: "usage-poll"
        )
        let proEntries = UsageView(snapshot: pro, now: now).entries
        expectEqual(
            section("5시간", in: proEntries) ?? [],
            [.bar(used: 0.22, pace: 0.6, text: "사용 22%"), .line("리셋까지 2시간 (\(clockText(t + 7200)))")],
            "a Pro account keeps its 5-hour bar"
        )
    }

    private static func testRingSubmenuOptions() throws {
        let absent = try absentSnapshot()
        let auto = RingChoice.options(for: .auto, in: absent, at: realNow)
        expectEqual(auto.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체", "Fable 주간"], "no 5-hour item without a reading")
        expectEqual(auto.map(\.isSelected), [true, false, false], "checkmark on auto")
        expectEqual(auto.map(\.setting), [.auto, .pinned(.week), .pinned(.model("Fable"))], "items carry their setting")

        let pinnedFive = RingChoice.options(for: .pinned(.five), in: absent, at: realNow)
        expect(!pinnedFive.contains { $0.isSelected }, "a pinned window that is not listed checks nothing")

        let t = now.timeIntervalSince1970
        let pro = Snapshot(
            capturedAt: t, fiveHour: RLWindow(used_percentage: 22, resets_at: t + 7200),
            sevenDay: RLWindow(used_percentage: 5, resets_at: t + 3 * 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil
        )
        let proOptions = RingChoice.options(for: .pinned(.five), in: pro, at: now)
        expectEqual(proOptions.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체", "5시간"], "a 5-hour reading lists 5시간")
        expectEqual(proOptions.map(\.isSelected), [false, false, true], "checkmark on the pinned window")
        expectEqual(RingChoice.options(for: .auto, in: nil, at: now).map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체"], "no snapshot: auto and weekly")

        // A reading too old to show offers none of its windows.
        let dayOld = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: absent, now: realNow.addingTimeInterval(25 * 3600)
        )
        expectEqual(dayOld.ringOptions.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체"], "a hidden reading lists no windows")

        let composition = MenuComposition.compose(providerMode: .claude, claudeSnapshot: pro, now: now)
        expectEqual(composition.ring?.window, .five, "Pro: auto picks the fuller 5-hour window")
        expect(texts(composition.entries).contains("5시간 · 링"), "Pro: the 5-hour section is marked")
        expectEqual(composition.toolTip, "AI Usage · Claude · 링 5시간 22% · 주 5%", "Pro tooltip")
        expectEqual(composition.ringOptions, RingChoice.options(for: .auto, in: pro, at: now), "the composition carries the submenu")
    }

    private static func testCompositionKeepsOtherProvidersAsTheyWere() throws {
        let t = now.timeIntervalSince1970
        let codexEntries: [MenuEntry] = [.header("Codex · Pro"), .line("from CodexUsageView")]
        let codex = MenuComposition.compose(
            providerMode: .codex,
            claudeSnapshot: nil,
            codexSnapshot: try makeSnapshot(capturedAt: t),
            codexEntries: codexEntries,
            codexToolTip: "AI Usage · Codex 42%",
            now: now
        )
        expectEqual(codex.entries, codexEntries, "Codex mode shows the Codex view's rows")
        expectEqual(codex.toolTip, "AI Usage · Codex 42%", "and its tooltip")
        expectEqual(codex.image, .codexRing(used: 42), "and its ring")
        expect(codex.ring == nil && codex.ringOptions.isEmpty, "no Claude ring or ring submenu in Codex mode")

        let claude = makeClaudeSnapshot(capturedAt: t - 600)
        let codexWithClaude = MenuComposition.compose(
            providerMode: .codex, claudeSnapshot: claude,
            codexSnapshot: try makeSnapshot(capturedAt: t), codexEntries: codexEntries,
            codexToolTip: "AI Usage · Codex 42%", now: now
        )
        expectEqual(Array(codexWithClaude.entries.prefix(2)), codexEntries, "the Codex rows come first")
        expectEqual(codexWithClaude.entries[2], .separator, "then a separator")
        expectEqual(codexWithClaude.entries[3], .header("Claude · 전환 보조"), "then the secondary Claude block")
        expect(!texts(codexWithClaude.entries).contains { $0.hasSuffix(" · 링") }, "the secondary block marks no ring")

        let grok = MenuComposition.compose(providerMode: .grokTransition, claudeSnapshot: nil, now: now)
        expectEqual(grok.image, .unavailable(accessibilityDescription: "Grok 사용량 확인 불가"), "Grok draws ?")
        expectEqual(grok.toolTip, GrokUsageUnavailablePresentation.toolTip, "Grok tooltip")
        expectEqual(grok.entries.first, .header("Grok"), "Grok block")
        expect(grok.ringOptions.isEmpty, "no ring submenu outside Claude mode")

        let missing = MenuComposition.compose(providerMode: .claude, claudeSnapshot: nil, now: now)
        expectEqual(missing.image, .unavailable(accessibilityDescription: "Claude 사용량 확인 불가"), "no snapshot: ?")
        expectEqual(missing.toolTip, ClaudeUsageUnavailablePresentation.toolTip, "no snapshot: tooltip")
        expect(texts(missing.entries).contains("스냅샷 없음 · 아직 한 번도 수집되지 않음"), "no snapshot: says so")
        expectEqual(missing.ringOptions.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체"], "Claude mode keeps the submenu")

        let history = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: nil,
            history: MenuHistory(totalRecords: 12, claudeRecords: 10, codexRecords: 2, lastRecord: "11/17 09:30"),
            now: now
        )
        expectEqual(
            Array(history.entries.suffix(4)),
            [.separator, .header("기록"), .line("총 12건 · Claude 10 · Codex 2"), .line("마지막 기록 11/17 09:30")],
            "the history block closes the menu"
        )

        // A broken collector under a still-fresh reading: numbers plus the cause.
        let blocked = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: makeClaudeSnapshot(capturedAt: t),
            collectorState: makeCollectorState("signed-out"), now: now
        )
        expect(texts(blocked.entries).contains("⚠ 수집 중단"), "a broken collector is named under the numbers")
    }

    private static func testPreviewText() throws {
        let absent = try absentSnapshot()
        let composition = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: absent, collectorState: okCollector(at: 1_794_875_663), now: realNow
        )
        let lines = composition.previewText.components(separatedBy: "\n")
        expectEqual(lines.first, "Claude", "headers as they are")
        expect(lines.contains { $0.hasPrefix("[■■■■■■□□□□] 사용 60% · 예상 ") }, "bars as ten cells: \(lines)")
        expect(lines.contains { $0.hasPrefix("[■■■■■■■■■□] 사용 91% · 예상 ") }, "the Fable bar")
        expect(lines.contains("—"), "separators as —")
        expect(lines.contains("메뉴바 링 ▸ ✓자동 (가장 많이 쓴 한도) | 주간 전체 | Fable 주간"), "the ring submenu")
        expectEqual(lines.suffix(2).first, "ring: Fable 주간 91%", "the ring line")
        expectEqual(lines.last, "tooltip: " + composition.toolTip, "the tooltip line")

        let missing = MenuComposition.compose(providerMode: .claude, claudeSnapshot: nil, now: now)
        expect(missing.previewText.contains("\nring: ?\n"), "nothing to draw: ring ?")
        let codex = MenuComposition.compose(
            providerMode: .codex, claudeSnapshot: nil,
            codexSnapshot: try makeSnapshot(capturedAt: now.timeIntervalSince1970),
            codexToolTip: "AI Usage · Codex 42%", now: now
        )
        expect(codex.previewText.hasSuffix("ring: Codex 42%\ntooltip: AI Usage · Codex 42%"), "Codex ring line")
    }

    private static func decideClaude(
        _ snapshot: Snapshot?,
        collector: ClaudeCollectorState? = nil
    ) -> PrimaryUsageDecision {
        PrimaryUsageSelector.decide(
            providerMode: .claude,
            codexSnapshot: nil,
            claudeSnapshot: snapshot,
            claudeCollectorState: collector,
            now: now
        )
    }

    private static func makeClaudeSnapshot(
        capturedAt: Double?,
        fiveHour: RLWindow? = RLWindow(used_percentage: 22, resets_at: 1_800_003_600),
        sevenDay: RLWindow? = RLWindow(used_percentage: 5, resets_at: 1_800_300_000)
    ) -> Snapshot {
        Snapshot(
            capturedAt: capturedAt,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            modelWindows: nil,
            model: "Opus 5"
        )
    }

    private static func makeCollectorState(_ status: String) -> ClaudeCollectorState {
        ClaudeCollectorState(
            schema: "claude-collector-state.v1",
            status: status,
            capturedAt: now.timeIntervalSince1970,
            detail: nil
        )
    }

    private static func makeSnapshot(
        source: String = "codex-app-server",
        capturedAt: Double?,
        usedPercent: Double? = 42,
        unlimited: Bool = false
    ) throws -> CodexUsageSnapshot {
        let capturedAtValue: Any = capturedAt ?? NSNull()
        let usedPercentValue: Any = usedPercent ?? NSNull()
        let primaryValue: Any
        if usedPercent == nil {
            primaryValue = NSNull()
        } else {
            primaryValue = [
                "usedPercent": usedPercentValue,
                "windowDurationMins": 10_080,
                "resetsAt": now.timeIntervalSince1970 + 86_400
            ] as [String: Any]
        }
        let object: [String: Any] = [
            "schema": "codex-usage.v1",
            "source": source,
            "capturedAt": capturedAtValue,
            "rateLimits": [
                "limitId": "codex",
                "planType": "pro",
                "primary": primaryValue,
                "credits": [
                    "hasCredits": false,
                    "unlimited": unlimited,
                    "balance": "0"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
    }
}
