import Foundation

enum ExecWrapperResolution {
    static let maxWrapperDepth = ExecEnvInvocationUnwrapper.maxWrapperDepth

    struct ShellWrapperCommand {
        let isWrapper: Bool
        let command: String?

        static let notWrapper = ShellWrapperCommand(isWrapper: false, command: nil)
    }

    enum ShellMultiplexerUnwrapResult {
        case notWrapper
        case blocked(wrapper: String)
        case unwrapped(wrapper: String, argv: [String])
    }

    enum DispatchWrapperUnwrapResult {
        case notWrapper
        case blocked(wrapper: String)
        case unwrapped(wrapper: String, argv: [String])
    }

    struct DispatchWrapperExecutionPlan {
        let argv: [String]
        let wrappers: [String]
        let policyBlocked: Bool
        let blockedWrapper: String?
    }

    private enum ShellWrapperKind {
        case posix
        case cmd
        case powershell
    }

    private struct ShellWrapperSpec {
        let kind: ShellWrapperKind
        let names: Set<String>
    }

    private enum WrapperScanDirective {
        case continueScan
        case consumeNext
        case stop
        case invalid
    }

    private struct InlineCommandMatch {
        let tokenIndex: Int
        let inlineCommand: String?
    }

    private static let posixInlineFlags = Set(["-lc", "-c", "--command"])
    private static let powershellInlineFlags = Set([
        "-c",
        "-command",
        "--command",
        "-f",
        "-file",
        "-encodedcommand",
        "-enc",
        "-e",
    ])

    private static let shellWrapperNames = Set([
        "ash",
        "bash",
        "cmd",
        "dash",
        "fish",
        "ksh",
        "powershell",
        "pwsh",
        "sh",
        "zsh",
    ])

    private static let shellMultiplexerWrapperNames = Set(["busybox", "toybox"])
    private static let transparentDispatchWrappers = Set(["nice", "nohup", "stdbuf", "timeout"])
    private static let shellWrapperOptionsWithValue = Set([
        "-c",
        "--command",
        "-o",
        "+o",
        "--rcfile",
        "--init-file",
        "--startup-file",
    ])
    private static let niceOptionsWithValue = Set(["-n", "--adjustment", "--priority"])
    private static let stdbufOptionsWithValue = Set(["-i", "--input", "-o", "--output", "-e", "--error"])
    private static let timeoutFlagOptions = Set(["--foreground", "--preserve-status", "-v", "--verbose"])
    private static let timeoutOptionsWithValue = Set(["-k", "--kill-after", "-s", "--signal"])

    private static let shellWrapperSpecs: [ShellWrapperSpec] = [
        ShellWrapperSpec(kind: .posix, names: ["ash", "sh", "bash", "zsh", "dash", "ksh", "fish"]),
        ShellWrapperSpec(kind: .cmd, names: ["cmd.exe", "cmd"]),
        ShellWrapperSpec(kind: .powershell, names: ["powershell", "powershell.exe", "pwsh", "pwsh.exe"]),
    ]

    static func normalizeExecutableToken(_ token: String) -> String {
        let base = ExecCommandToken.basenameLower(token)
        if base.hasSuffix(".exe") {
            return String(base.dropLast(4))
        }
        return base
    }

    static func isShellWrapperExecutable(_ token: String) -> Bool {
        self.shellWrapperNames.contains(self.normalizeExecutableToken(token))
    }

    static func extractShellWrapperCommand(_ argv: [String], rawCommand: String?) -> ShellWrapperCommand {
        self.extractShellWrapperCommandInternal(
            argv,
            rawCommand: self.normalizeRawCommand(rawCommand),
            depth: 0)
    }

    static func extractShellInlinePayload(_ argv: [String], normalizedWrapper: String) -> String? {
        if normalizedWrapper == "cmd" {
            return self.extractCmdInlineCommand(argv)
        }
        if normalizedWrapper == "powershell" || normalizedWrapper == "pwsh" {
            return self.extractInlineCommandByFlags(
                argv,
                flags: self.powershellInlineFlags,
                allowCombinedC: false)
        }
        return self.extractInlineCommandByFlags(
            argv,
            flags: self.posixInlineFlags,
            allowCombinedC: true)
    }

