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
        testOutOfRangeResetsAreNoReading()
        testAbsurdTimesNeverTrap()
        testBucketEndingAsThePollReturns()
        testEndedWeekKeepsItsHeader()
        try testNoStraySeparators()
        try testBlankedWindowsAreNoReading()
        try testCodexRowsOnlyInCodexMode()

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
            of: #""source": "usage-poll"}"#, with: #""source": 7, "fiveHourAbsentSince": "soon", "fiveHourSeenAt": "soon"}"#
        ))
        expect(odd.fiveHourAbsentSince == nil && odd.source == nil, "malformed extras read as absent")
        expect(odd.fiveHourSeenAt == nil, "a malformed fiveHourSeenAt reads as absent")
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
            // The pace tick: how far into Fable's week we are, counted back
            // from its reset (1794978000), about 83%.
            let fableStart = 1_794_978_000 - WindowCalc.weekLength
            let fablePace = (realNow.timeIntervalSince1970 - fableStart) / WindowCalc.weekLength
            expect(
                abs((composition.ring?.pace ?? -1) - fablePace) < 1e-9,
                "\(name): the ring's pace tick is Fable's elapsed week (\(fablePace)): \(String(describing: composition.ring?.pace))"
            )
            expect(abs(fablePace - 0.831) < 0.001, "\(name): about 83% of that week has gone (\(fablePace))")
            expect(composition.ring?.dimmed == false, "\(name): a two-minute-old reading is not dimmed")
            expect(composition.toolTip.hasPrefix("AI Usage · Claude · 링 Fable 주간 91% · 주 60%"), "\(name): tooltip names the ring: \(composition.toolTip)")
            expect(texts(composition.entries).contains("Fable 주간 · 링"), "\(name): the Fable section is marked")
            expect(texts(composition.entries).contains("주간 전체 (7일)"), "\(name): the weekly section is not")
        }

        // The real snapshot's Fable shares the week's reset, so it cannot
        // tell which reset a tick is counted from. Here Fable resets a day
        // out and the week two: each window's tick comes from its own reset.
        let t = now.timeIntervalSince1970
        let ownReset = Snapshot(
            capturedAt: t - 60, fiveHour: nil,
            sevenDay: RLWindow(used_percentage: 60, resets_at: t + 2 * 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: ["Fable": RLWindow(used_percentage: 91, resets_at: t + 86_400)],
            model: nil, fiveHourAbsentSince: t - 86_400, source: "usage-poll"
        )
        let fableOwn = MenuComposition.compose(providerMode: .claude, claudeSnapshot: ownReset, now: now)
        expectEqual(fableOwn.ring?.window, .model("Fable"), "own reset: auto picks Fable")
        // Six of Fable's seven days have gone; the week's five would be wrong.
        expect(
            abs((fableOwn.ring?.pace ?? -1) - 6.0 / 7) < 1e-9,
            "own reset: the tick is Fable's elapsed week (6/7), not the week's (5/7): \(String(describing: fableOwn.ring?.pace))"
        )
        let weekOwn = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: ownReset, ringSetting: .pinned(.week), now: now
        )
        expectEqual(weekOwn.ring?.window, .week, "own reset: the pinned week is drawn")
        expect(
            abs((weekOwn.ring?.pace ?? -1) - 5.0 / 7) < 1e-9,
            "own reset: its tick is the week's own (5/7), not Fable's (6/7): \(String(describing: weekOwn.ring?.pace))"
        )

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
        expect(texts(weekEntries).contains("주간 전체 (7일) · 링"), "the pinned weekly section is marked")
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
        expectEqual(UsageView.planningLine(used: 60, remaining: 1.5 * day), "남은 40% · 리셋까지 하루 27%씩", "from 10% up: whole percent")
        expectEqual(UsageView.planningLine(used: 0, remaining: 3 * day), "남은 100% · 리셋까지 하루 33%씩", "rounded to a whole percent")
        expectEqual(UsageView.planningLine(used: 52, remaining: 5 * day), "남은 48% · 리셋까지 하루 9.6%씩", "under 10%: one decimal")
        expectEqual(UsageView.planningLine(used: 50.2, remaining: 5 * day), "남은 50% · 리셋까지 하루 10%씩", "9.96 rounds up to a whole 10%")
        expectEqual(UsageView.planningLine(used: 66, remaining: day), "남은 34% · 리셋까지 하루 34%씩", "exactly 24h left is still per day")
        expectEqual(UsageView.planningLine(used: 91, remaining: 3 * hour), "남은 9% · 리셋까지 시간당 3%씩", "under a day left: per hour")
        expectEqual(UsageView.planningLine(used: 90, remaining: 4 * hour), "남은 10% · 리셋까지 시간당 2.5%씩", "per-hour decimals")
        expectEqual(UsageView.planningLine(used: 70, remaining: 10 * hour), "남은 30% · 리셋까지 시간당 3%씩", "a whole rate drops .0")
        expectEqual(UsageView.planningLine(used: 99, remaining: 23 * hour), "남은 1% · 리셋까지 시간당 0.1% 미만", "a rate that rounds to nothing is not 0%")
        expect(UsageView.planningLine(used: 100, remaining: 2 * day) == nil, "used up: no line")
        expect(UsageView.planningLine(used: 99.6, remaining: 2 * day) == nil, "shown as 100%: no line")
        expect(UsageView.planningLine(used: 40, remaining: 0) == nil, "no time left: no line")
        expect(UsageView.planningLine(used: 40, remaining: 30) == nil, "under a minute left: no line")
        // In the last hour a per-hour rate would exceed what is left (36%
        // left with 10 minutes to go is "216% an hour"): the time instead.
        expectEqual(UsageView.planningLine(used: 64, remaining: hour), "남은 36% · 리셋까지 시간당 36%씩", "an hour left is still per hour")
        expectEqual(UsageView.planningLine(used: 64, remaining: 3599), "남은 36% · 리셋까지 59분", "under an hour: the minutes left")
        expectEqual(UsageView.planningLine(used: 64, remaining: 600), "남은 36% · 리셋까지 10분", "ten minutes left")
        expectEqual(UsageView.planningLine(used: 64, remaining: 60), "남은 36% · 리셋까지 1분", "a minute left")
        // Whole minutes counted like the reset line's `dur` (to the second,
        // then down), so the two lines never disagree.
        expectEqual(UsageView.planningLine(used: 64, remaining: 119.9), "남은 36% · 리셋까지 2분", "119.9 s reads 2분, as the reset line says")
        expectEqual(UsageView.planningLine(used: 64, remaining: 119.4), "남은 36% · 리셋까지 1분", "119.4 s reads 1분")
        expectEqual(UsageView.planningLine(used: 64, remaining: 599.7), "남은 36% · 리셋까지 10분", "599.7 s reads 10분")
        expectEqual(UsageView.planningLine(used: 64, remaining: 3599.6), "남은 36% · 리셋까지 시간당 36%씩", "3599.6 s reads an hour, as the reset line says")
        expectEqual(UsageView.planningLine(used: 64, remaining: 59.6), "남은 36% · 리셋까지 1분", "59.6 s reads a minute")
        expect(UsageView.planningLine(used: 64, remaining: 59.4) == nil, "59.4 s is under a minute: no line")
        expect(UsageView.planningLine(used: 64, remaining: 1e19) == nil, "an absurd time left plans nothing")
        expect(UsageView.planningLine(used: 64, remaining: -.infinity) == nil, "nor a non-finite one")
        expect(UsageView.planningLine(used: 64, remaining: -1e19) == nil, "nor a negative absurd one")
        expectEqual(UsageView.planningLine(used: 66, remaining: 86_399.6), "남은 34% · 리셋까지 하루 34%씩", "86399.6 s reads a day, as the reset line says")
        expectEqual(UsageView.planningLine(used: 66, remaining: 86_399.4), "남은 34% · 리셋까지 시간당 1.4%씩", "86399.4 s reads 23시간 59분: per hour")
        let lastHour = Snapshot(
            capturedAt: now.timeIntervalSince1970 - 60, fiveHour: nil,
            sevenDay: RLWindow(used_percentage: 64, resets_at: now.timeIntervalSince1970 + 570),
            sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil, source: "usage-poll"
        )
        let lastHourSection = section("주간 전체 (7일)", in: UsageView(snapshot: lastHour, now: now).entries) ?? []
        expectEqual(texts(lastHourSection).last, "남은 36% · 리셋까지 9분", "the weekly section says so in its last hour")

        let weekly = UsageView(snapshot: try? absentSnapshot(), now: realNow).entries
        let weekSection = section("주간 전체 (7일)", in: weekly) ?? []
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

        // The note comes once, after the limits that do apply: below the
        // last bucket's last line, not between the week and the buckets.
        let t = now.timeIntervalSince1970
        let twoBuckets = Snapshot(
            capturedAt: t - 60, fiveHour: nil,
            sevenDay: RLWindow(used_percentage: 60, resets_at: t + 2 * 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: [
                "Fable": RLWindow(used_percentage: 91, resets_at: t + 2 * 86_400),
                "Zeta": RLWindow(used_percentage: 12, resets_at: t + 3 * 86_400)
            ],
            model: nil, fiveHourAbsentSince: absentSince, source: "usage-poll"
        )
        let noteLine = MenuEntry.line("5시간 한도 없는 계정 · 주간 한도만 적용 (\(dayText(absentSince)) 확인)")
        for (name, entries) in [
            ("real snapshot", composition.entries),
            ("two buckets", MenuComposition.compose(providerMode: .claude, claudeSnapshot: twoBuckets, now: now).entries),
            ("secondary block", MenuComposition.compose(providerMode: .codex, claudeSnapshot: twoBuckets, now: now).entries)
        ] {
            let lastBucketHeader = entries.lastIndex { entry in
                if case .header(let text) = entry { return text.hasPrefix("Fable 주간") || text.hasPrefix("Zeta 주간") }
                return false
            }
            guard let lastBucketHeader, let note = entries.firstIndex(of: noteLine) else {
                expect(false, "\(name): no bucket or no note: \(texts(entries))")
                continue
            }
            // That bucket's rows run up to the next separator.
            let lastBucketRow = (entries[lastBucketHeader...].firstIndex(of: .separator) ?? entries.endIndex) - 1
            expect(texts([entries[lastBucketRow]]).first?.hasPrefix("남은 ") == true, "\(name): the bucket ends with its planning line")
            expect(note > lastBucketRow, "\(name): the note comes after the last bucket line: \(texts(entries))")
            expectEqual(entries[note - 1], .separator, "\(name): set off by a separator")
            expectEqual(entries.filter { $0 == noteLine }.count, 1, "\(name): said once")
        }

        // Without the key, today's 5-hour handling stays exactly as it was.
        let today = try decodeSnapshot(realSnapshotJSON)
        let todayLines = texts(UsageView(snapshot: today, now: realNow).entries)
        expect(
            todayLines.contains("지금 열린 창 없음 (\(clockText(1_794_637_200))에 끝남) · 다음 메시지부터 새로 시작"),
            "no key: the ended window still reads as before"
        )
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
        expectEqual(
            pinnedFive.map(\.title),
            ["자동 (가장 많이 쓴 한도)", "주간 전체", "Fable 주간", "5시간 (지금 값 없음)"],
            "a pinned window without a reading stays listed, last"
        )
        expectEqual(pinnedFive.map(\.isSelected), [false, false, false, true], "and keeps the checkmark")
        expectEqual(pinnedFive.map(\.isEnabled), [true, true, true, false], "greyed out: nothing to switch to")
        expectEqual(pinnedFive.last?.setting, .pinned(.five), "it still carries the pinned setting")
        let pinnedGone = RingChoice.options(for: .pinned(.model("Opus")), in: nil, at: realNow)
        expectEqual(
            pinnedGone.map(\.title),
            ["자동 (가장 많이 쓴 한도)", "Opus 주간 (지금 값 없음)"],
            "with no reading shown the pinned bucket is still listed"
        )
        // The all-models week is listed like the others: only with a reading.
        let pinnedWeek = RingChoice.options(for: .pinned(.week), in: nil, at: realNow)
        expectEqual(pinnedWeek.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체 (지금 값 없음)"], "a pinned week without a reading is listed once")
        expectEqual(pinnedWeek.map(\.isSelected), [false, true], "checked")
        expectEqual(pinnedWeek.map(\.isEnabled), [true, false], "and greyed out")
        expectEqual(pinnedWeek.last?.setting, .pinned(.week), "carrying the pinned setting")
        let pinnedWeekShown = RingChoice.options(for: .pinned(.week), in: absent, at: realNow)
        expectEqual(pinnedWeekShown.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체", "Fable 주간"], "a pinned week with a reading is listed once, enabled")
        expectEqual(pinnedWeekShown.map(\.isSelected), [false, true, false], "with the checkmark")

        let t = now.timeIntervalSince1970
        let pro = Snapshot(
            capturedAt: t, fiveHour: RLWindow(used_percentage: 22, resets_at: t + 7200),
            sevenDay: RLWindow(used_percentage: 5, resets_at: t + 3 * 86_400),
            sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil
        )
        let proOptions = RingChoice.options(for: .pinned(.five), in: pro, at: now)
        expectEqual(proOptions.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체", "5시간"], "a 5-hour reading lists 5시간")
        expectEqual(proOptions.map(\.isSelected), [false, false, true], "checkmark on the pinned window")
        expectEqual(RingChoice.options(for: .auto, in: nil, at: now).map(\.title), ["자동 (가장 많이 쓴 한도)"], "no snapshot: auto only")

        // A week that ended is no reading either: not offered, like an ended 5-hour window.
        let weekEnded = Snapshot(
            capturedAt: t - 3600, fiveHour: RLWindow(used_percentage: 22, resets_at: t + 7200),
            sevenDay: RLWindow(used_percentage: 60, resets_at: t - 60),
            sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil, source: "usage-poll"
        )
        expectEqual(RingChoice.options(for: .auto, in: weekEnded, at: now).map(\.title), ["자동 (가장 많이 쓴 한도)", "5시간"], "an ended week is not offered")
        let weekEndedPinned = RingChoice.options(for: .pinned(.week), in: weekEnded, at: now)
        expectEqual(weekEndedPinned.map(\.title), ["자동 (가장 많이 쓴 한도)", "5시간", "주간 전체 (지금 값 없음)"], "a pinned ended week stays listed, last")
        expectEqual(weekEndedPinned.map(\.isEnabled), [true, true, false], "greyed out")

        // A reading too old to show offers none of its windows.
        let dayOld = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: absent, now: realNow.addingTimeInterval(25 * 3600)
        )
        expectEqual(dayOld.ringOptions.map(\.title), ["자동 (가장 많이 쓴 한도)"], "a hidden reading lists no windows")

        let composition = MenuComposition.compose(providerMode: .claude, claudeSnapshot: pro, now: now)
        expectEqual(composition.ring?.window, .five, "Pro: auto picks the fuller 5-hour window")
        // The pace tick: the elapsed fraction of the 5-hour window, 3 of 5 hours.
        expectEqual(composition.ring?.pace, 0.6, "Pro: the ring's pace tick is where the 5-hour window stands")
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
        expectEqual(missing.ringOptions.map(\.title), ["자동 (가장 많이 쓴 한도)"], "Claude mode keeps the submenu")

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

    /// An absurd but finite reset (1e19) used to pass for a current reading
    /// and trap on its way to a duration. Any reset further ahead than its
    /// window reaches is no reading now.
    private static func testOutOfRangeResetsAreNoReading() {
        let t = now.timeIntervalSince1970
        let weekly = RLWindow(used_percentage: 60, resets_at: t + 28 * 3600)
        let absurd = RLWindow(used_percentage: 50, resets_at: 1e19)
        func snapshot(five: RLWindow? = nil, week: RLWindow? = nil, models: [String: RLWindow]? = nil) -> Snapshot {
            Snapshot(
                capturedAt: t - 60, fiveHour: five, sevenDay: week,
                sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: models,
                model: nil, source: "usage-poll"
            )
        }

        let bucket = snapshot(week: weekly, models: ["Fable": absurd])
        let read = bucket.droppingEndedWindows(at: now)
        expect(read.modelWindows?["Fable"]?.used_percentage == nil, "a bucket reset of 1e19 loses its percentage")
        expect(read.usableModelBuckets.isEmpty, "and is no usable bucket")
        let composition = MenuComposition.compose(providerMode: .claude, claudeSnapshot: bucket, now: now)
        expect(!texts(composition.entries).contains { $0.contains("Fable") }, "the bucket is not shown: \(texts(composition.entries))")
        expectEqual(composition.ring?.window, .week, "nor drives the ring")
        expectEqual(composition.ringOptions.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체"], "nor is offered to pin")
        expect(
            composition.previewText.hasSuffix("ring: 주간 전체 60%\ntooltip: AI Usage · Claude · 링 주간 전체 60%"),
            "the preview draws the week: \(composition.previewText)"
        )

        let onlyBucket = snapshot(models: ["Fable": absurd])
        expect(!onlyBucket.droppingEndedWindows(at: now).hasUsableWindow, "a bucket-only reading with that reset has nothing usable")
        let nothing = MenuComposition.compose(providerMode: .claude, claudeSnapshot: onlyBucket, now: now)
        expectEqual(nothing.image, .unavailable(accessibilityDescription: "Claude 사용량 확인 불가"), "so the ring draws ?")
        expect(
            texts(nothing.entries).contains("지금 쓸 수 있는 한도 값 없음 — 리셋이 지났거나 조회값에 퍼센트가 없음"),
            "and the menu says there is no usable value"
        )

        // The all-models week and the 5-hour window, the same way.
        let fiveOpen = RLWindow(used_percentage: 22, resets_at: t + 3600)
        let weekEntries = UsageView(snapshot: snapshot(five: fiveOpen, week: absurd), now: now).entries
        expect(section("주간 전체 (7일)", in: weekEntries) == nil, "a weekly reset of 1e19 shows no weekly section")
        expect(section("5시간", in: weekEntries) != nil, "while the 5-hour reading still shows")
        let fiveEntries = UsageView(snapshot: snapshot(five: absurd, week: weekly), now: now).entries
        expect(section("5시간", in: fiveEntries) == nil, "a 5-hour reset of 1e19 shows no 5-hour section")
        expect(section("주간 전체 (7일)", in: fiveEntries) != nil, "while the week still shows")

        // The bound: the window's own length plus a day of slack.
        func kept(_ reset: Double, _ length: TimeInterval) -> Bool {
            RLWindow(used_percentage: 50, resets_at: reset).blankIfOutOfRange(length: length, at: now).isUsable
        }
        let weekLimit = t + WindowCalc.weekLength + RLWindow.resetSlack
        expect(kept(weekLimit, WindowCalc.weekLength), "a weekly reset at the bound is a reading")
        expect(!kept(weekLimit + 1, WindowCalc.weekLength), "one second further is not")
        expect(!kept(t + 40 * 86_400, WindowCalc.weekLength), "no weekly reset 40 days out")
        expect(!kept(1e11, WindowCalc.weekLength), "nor one in the year 5138")
        let fiveLimit = t + WindowCalc.fiveHourLength + RLWindow.resetSlack
        expect(kept(fiveLimit, WindowCalc.fiveHourLength), "a 5-hour reset at the bound is a reading")
        expect(!kept(fiveLimit + 1, WindowCalc.fiveHourLength), "one second further is not")
        let ended = RLWindow(used_percentage: 45, resets_at: t - 60).endingIfPast(at: now)
        expectEqual(ended.blankIfOutOfRange(length: WindowCalc.weekLength, at: now), ended, "a past reset stays an ended window")
    }

    /// Capture and attempt times far off used to trap when their age became
    /// a duration; that age reads "?" instead.
    private static func testAbsurdTimesNeverTrap() {
        let ancient = makeClaudeSnapshot(capturedAt: -1e19)
        let freshness = texts(FreshnessPresentation.entries(
            snapshot: ancient,
            poll: ClaudePollStatus(runningFor: nil, lastAttempt: Date(timeIntervalSince1970: 1e19)),
            numbersShown: false, now: now
        ))
        expect(freshness.contains { $0.hasPrefix("마지막 값은 ? 전") }, "an absurd capture time has no age: \(freshness)")
        expect(freshness.contains("마지막 조회 시도 ? 전"), "nor an absurd attempt time")
        let claude = MenuComposition.compose(providerMode: .claude, claudeSnapshot: ancient, now: now)
        expectEqual(claude.image, .unavailable(accessibilityDescription: "Claude 사용량 확인 불가"), "such a reading draws ?")

        // Another provider keeps Claude's block for a capture in the future
        // (as before); its footer gets no age either.
        let future = MenuComposition.compose(
            providerMode: .codex, claudeSnapshot: makeClaudeSnapshot(capturedAt: 1e19), now: now
        )
        expect(texts(future.entries).contains("? 전 갱신 · Opus 5"), "footer of a far-future capture: \(texts(future.entries))")

        // A clock set back since the capture: within the minute allowed for
        // that the age reads as none, beyond it as unknown, never negative.
        let t = now.timeIntervalSince1970
        let justAhead = MenuComposition.compose(providerMode: .claude, claudeSnapshot: makeClaudeSnapshot(capturedAt: t + 30), now: now)
        expect(texts(justAhead.entries).contains("0초 전 갱신 · Opus 5"), "footer of a capture 30 s ahead: \(texts(justAhead.entries))")
        let edgeAhead = MenuComposition.compose(providerMode: .claude, claudeSnapshot: makeClaudeSnapshot(capturedAt: t + 60), now: now)
        expect(texts(edgeAhead.entries).contains("0초 전 갱신 · Opus 5"), "footer of a capture exactly 60 s ahead: \(texts(edgeAhead.entries))")
        let monthAhead = MenuComposition.compose(
            providerMode: .codex, claudeSnapshot: makeClaudeSnapshot(capturedAt: t + 30 * 86_400), now: now
        )
        expect(texts(monthAhead.entries).contains("? 전 갱신 · Opus 5"), "footer of a capture a month ahead: \(texts(monthAhead.entries))")
        let attemptAhead = texts(FreshnessPresentation.entries(
            snapshot: makeClaudeSnapshot(capturedAt: t - 3600),
            poll: ClaudePollStatus(runningFor: nil, lastAttempt: Date(timeIntervalSince1970: t + 20)),
            numbersShown: true, now: now
        ))
        expect(attemptAhead.contains("마지막 조회 시도 0초 전"), "an attempt 20 s ahead: \(attemptAhead)")
        expect(!(texts(justAhead.entries) + texts(monthAhead.entries) + attemptAhead).contains { $0.contains("-") && $0.contains("초") },
               "no negative age anywhere")

        expect(UsageView.planningLine(used: 1e19, remaining: 86_400) == nil, "an absurd percentage plans nothing")
    }

    /// `/usage` prints a bucket as it stands when it runs; the capture time is
    /// stamped once the poll returns. A bucket printed at 13:59:50 with a
    /// 14:00 reset and captured at 14:00:20 ended since that output: it is
    /// shown as ended, not hidden like a bucket `/usage` stopped printing.
    private static func testBucketEndingAsThePollReturns() {
        let reset = now.timeIntervalSince1970 - 300
        func snapshot(capturedAfterReset delay: Double) -> Snapshot {
            Snapshot(
                capturedAt: reset + delay, fiveHour: nil,
                sevenDay: RLWindow(used_percentage: 60, resets_at: reset + 3 * 86_400),
                sevenDayOpus: nil, sevenDaySonnet: nil,
                modelWindows: ["Fable": RLWindow(used_percentage: 91, resets_at: reset)],
                model: nil, source: "usage-poll"
            )
        }
        let ended = MenuEntry.line("\(clockText(reset))에 리셋됨 · 새 값은 다음 조회 때")
        let justAfter = snapshot(capturedAfterReset: 20)
        expectEqual(
            justAfter.reading(justAfter.modelWindows?["Fable"], at: now), .noOpenWindow(endedAt: reset),
            "Snapshot.reading itself is left as it was"
        )
        let shown = UsageView(snapshot: justAfter, now: now).entries
        expectEqual(section("Fable 주간", in: shown) ?? [], [ended], "captured 20s after the reset: shown as ended")
        expect(!barTexts(shown).contains { $0.hasPrefix("사용 91%") }, "with no percentage")
        expectEqual(
            section("Fable 주간", in: UsageView(snapshot: justAfter, polled: false, now: now).entries) ?? [],
            [.line("\(clockText(reset))에 리셋됨 · 이 모드에선 새로 조회하지 않음")],
            "under another provider too"
        )
        expectEqual(
            section("Fable 주간", in: UsageView(snapshot: snapshot(capturedAfterReset: 119), now: now).entries) ?? [],
            [ended], "119s after: still that output"
        )
        for delay in [120.0, 200] {
            let hidden = UsageView(snapshot: snapshot(capturedAfterReset: delay), now: now).entries
            expect(
                !texts(hidden).contains { $0.contains("Fable") },
                "captured \(Int(delay))s after the reset: a bucket /usage stopped printing is hidden"
            )
        }
        let composition = MenuComposition.compose(providerMode: .claude, claudeSnapshot: justAfter, now: now)
        expectEqual(composition.ring?.window, .week, "an ended bucket never drives the ring")
        expect(!composition.ringOptions.contains { $0.title.contains("Fable") }, "nor is offered to pin")
    }

    /// An ended all-models week keeps the section's full name ("주간 전체
    /// (7일)", formerly "주간 (7일)"), with no percentage and no ring mark.
    private static func testEndedWeekKeepsItsHeader() {
        let t = now.timeIntervalSince1970
        func snapshot(capturedAt: Double) -> Snapshot {
            Snapshot(
                capturedAt: capturedAt, fiveHour: RLWindow(used_percentage: 22, resets_at: t + 7200),
                sevenDay: RLWindow(used_percentage: 60, resets_at: t - 60),
                sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil, source: "usage-poll"
            )
        }
        let ended = "\(clockText(t - 60))에 리셋됨"
        // Reset after the last poll, or polled after the reset with no new
        // week printed yet: the same words either way.
        for (name, capturedAt) in [("ended since the poll", t - 3600), ("polled after the reset", t - 30)] {
            let composition = MenuComposition.compose(
                providerMode: .claude, claudeSnapshot: snapshot(capturedAt: capturedAt), now: now
            )
            expectEqual(
                section("주간 전체 (7일)", in: composition.entries) ?? [], [.line("\(ended) · 새 값은 다음 조회 때")],
                "\(name): the ended week keeps the 주간 전체 (7일) header"
            )
            expect(!texts(composition.entries).contains("주간 전체 (7일) · 링"), "\(name): an ended week is not the ring")
            expect(!texts(composition.entries).contains { $0.hasPrefix("주간 (7일)") }, "\(name): the old name is gone")
            expectEqual(composition.ring?.window, .five, "\(name): the ring draws the 5-hour window")
        }
        let secondary = UsageView(snapshot: snapshot(capturedAt: t - 3600), polled: false, now: now).entries
        expectEqual(
            section("주간 전체 (7일)", in: secondary) ?? [], [.line("\(ended) · 이 모드에선 새로 조회하지 않음")],
            "under another provider the same header"
        )
    }

    /// Indices of separators that divide nothing: first, right under a
    /// header, or right after another separator.
    private static func straySeparators(_ entries: [MenuEntry]) -> [Int] {
        entries.indices.filter { i in
            guard entries[i] == .separator else { return false }
            guard i > 0 else { return true }
            if case .header = entries[i - 1] { return true }
            return entries[i - 1] == .separator
        }
    }

    /// A section that is left out leaves no divider behind: none right under
    /// the "Claude" header, none twice in a row (the freshness block above
    /// ends with its own).
    private static func testNoStraySeparators() throws {
        let t = now.timeIntervalSince1970
        func fiveOnly(capturedAt: Double) -> Snapshot {
            Snapshot(
                capturedAt: capturedAt, fiveHour: RLWindow(used_percentage: 22, resets_at: t + 7200),
                sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil, modelWindows: nil, model: nil,
                source: "usage-poll"
            )
        }
        let bucketOnly = Snapshot(
            capturedAt: t - 60, fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: ["Fable": RLWindow(used_percentage: 91, resets_at: t + 86_400)],
            model: nil, fiveHourAbsentSince: t - 86_400, source: "usage-poll"
        )
        for (name, snapshot, first) in [
            ("no weekly section", fiveOnly(capturedAt: t - 60), MenuEntry.header("5시간 · 링")),
            ("only a bucket", bucketOnly, MenuEntry.header("Fable 주간 · 링"))
        ] {
            let entries = MenuComposition.compose(providerMode: .claude, claudeSnapshot: snapshot, now: now).entries
            expectEqual(Array(entries.prefix(2)), [.header("Claude"), first], "\(name): the first section right under the header")
            expectEqual(straySeparators(entries), [], "\(name): no stray separator: \(entries)")
        }

        // The stale block above: one separator between it and the numbers.
        let stale = MenuComposition.compose(providerMode: .claude, claudeSnapshot: fiveOnly(capturedAt: t - 1800), now: now).entries
        expectEqual(Array(stale.prefix(2)), [.header("Claude"), .header("⚠ 갱신 멈춤")], "stale: the freshness block first")
        expectEqual(straySeparators(stale), [], "stale: no stray separator: \(stale)")
        if let divider = stale.firstIndex(of: .separator), divider + 1 < stale.count {
            expectEqual(stale[divider + 1], .header("5시간 · 링"), "stale: then straight to the 5-hour section")
        } else {
            expect(false, "stale: no separator under the freshness block: \(stale)")
        }

        // Under another provider: the secondary block's header, then the numbers.
        let secondary = MenuComposition.compose(providerMode: .codex, claudeSnapshot: fiveOnly(capturedAt: t - 60), now: now).entries
        expectEqual(straySeparators(secondary), [], "secondary block: no stray separator: \(secondary)")
        if let header = secondary.firstIndex(of: .header("Claude · 전환 보조")), header + 1 < secondary.count {
            expectEqual(secondary[header + 1], .header("5시간"), "secondary block: the 5-hour section right under its header")
        } else {
            expect(false, "secondary block missing: \(secondary)")
        }

        // Nothing but the note left: it opens the block.
        let noteOnly = Snapshot(
            capturedAt: t - 60, fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
            modelWindows: nil, model: nil, fiveHourAbsentSince: t - 86_400, source: "usage-poll"
        )
        let noteEntries = UsageView(snapshot: noteOnly, now: now).entries
        expect(texts(Array(noteEntries.prefix(1))).first?.hasPrefix("5시간 한도 없는 계정") == true, "only the note: it comes first: \(noteEntries)")
        expectEqual(straySeparators(noteEntries), [], "only the note: no stray separator")

        // And the menus built from the real snapshot.
        for (name, composition) in [
            ("absent key", MenuComposition.compose(providerMode: .claude, claudeSnapshot: try absentSnapshot(), now: realNow)),
            ("as stored", MenuComposition.compose(providerMode: .claude, claudeSnapshot: try decodeSnapshot(realSnapshotJSON), now: realNow)),
            ("codex mode", MenuComposition.compose(providerMode: .codex, claudeSnapshot: try absentSnapshot(), now: realNow))
        ] {
            expectEqual(straySeparators(composition.entries), [], "\(name): no stray separator")
        }
    }

    /// The collector blanks a window's percentage, keeping its reset, when
    /// the latest poll did not print it, and adds a "fiveHourSeenAt" key. A
    /// window like that is no reading: no bar, no ring, nothing to pin, and
    /// no "ended" text until its reset passes.
    private static func testBlankedWindowsAreNoReading() throws {
        let t = now.timeIntervalSince1970
        let fiveReset = t + 3600
        let weekReset = t + 2 * 86_400
        let snapshot = try decodeSnapshot("""
        {"capturedAt": \(t - 60), "fiveHour": {"used_percentage": null, "resets_at": \(fiveReset)}, \
        "fiveHourSeenAt": \(t - 4000), \
        "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}, "sevenDayOpus": null, "sevenDaySonnet": null, \
        "modelWindows": {"Fable": {"used_percentage": null, "resets_at": \(weekReset)}, \
        "Opus": {"used_percentage": 30, "resets_at": \(weekReset)}}, "source": "usage-poll"}
        """)
        expect(snapshot.fiveHour?.resets_at == fiveReset && snapshot.fiveHour?.used_percentage == nil, "decodes, fiveHourSeenAt and all")
        expect(!snapshot.hasNoFiveHourLimit, "fiveHourSeenAt is not the no-limit key")
        expectEqual(snapshot.reading(snapshot.fiveHour, at: now), .unavailable, "a blanked 5-hour window with its reset ahead is no reading")
        expectEqual(snapshot.reading(snapshot.modelWindows?["Fable"], at: now), .unavailable, "nor is a blanked bucket")

        let composition = MenuComposition.compose(providerMode: .claude, claudeSnapshot: snapshot, now: now)
        let lines = texts(composition.entries)
        expectEqual(barTexts(composition.entries).count, 2, "bars for the week and Opus only: \(lines)")
        // The 5-hour section says why it has no number instead of going missing.
        let reason = "사용률 값 없음 — 마지막 조회에 5시간 줄이 없음 (창은 \(clockText(fiveReset))까지)"
        if let header = composition.entries.firstIndex(of: .header("5시간")) {
            expectEqual(composition.entries[header + 1], .line(reason), "the 5-hour section gives the reason: \(lines)")
        } else {
            expect(false, "a 5-hour section with the reason: \(lines)")
        }
        expect(!lines.contains("5시간 · 링"), "not marked as the ring")
        expect(!lines.contains { $0.contains("Fable") }, "no Fable section")
        let endedWords = ["창 끝남", "리셋됨", "지금 열린 창 없음", "다음 메시지부터"]
        expect(!lines.contains { line in endedWords.contains { line.contains($0) } }, "no ended text while the resets are ahead")
        expectEqual(RingCandidate.all(in: snapshot, at: now).map(\.window), [.week, .model("Opus")], "no ring candidates")
        expectEqual(composition.ring?.window, .week, "auto draws the fullest real reading")
        expectEqual(composition.ringOptions.map(\.title), ["자동 (가장 많이 쓴 한도)", "주간 전체", "Opus 주간"], "the blanked bucket is not offered to pin")
        let pinned = MenuComposition.compose(
            providerMode: .claude, claudeSnapshot: snapshot, ringSetting: .pinned(.model("Fable")), now: now
        )
        expectEqual(pinned.ring?.window, .week, "a pinned blanked bucket falls back")
        expect(texts(pinned.entries).contains("링: Fable 주간 지금 값 없음 · 자동으로 표시"), "and says so")
        expectEqual(pinned.ringOptions.last, RingOption(
            title: "Fable 주간 (지금 값 없음)", setting: .pinned(.model("Fable")), isSelected: true, isEnabled: false
        ), "listed checked and greyed out")

        // Its reset passing before the next poll makes it ended, like any other.
        let later = texts(UsageView(snapshot: snapshot, now: Date(timeIntervalSince1970: fiveReset + 60)).entries)
        expect(later.contains("\(clockText(fiveReset))에 창 끝남 · 새 값은 다음 조회 때"), "past its reset: the 5-hour window ended: \(later)")
        expect(!later.contains { $0.contains("Fable") }, "Fable's reset is still ahead: nothing yet")

        // A session line the latest poll printed but could not read: no
        // number either, and its own reason, with or without a reset.
        for reset in ["null", "\(fiveReset)"] {
            let unread = try decodeSnapshot("""
            {"capturedAt": \(t - 60), "fiveHour": {"used_percentage": null, "resets_at": \(reset)}, \
            "fiveHourSeenAt": \(t - 60), \
            "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}, "source": "usage-poll"}
            """)
            expect(unread.latestPollPrintedSessionLine, "the latest poll printed the line (reset \(reset))")
            let entries = UsageView(snapshot: unread, now: now).entries
            if let header = entries.firstIndex(of: .header("5시간")) {
                expectEqual(entries[header + 1], .line("사용률 값 없음 — 5시간 줄을 해석하지 못함"), "unreadable line, reset \(reset)")
            } else {
                expect(false, "a 5-hour section for an unreadable line (reset \(reset)): \(texts(entries))")
            }
            expectEqual(barTexts(entries).count, 1, "only the week's bar (reset \(reset))")
        }
        // A line that was read but left no usable window says which part,
        // judged by what the line gave as stored: a reset out of range is
        // blanked on reading, and is still not "unreadable". The same through
        // the menu, which reads a snapshot that was already blanked.
        let farReset = t + 3 * 86_400
        for (window, reason) in [
            (#"{"used_percentage": 30, "resets_at": null}"#, "사용률 값 없음 — 5시간 줄의 리셋 시각을 해석하지 못함"),
            (#"{"used_percentage": 130, "resets_at": \#(fiveReset)}"#, "사용률 값 없음 — 5시간 줄의 값이 범위를 벗어남"),
            (#"{"used_percentage": 30, "resets_at": \#(farReset)}"#, "사용률 값 없음 — 5시간 줄의 값이 범위를 벗어남"),
            (#"{"used_percentage": null, "resets_at": \#(farReset)}"#, "사용률 값 없음 — 5시간 줄을 해석하지 못함")
        ] {
            let read = try decodeSnapshot("""
            {"capturedAt": \(t - 60), "fiveHour": \(window), "fiveHourSeenAt": \(t - 60), \
            "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}, "source": "usage-poll"}
            """)
            let viewed = UsageView(snapshot: read, now: now).entries
            let composed = MenuComposition.compose(
                providerMode: .claude, claudeSnapshot: read.droppingEndedWindows(at: now), now: now
            ).entries
            for (via, entries) in [("view", viewed), ("menu", composed)] {
                if let header = entries.firstIndex(of: .header("5시간")) {
                    expectEqual(entries[header + 1], .line(reason), "read but unusable (\(via)): \(window)")
                } else {
                    expect(false, "a 5-hour section for \(window) (\(via)): \(texts(entries))")
                }
            }
        }
        // A poll without the line after one that gave no reset: the window
        // may be open for 5 hours from that line, and says so, until exactly
        // 5 hours on. A percentage the collector left (a snapshot from before
        // it cleared these) does not change that.
        let five = WindowCalc.fiveHourLength
        for window in [#"{"used_percentage": null, "resets_at": null}"#, #"{"used_percentage": 30, "resets_at": null}"#] {
            for (seen, shown) in [(t - 600, true), (t - 4 * 3600, true), (t - five + 1, true), (t - five, false), (t - five - 60, false)] {
                let after = try decodeSnapshot("""
                {"capturedAt": \(t - 60), "fiveHour": \(window), "fiveHourSeenAt": \(seen), \
                "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}, "source": "usage-poll"}
                """)
                let lines = texts(UsageView(snapshot: after, now: now).entries)
                expectEqual(lines.contains("사용률 값 없음 — 마지막 조회에 5시간 줄이 없음"), shown,
                            "no reset \(window), line seen \(Int(t - seen)) s ago: \(lines)")
                expect(!lines.contains { $0.contains("해석하지 못함") }, "no reset \(window), line seen \(Int(t - seen)) s ago: not unreadable")
            }
        }
        // A sighting the collector moved to the second before a poll without
        // the line (a clock that ran fast) is not this poll's line.
        let clamped = try decodeSnapshot("""
        {"capturedAt": \(t - 60), "fiveHour": {"used_percentage": null, "resets_at": \(fiveReset)}, "fiveHourSeenAt": \(t - 61), \
        "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}, "source": "usage-poll"}
        """)
        expect(!clamped.latestPollPrintedSessionLine, "a sighting a second before the poll is an earlier poll's")
        expect(texts(UsageView(snapshot: clamped, now: now).entries).contains(reason), "and gives the missing line with the window's end")

        // A readable line's window is drawn as usual, and statusLine output
        // (which never clears a window) says nothing it cannot know.
        let readable = try decodeSnapshot("""
        {"capturedAt": \(t - 60), "fiveHour": {"used_percentage": 30, "resets_at": \(fiveReset)}, \
        "fiveHourSeenAt": \(t - 60), "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}, "source": "usage-poll"}
        """)
        expect(!texts(UsageView(snapshot: readable, now: now).entries).contains { $0.hasPrefix("사용률 값 없음") }, "a readable line has its bar")
        let statusLine = try decodeSnapshot("""
        {"capturedAt": \(t - 60), "fiveHour": {"used_percentage": null, "resets_at": \(fiveReset)}, \
        "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}}
        """)
        expect(!texts(UsageView(snapshot: statusLine, now: now).entries).contains("5시간"), "statusLine output: no 5-hour section")
        let absent = try decodeSnapshot("""
        {"capturedAt": \(t - 60), "fiveHour": null, "fiveHourAbsentSince": \(t - 600), "fiveHourSeenAt": \(t - 9000), \
        "sevenDay": {"used_percentage": 60, "resets_at": \(weekReset)}, "source": "usage-poll"}
        """)
        expect(!texts(UsageView(snapshot: absent, now: now).entries).contains("5시간"), "no 5-hour limit: no 5-hour section")

        // Every window blanked: nothing to draw.
        let allBlank = try decodeSnapshot("""
        {"capturedAt": \(t - 60), "fiveHour": {"used_percentage": null, "resets_at": \(fiveReset)}, \
        "sevenDay": {"used_percentage": null, "resets_at": \(weekReset)}, \
        "modelWindows": {"Fable": {"used_percentage": null, "resets_at": \(weekReset)}}, \
        "fiveHourSeenAt": \(t - 4000), "source": "usage-poll"}
        """)
        let nothing = MenuComposition.compose(providerMode: .claude, claudeSnapshot: allBlank, now: now)
        expectEqual(nothing.image, .unavailable(accessibilityDescription: "Claude 사용량 확인 불가"), "every window blanked: the ring draws ?")
        expect(
            texts(nothing.entries).contains("지금 쓸 수 있는 한도 값 없음 — 리셋이 지났거나 조회값에 퍼센트가 없음"),
            "and the menu says why"
        )
        expectEqual(nothing.ringOptions.map(\.title), ["자동 (가장 많이 쓴 한도)"], "every window blanked: nothing to pin")
    }

    /// Codex's rows and tooltip are only worked out when Codex is what the
    /// menu shows: a leftover codex-snapshot.json with absurd numbers used to
    /// trap the Claude and Grok menus on its way to Int.
    private static func testCodexRowsOnlyInCodexMode() throws {
        var built: [String] = []
        func rows() -> [MenuEntry] { built.append("rows"); return [.header("Codex")] }
        func tip() -> String { built.append("tooltip"); return "AI Usage · Codex" }
        let t = now.timeIntervalSince1970
        let fresh = try makeSnapshot(capturedAt: t)
        let farOff = try makeSnapshot(capturedAt: 1e19)
        let cases: [(PrimaryUsageProviderMode, CodexUsageSnapshot)] = [(.claude, fresh), (.grokTransition, fresh), (.codex, farOff)]
        for (mode, codex) in cases {
            built = []
            _ = MenuComposition.compose(
                providerMode: mode, claudeSnapshot: makeClaudeSnapshot(capturedAt: t), codexSnapshot: codex,
                codexEntries: rows(), codexToolTip: tip(), now: now
            )
            expectEqual(built, [], "\(mode): the Codex rows are not built")
        }
        built = []
        let codex = MenuComposition.compose(
            providerMode: .codex, claudeSnapshot: nil, codexSnapshot: fresh,
            codexEntries: rows(), codexToolTip: tip(), now: now
        )
        expectEqual(built.sorted(), ["rows", "tooltip"], "Codex mode builds them, once each")
        expectEqual(codex.entries, [.header("Codex")], "and shows them")
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
