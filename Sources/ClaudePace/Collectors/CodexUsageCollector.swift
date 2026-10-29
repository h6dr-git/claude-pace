import Foundation

/// Fetches Codex account usage through the official local app-server protocol
/// (formerly tools/poll-codex-usage.py). Short-lived on purpose: start
/// `codex app-server`, do the initialize handshake, read account rate limits
/// and token usage, write one atomic snapshot, exit. No model turn is created.
enum CodexUsageCollector {
    struct Context {
        let home: String
        /// The environment `codex app-server` runs with.
        let environment: [String: String]
        /// The PATH searched for `codex` after the fixed install locations.
        let searchPath: String?
        /// CODEX_BIN: tried first.
        let codexBin: String?
    }

    private struct Failure: Error {
        let message: String
    }

    // The exact request lines the Python poller sent (`json.dumps` with
    // compact separators, keys in insertion order).
    private static let initializeRequest =
        #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"ai_usage_menubar","title":"AI Usage Menu Bar","version":"2.0.0"}}}"#
    private static let initializedNotification = #"{"method":"initialized","params":{}}"#
    private static let rateLimitsRequest = #"{"method":"account/rateLimits/read","id":1}"#
    private static let usageRequest = #"{"method":"account/usage/read","id":2}"#

    static func poll(_ context: Context, io: CommandIO) -> Int32 {
        let paths = AppPaths(home: context.home)
        do {
            let (rateLimits, usage, serverInfo) = try fetch(context, paths: paths)
            let snapshot = writeSnapshot(paths, rateLimits: rateLimits, usage: usage, serverInfo: serverInfo)
            let main = snapshot["rateLimits"]?.objectValue ?? JSONObject()
            let primary = main["primary"]?.objectValue ?? JSONObject()
            io.out("codex snapshot updated: plan=\(pythonString(main["planType"])) used=\(pythonString(primary["usedPercent"]))% window=\(pythonString(primary["windowDurationMins"]))m")
            return 0
        } catch let failure as Failure {
            // The last good snapshot is kept on every failure.
            io.err("codex usage poll failed: \(failure.message)")
            return 1
        } catch {
            io.err("codex usage poll failed: \(error)")
            return 1
        }
    }

    private static func findCodex(_ context: Context) throws -> String {
        let candidates = [
            context.codexBin,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            CollectorEnvironment.which("codex", path: context.searchPath)
        ]
        for case let candidate? in candidates where !candidate.isEmpty {
            if Shell.isRegularFile(candidate), Shell.isExecutable(candidate) {
                return candidate
            }
        }
        throw Failure(message: "codex CLI not found")
    }

    private static func fetch(_ context: Context, paths: AppPaths) throws -> (JSONObject, JSONObject?, JSONObject) {
        let codex = try findCodex(context)
        Shell.makeDirectories(paths.scratch)
        guard let channel = LineChannel(
            executable: codex,
            arguments: ["app-server"],
            environment: context.environment,
            directory: paths.scratch
        ) else {
            throw Failure(message: "could not start \(codex) app-server")
        }
        defer { channel.shutDown() }

        channel.send(initializeRequest)
        guard let initialized = try readResponses(channel, wanted: [0], timeout: 5)[0] else {
            throw Failure(message: "app-server initialize timed out")
        }
        let serverInfo = try resultOrError(initialized, "initialize")

        channel.send(initializedNotification)
        channel.send(rateLimitsRequest)
        channel.send(usageRequest)
        let responses = try readResponses(channel, wanted: [1, 2], timeout: 8)

        guard let rateResponse = responses[1] else {
            throw Failure(message: "account/rateLimits/read timed out")
        }
        let rateLimits = try resultOrError(rateResponse, "account/rateLimits/read")

        var usage: JSONObject?
        if let usageResponse = responses[2], usageResponse["error"] == nil,
           case .object(let result)? = usageResponse["result"] {
            usage = result
        }
        return (rateLimits, usage, serverInfo)
    }

    /// Read lines until every wanted id has answered or the time is up.
    /// Notifications and lines that are not JSON are skipped.
    private static func readResponses(_ channel: LineChannel, wanted: Set<Int>, timeout: TimeInterval) throws -> [Int: JSONObject] {
        var responses: [Int: JSONObject] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        while !wanted.subtracting(responses.keys).isEmpty {
            guard Date() < deadline, let line = channel.nextLine(before: deadline) else { break }
            guard let message = try? JSONParser.parse(line) else { continue }
            guard case .object(let object) = message else {
                throw Failure(message: "unexpected app-server message")
            }
            if case .number(let number)? = object["id"], let id = number.intValue, wanted.contains(id) {
                responses[id] = object
            }
        }
        return responses
    }

    private static func resultOrError(_ response: JSONObject, _ method: String) throws -> JSONObject {
        if let error = response["error"] {
            throw Failure(message: "\(method): \(error.compactText)")
        }
        guard case .object(let result)? = response["result"] else {
            throw Failure(message: "\(method): missing result")
        }
        return result
    }

    @discardableResult
    private static func writeSnapshot(
        _ paths: AppPaths,
        rateLimits: JSONObject,
        usage: JSONObject?,
        serverInfo: JSONObject
    ) -> JSONObject {
        Shell.makeDirectories(paths.appDir)
        var previous = JSONObject()
        if let data = Shell.readData(paths.codexSnapshot), case .object(let object)? = try? JSONParser.parse(data) {
            previous = object
        }
        let now = Shell.nowSeconds()

        var snapshot = JSONObject()
        snapshot["schema"] = JSONValue.string("codex-usage.v1")
        snapshot["source"] = JSONValue.string("codex-app-server")
        snapshot["capturedAt"] = JSONValue.int(now)
        snapshot["rateLimits"] = rateLimits["rateLimits"] ?? JSONValue.null
        snapshot["rateLimitsByLimitId"] = rateLimits["rateLimitsByLimitId"] ?? JSONValue.null
        snapshot["rateLimitResetCredits"] = rateLimits["rateLimitResetCredits"] ?? JSONValue.null
        if let usage {
            snapshot["accountUsage"] = JSONValue.object(usage)
            snapshot["accountUsageCapturedAt"] = JSONValue.int(now)
        } else {
            snapshot["accountUsage"] = previous["accountUsage"] ?? JSONValue.null
            snapshot["accountUsageCapturedAt"] = previous["accountUsageCapturedAt"] ?? JSONValue.null
        }
        snapshot["server"] = JSONValue.object(JSONObject([
            "userAgent": serverInfo["userAgent"] ?? JSONValue.null,
            "platformFamily": serverInfo["platformFamily"] ?? JSONValue.null,
            "platformOs": serverInfo["platformOs"] ?? JSONValue.null
        ]))

        let text = JSONValue.object(snapshot).pythonText(ensureASCII: false, compact: true) + "\n"
        Shell.replaceAtomically(Data(text.utf8), at: paths.codexSnapshot)
        return snapshot
    }

    /// Python's `str()` of a JSON value, for the one-line summary.
    private static func pythonString(_ value: JSONValue?) -> String {
        switch value ?? .null {
        case .null: return "None"
        case .bool(let flag): return flag ? "True" : "False"
        case .string(let string): return string
        case .number(let number): return number.text
        default: return value?.compactText ?? "None"
        }
    }
}