    static func resolveInlineCommandValueTokenIndex(
        _ argv: [String],
        normalizedWrapper: String) -> Int?
    {
        if normalizedWrapper == "cmd" {
            guard let idx = argv.firstIndex(where: {
                let token = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return token == "/c" || token == "/k"
            }) else {
                return nil
            }
            let nextIndex = idx + 1
            return nextIndex < argv.count ? nextIndex : nil
        }

        let flags: Set<String>
        let allowCombinedC: Bool
        if normalizedWrapper == "powershell" || normalizedWrapper == "pwsh" {
            flags = self.powershellInlineFlags
            allowCombinedC = false
        } else {
            flags = self.posixInlineFlags
            allowCombinedC = true
        }

        guard let match = self.findInlineCommandMatch(argv, flags: flags, allowCombinedC: allowCombinedC) else {
            return nil
        }
        if match.inlineCommand != nil {
            return match.tokenIndex
        }
        let nextIndex = match.tokenIndex + 1
        return nextIndex < argv.count ? nextIndex : nil
    }

    static func unwrapKnownShellMultiplexerInvocation(_ argv: [String]) -> ShellMultiplexerUnwrapResult {
        guard let token0 = self.trimmedNonEmpty(argv.first) else {
            return .notWrapper
        }
        let wrapper = self.normalizeExecutableToken(token0)
        guard self.shellMultiplexerWrapperNames.contains(wrapper) else {
            return .notWrapper
        }

        var appletIndex = 1
        if appletIndex < argv.count, argv[appletIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "--" {
            appletIndex += 1
        }
        guard appletIndex < argv.count else {
            return .blocked(wrapper: wrapper)
        }

        let applet = argv[appletIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !applet.isEmpty, self.isShellWrapperExecutable(applet) else {
            return .blocked(wrapper: wrapper)
        }

        return .unwrapped(wrapper: wrapper, argv: Array(argv[appletIndex...]))
    }

    static func unwrapKnownDispatchWrapperInvocation(_ argv: [String]) -> DispatchWrapperUnwrapResult {
        guard let token0 = self.trimmedNonEmpty(argv.first) else {
            return .notWrapper
        }
        let wrapper = self.normalizeExecutableToken(token0)
        switch wrapper {
        case "env":
            return self.unwrapDispatchWrapper(wrapper: wrapper, unwrapped: ExecEnvInvocationUnwrapper.unwrap(argv))
        case "nice":
            return self.unwrapDispatchWrapper(wrapper: wrapper, unwrapped: self.unwrapNiceInvocation(argv))
        case "nohup":
            return self.unwrapDispatchWrapper(wrapper: wrapper, unwrapped: self.unwrapNohupInvocation(argv))
        case "stdbuf":
            return self.unwrapDispatchWrapper(wrapper: wrapper, unwrapped: self.unwrapStdbufInvocation(argv))
        case "timeout":
            return self.unwrapDispatchWrapper(wrapper: wrapper, unwrapped: self.unwrapTimeoutInvocation(argv))
        case "chrt", "doas", "ionice", "setsid", "sudo", "taskset":
            return .blocked(wrapper: wrapper)
        default:
            return .notWrapper
        }
    }

    static func resolveDispatchWrapperExecutionPlan(
        _ argv: [String],
        maxDepth: Int = ExecEnvInvocationUnwrapper.maxWrapperDepth) -> DispatchWrapperExecutionPlan
    {
        var current = argv
        var wrappers: [String] = []

        for _ in 0..<maxDepth {
            let unwrap = self.unwrapKnownDispatchWrapperInvocation(current)
            switch unwrap {
            case let .blocked(wrapper):
                return DispatchWrapperExecutionPlan(
                    argv: current,
                    wrappers: wrappers,
                    policyBlocked: true,
                    blockedWrapper: wrapper)
            case let .unwrapped(wrapper, argv):
                wrappers.append(wrapper)
                if self.isSemanticDispatchWrapperUsage(wrapper: wrapper, argv: current) {
                    return DispatchWrapperExecutionPlan(
                        argv: current,
                        wrappers: wrappers,
                        policyBlocked: true,
                        blockedWrapper: wrapper)
                }
                current = argv
            case .notWrapper:
                return DispatchWrapperExecutionPlan(
                    argv: current,
                    wrappers: wrappers,
                    policyBlocked: false,
                    blockedWrapper: nil)
            }
        }

        if wrappers.count >= maxDepth {
            let overflow = self.unwrapKnownDispatchWrapperInvocation(current)
            switch overflow {
            case let .blocked(wrapper), let .unwrapped(wrapper, _):
                return DispatchWrapperExecutionPlan(
                    argv: current,
                    wrappers: wrappers,
                    policyBlocked: true,
                    blockedWrapper: wrapper)
            case .notWrapper:
                break
            }
        }

        return DispatchWrapperExecutionPlan(
            argv: current,
            wrappers: wrappers,
            policyBlocked: false,
            blockedWrapper: nil)
    }

    static func unwrapDispatchWrappersForResolution(
        _ argv: [String],
        maxDepth: Int = ExecEnvInvocationUnwrapper.maxWrapperDepth) -> [String]
    {
        self.resolveDispatchWrapperExecutionPlan(argv, maxDepth: maxDepth).argv
    }

    static func unwrapShellInspectionArgv(_ argv: [String]) -> [String] {
        var current = self.unwrapDispatchWrappersForResolution(argv)
        for _ in 0..<self.maxWrapperDepth {
            let multiplexer = self.unwrapKnownShellMultiplexerInvocation(current)
            switch multiplexer {
            case let .unwrapped(_, argv):
                current = argv
            case .blocked, .notWrapper:
                return current
            }
        }
        return current
    }

    static func resolveShellWrapperScriptCandidatePath(_ argv: [String], cwd: String?) -> String? {
        let effective = self.unwrapShellInspectionArgv(argv)
        guard let token0 = self.trimmedNonEmpty(effective.first) else {
            return nil
        }

        let normalized = self.normalizeExecutableToken(token0)
        guard let spec = self.findShellWrapperSpec(normalized) else {
            return nil
        }
        guard self.extractShellWrapperPayload(effective, spec: spec) == nil else {
            return nil
        }
        guard let scriptIndex = self.findShellWrapperScriptTokenIndex(effective) else {
            return nil
        }

        let scriptToken = effective[scriptIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scriptToken.isEmpty else {
            return nil
        }

        let expanded = scriptToken.hasPrefix("~")
            ? (scriptToken as NSString).expandingTildeInPath
            : scriptToken
        if expanded.hasPrefix("/") {
            return expanded
        }

        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (trimmedCwd?.isEmpty == false) ? trimmedCwd! : FileManager().currentDirectoryPath
        return URL(fileURLWithPath: root)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

    static func hasEnvManipulationBeforeShellWrapper(_ argv: [String]) -> Bool {
        self.hasEnvManipulationBeforeShellWrapperInternal(
            argv,
            depth: 0,
            envManipulationSeen: false)
    }

    private static func normalizeRawCommand(_ rawCommand: String?) -> String? {
        let trimmed = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func splitFlag(_ lowerToken: String) -> String {
        lowerToken.split(separator: "=", maxSplits: 1).first.map(String.init) ?? lowerToken
    }

    private static func scanWrapperInvocation(
        _ argv: [String],
        separators: Set<String> = [],
        onToken: (String, String) -> WrapperScanDirective,
        adjustCommandIndex: ((Int, [String]) -> Int?)? = nil) -> [String]?
    {
        var idx = 1
        var expectsOptionValue = false

        while idx < argv.count {
            let token = argv[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                idx += 1
                continue
            }
            if expectsOptionValue {
                expectsOptionValue = false
                idx += 1
                continue
            }
            if separators.contains(token) {
                idx += 1
                break
            }

            let directive = onToken(token, token.lowercased())
            switch directive {
            case .stop:
                break
            case .invalid:
                return nil
            case .consumeNext:
                expectsOptionValue = true
            case .continueScan:
                break
            }

            if directive == .stop {
                break
            }
            idx += 1
        }

        if expectsOptionValue {
            return nil
        }

        let commandIndex = adjustCommandIndex?(idx, argv) ?? idx
        guard commandIndex < argv.count else {
            return nil
        }
        return Array(argv[commandIndex...])
    }

    private static func unwrapDashOptionInvocation(
        _ argv: [String],
        onFlag: (String, String) -> WrapperScanDirective,
        adjustCommandIndex: ((Int, [String]) -> Int?)? = nil) -> [String]?
    {
        self.scanWrapperInvocation(
            argv,
            separators: ["--"],
            onToken: { token, lower in
                if !token.hasPrefix("-") || token == "-" {
                    return .stop
                }
                return onFlag(self.splitFlag(lower), lower)
            },
            adjustCommandIndex: adjustCommandIndex)
    }

    private static func envInvocationUsesModifiers(_ argv: [String]) -> Bool {
        ExecEnvInvocationUnwrapper.unwrapWithMetadata(argv)?.usesModifiers ?? true
    }

    private static func unwrapNiceInvocation(_ argv: [String]) -> [String]? {
        self.unwrapDashOptionInvocation(argv) { flag, lower in
            if lower.range(of: #"^-\d+$"#, options: .regularExpression) != nil {
                return .continueScan
            }
            if self.niceOptionsWithValue.contains(flag) {
                return lower.contains("=") || lower != flag ? .continueScan : .consumeNext
            }
            if lower.hasPrefix("-n"), lower.count > 2 {
                return .continueScan
            }
            return .invalid
        }
    }

    private static func unwrapNohupInvocation(_ argv: [String]) -> [String]? {
        self.scanWrapperInvocation(
            argv,
            separators: ["--"],
            onToken: { token, lower in
                if !token.hasPrefix("-") || token == "-" {
                    return .stop
                }
                return lower == "--help" || lower == "--version" ? .continueScan : .invalid
            })
    }

    private static func unwrapStdbufInvocation(_ argv: [String]) -> [String]? {
        self.unwrapDashOptionInvocation(argv) { flag, lower in
            if !self.stdbufOptionsWithValue.contains(flag) {
                return .invalid
            }
            return lower.contains("=") ? .continueScan : .consumeNext
        }
    }

    private static func unwrapTimeoutInvocation(_ argv: [String]) -> [String]? {
        self.unwrapDashOptionInvocation(
            argv,
            onFlag: { flag, lower in
                if self.timeoutFlagOptions.contains(flag) {
                    return .continueScan
                }
                if self.timeoutOptionsWithValue.contains(flag) {
                    return lower.contains("=") ? .continueScan : .consumeNext
                }
                return .invalid
            },
            adjustCommandIndex: { commandIndex, currentArgv in
                let wrappedCommandIndex = commandIndex + 1
                return wrappedCommandIndex < currentArgv.count ? wrappedCommandIndex : nil
            })
    }

    private static func unwrapDispatchWrapper(
        wrapper: String,
        unwrapped: [String]?) -> DispatchWrapperUnwrapResult
    {
        guard let unwrapped, !unwrapped.isEmpty else {
            return .blocked(wrapper: wrapper)
        }
        return .unwrapped(wrapper: wrapper, argv: unwrapped)
    }

    private static func isSemanticDispatchWrapperUsage(wrapper: String, argv: [String]) -> Bool {
        if wrapper == "env" {
            return self.envInvocationUsesModifiers(argv)
        }
        return !self.transparentDispatchWrappers.contains(wrapper)
    }

    private static func findShellWrapperSpec(_ baseExecutable: String) -> ShellWrapperSpec? {
        self.shellWrapperSpecs.first { $0.names.contains(baseExecutable) }
    }

    private static func findShellWrapperScriptTokenIndex(_ argv: [String]) -> Int? {
        guard argv.count >= 2 else {
            return nil
        }

        var idx = 1
        while idx < argv.count {
            let token = argv[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                idx += 1
                continue
            }
            let lower = token.lowercased()
            if lower == "--" {
                idx += 1
                break
            }
            if lower == "-c" || lower == "--command" || self.isCombinedShellModeFlag(lower, flag: "c") {
                return nil
            }
            if lower == "-s" || self.isCombinedShellModeFlag(lower, flag: "s") {
                return nil
            }
            if self.shellWrapperOptionsWithValue.contains(lower) {
                idx += 2
                continue
            }
            if token.hasPrefix("-") || token.hasPrefix("+") {
                idx += 1
                continue
            }
            break
        }

        return idx < argv.count ? idx : nil
    }

    private static func extractShellWrapperPayload(_ argv: [String], spec: ShellWrapperSpec) -> String? {
        switch spec.kind {
        case .posix:
            return self.extractInlineCommandByFlags(
                argv,
                flags: self.posixInlineFlags,
                allowCombinedC: true)
        case .cmd:
            return self.extractCmdInlineCommand(argv)
        case .powershell:
            return self.extractInlineCommandByFlags(
                argv,
                flags: self.powershellInlineFlags,
                allowCombinedC: false)
        }
    }

    private static func extractShellWrapperCommandInternal(
        _ argv: [String],
        rawCommand: String?,
        depth: Int) -> ShellWrapperCommand
    {
        if depth > self.maxWrapperDepth {
            return .notWrapper
        }
        guard let token0 = self.trimmedNonEmpty(argv.first) else {
            return .notWrapper
        }

        switch self.unwrapKnownDispatchWrapperInvocation(argv) {
        case .blocked:
            return .notWrapper
        case let .unwrapped(_, argv):
            return self.extractShellWrapperCommandInternal(
                argv,
                rawCommand: rawCommand,
                depth: depth + 1)
        case .notWrapper:
            break
        }

        switch self.unwrapKnownShellMultiplexerInvocation(argv) {
        case .blocked:
            return .notWrapper
        case let .unwrapped(_, argv):
            return self.extractShellWrapperCommandInternal(
                argv,
                rawCommand: rawCommand,
                depth: depth + 1)
        case .notWrapper:
            break
        }

        let base0 = self.normalizeExecutableToken(token0)
        guard let wrapper = self.findShellWrapperSpec(base0),
              let payload = self.extractShellWrapperPayload(argv, spec: wrapper)
        else {
            return .notWrapper
        }

        return ShellWrapperCommand(
            isWrapper: true,
            command: rawCommand ?? payload)
    }

    private static func hasEnvManipulationBeforeShellWrapperInternal(
        _ argv: [String],
        depth: Int,
        envManipulationSeen: Bool) -> Bool
    {
        if depth > self.maxWrapperDepth {
            return false
        }
        guard let token0 = self.trimmedNonEmpty(argv.first) else {
            return false
        }

        switch self.unwrapKnownDispatchWrapperInvocation(argv) {
        case .blocked:
            return false
        case let .unwrapped(wrapper, unwrappedArgv):
            let nextEnvManipulationSeen = envManipulationSeen || (
                wrapper == "env" && self.envInvocationUsesModifiers(argv)
            )
            return self.hasEnvManipulationBeforeShellWrapperInternal(
                unwrappedArgv,
                depth: depth + 1,
                envManipulationSeen: nextEnvManipulationSeen)
        case .notWrapper:
            break
        }

        switch self.unwrapKnownShellMultiplexerInvocation(argv) {
        case .blocked:
            return false
        case let .unwrapped(_, argv):
            return self.hasEnvManipulationBeforeShellWrapperInternal(
                argv,
                depth: depth + 1,
                envManipulationSeen: envManipulationSeen)
        case .notWrapper:
            break
        }

        let normalized = self.normalizeExecutableToken(token0)
        guard let spec = self.findShellWrapperSpec(normalized),
              self.extractShellWrapperPayload(argv, spec: spec) != nil
        else {
            return false
        }
        return envManipulationSeen
    }

    private static func findInlineCommandMatch(
        _ argv: [String],
        flags: Set<String>,
        allowCombinedC: Bool) -> InlineCommandMatch?
    {
        var idx = 1
        while idx < argv.count {
            let token = argv[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                idx += 1
                continue
            }
            let lower = token.lowercased()
            if lower == "--" {
                break
            }
            if flags.contains(lower) {
                return InlineCommandMatch(tokenIndex: idx, inlineCommand: nil)
            }
            if allowCombinedC, let inlineOffset = self.combinedCommandInlineOffset(token) {
                let inline = String(token.dropFirst(inlineOffset))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return InlineCommandMatch(
                    tokenIndex: idx,
                    inlineCommand: inline.isEmpty ? nil : inline)
            }
            idx += 1
        }
        return nil
    }

    private static func extractInlineCommandByFlags(
        _ argv: [String],
        flags: Set<String>,
        allowCombinedC: Bool) -> String?
    {
        guard let match = self.findInlineCommandMatch(argv, flags: flags, allowCombinedC: allowCombinedC) else {
            return nil
        }
        if let inlineCommand = match.inlineCommand {
            return inlineCommand
        }
        let nextIndex = match.tokenIndex + 1
        return self.trimmedNonEmpty(nextIndex < argv.count ? argv[nextIndex] : nil)
    }

    private static func combinedCommandInlineOffset(_ token: String) -> Int? {
        let chars = Array(token.lowercased())
        guard chars.count >= 2, chars[0] == "-", chars[1] != "-" else {
            return nil
        }
        if chars.dropFirst().contains("-") {
            return nil
        }
        guard let commandIndex = chars.firstIndex(of: "c"), commandIndex > 0 else {
            return nil
        }
        return commandIndex + 1
    }

    private static func isCombinedShellModeFlag(_ lowerToken: String, flag: Character) -> Bool {
        let chars = Array(lowerToken)
        guard chars.count >= 2, chars[0] == "-", chars[1] != "-" else {
            return false
        }
        if chars.dropFirst().contains("-") {
            return false
        }
        return chars.dropFirst().contains(flag)
    }

    private static func extractCmdInlineCommand(_ argv: [String]) -> String? {
        guard let idx = argv.firstIndex(where: {
            let token = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return token == "/c" || token == "/k"
        }) else {
            return nil
        }
        let tailIndex = idx + 1
        guard tailIndex < argv.count else {
            return nil
        }
        let payload = argv[tailIndex...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }
}
