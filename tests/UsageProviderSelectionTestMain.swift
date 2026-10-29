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
