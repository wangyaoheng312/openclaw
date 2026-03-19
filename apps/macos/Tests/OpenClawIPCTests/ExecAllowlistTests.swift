import Foundation
import Testing
@testable import OpenClaw

/// These cases cover optional `security=allowlist` behavior.
/// Default install posture remains deny-by-default for exec on macOS node-host.
struct ExecAllowlistTests {
    private struct ShellParserParityFixture: Decodable {
        struct Case: Decodable {
            let id: String
            let command: String
            let ok: Bool
            let executables: [String]
        }

        let cases: [Case]
    }

    private struct WrapperResolutionParityFixture: Decodable {
        struct Case: Decodable {
            let id: String
            let argv: [String]
            let expectedRawExecutable: String?
        }

        let cases: [Case]
    }

    private static func loadShellParserParityCases() throws -> [ShellParserParityFixture.Case] {
        let fixtureURL = self.fixtureURL(filename: "exec-allowlist-shell-parser-parity.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(ShellParserParityFixture.self, from: data)
        return fixture.cases
    }

    private static func loadWrapperResolutionParityCases() throws -> [WrapperResolutionParityFixture.Case] {
        let fixtureURL = self.fixtureURL(filename: "exec-wrapper-resolution-parity.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(WrapperResolutionParityFixture.self, from: data)
        return fixture.cases
    }

    private static func fixtureURL(filename: String) -> URL {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repoRoot.deleteLastPathComponent()
        }
        return repoRoot
            .appendingPathComponent("test")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(filename)
    }

    private static func homebrewRGResolution() -> ExecCommandResolution {
        ExecCommandResolution(
            rawExecutable: "rg",
            resolvedPath: "/opt/homebrew/bin/rg",
            executableName: "rg",
            cwd: nil)
    }

    private static func shellScriptFixture() throws -> (dir: URL, bash: URL, script: URL) {
        let dir = try makeTempDirForTests()
        let bash = dir.appendingPathComponent("bash")
        try makeExecutableForTests(at: bash)

        let scriptsDir = dir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let script = scriptsDir.appendingPathComponent("save_crystal.sh")
        FileManager.default.createFile(atPath: script.path, contents: Data("echo ok\n".utf8))
        return (dir, bash, script)
    }

    @Test func `match uses resolved path`() {
        let entry = ExecAllowlistEntry(pattern: "/opt/homebrew/bin/rg")
        let resolution = Self.homebrewRGResolution()
        let match = ExecAllowlistMatcher.match(entries: [entry], resolution: resolution)
        #expect(match?.pattern == entry.pattern)
    }

    @Test func `match ignores basename pattern`() {
        let entry = ExecAllowlistEntry(pattern: "rg")
        let resolution = Self.homebrewRGResolution()
        let match = ExecAllowlistMatcher.match(entries: [entry], resolution: resolution)
        #expect(match == nil)
    }

    @Test func `match ignores basename for relative executable`() {
        let entry = ExecAllowlistEntry(pattern: "echo")
        let resolution = ExecCommandResolution(
            rawExecutable: "./echo",
            resolvedPath: "/tmp/oc-basename/echo",
            executableName: "echo",
            cwd: "/tmp/oc-basename")
        let match = ExecAllowlistMatcher.match(entries: [entry], resolution: resolution)
        #expect(match == nil)
    }

    @Test func `match is case insensitive`() {
        let entry = ExecAllowlistEntry(pattern: "/OPT/HOMEBREW/BIN/RG")
        let resolution = Self.homebrewRGResolution()
        let match = ExecAllowlistMatcher.match(entries: [entry], resolution: resolution)
        #expect(match?.pattern == entry.pattern)
    }

    @Test func `match supports glob star`() {
        let entry = ExecAllowlistEntry(pattern: "/opt/**/rg")
        let resolution = Self.homebrewRGResolution()
        let match = ExecAllowlistMatcher.match(entries: [entry], resolution: resolution)
        #expect(match?.pattern == entry.pattern)
    }

    @Test func `resolve for allowlist splits shell chains`() {
        let command = ["/bin/sh", "-lc", "echo allowlisted && /usr/bin/touch /tmp/openclaw-allowlist-test"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "echo allowlisted && /usr/bin/touch /tmp/openclaw-allowlist-test",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.count == 2)
        #expect(resolutions[0].executableName == "echo")
        #expect(resolutions[1].executableName == "touch")
    }

    @Test func `resolve for allowlist keeps quoted operators in single segment`() {
        let command = ["/bin/sh", "-lc", "echo \"a && b\""]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "echo \"a && b\"",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.count == 1)
        #expect(resolutions[0].executableName == "echo")
    }

    @Test func `resolve for allowlist fails closed on command substitution`() {
        let command = ["/bin/sh", "-lc", "echo $(/usr/bin/touch /tmp/openclaw-allowlist-test-subst)"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "echo $(/usr/bin/touch /tmp/openclaw-allowlist-test-subst)",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.isEmpty)
    }

    @Test func `resolve for allowlist fails closed on quoted command substitution`() {
        let command = ["/bin/sh", "-lc", "echo \"ok $(/usr/bin/touch /tmp/openclaw-allowlist-test-quoted-subst)\""]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "echo \"ok $(/usr/bin/touch /tmp/openclaw-allowlist-test-quoted-subst)\"",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.isEmpty)
    }

    @Test func `resolve for allowlist fails closed on line-continued command substitution`() {
        let command = ["/bin/sh", "-lc", "echo $\\\n(/usr/bin/touch /tmp/openclaw-allowlist-test-line-cont-subst)"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "echo $\\\n(/usr/bin/touch /tmp/openclaw-allowlist-test-line-cont-subst)",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.isEmpty)
    }

    @Test func `resolve for allowlist fails closed on chained line-continued command substitution`() {
        let command = ["/bin/sh", "-lc", "echo ok && $\\\n(/usr/bin/touch /tmp/openclaw-allowlist-test-chained-line-cont-subst)"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "echo ok && $\\\n(/usr/bin/touch /tmp/openclaw-allowlist-test-chained-line-cont-subst)",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.isEmpty)
    }

    @Test func `resolve for allowlist fails closed on quoted backticks`() {
        let command = ["/bin/sh", "-lc", "echo \"ok `/usr/bin/id`\""]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "echo \"ok `/usr/bin/id`\"",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.isEmpty)
    }

    @Test func `resolve for allowlist matches shared shell parser fixture`() throws {
        let fixtures = try Self.loadShellParserParityCases()
        for fixture in fixtures {
            let resolutions = ExecCommandResolution.resolveForAllowlist(
                command: ["/bin/sh", "-lc", fixture.command],
                rawCommand: fixture.command,
                cwd: nil,
                env: ["PATH": "/usr/bin:/bin"])

            #expect(!resolutions.isEmpty == fixture.ok)
            if fixture.ok {
                let executables = resolutions.map { $0.executableName.lowercased() }
                let expected = fixture.executables.map { $0.lowercased() }
                #expect(executables == expected)
            }
        }
    }

    @Test func `resolve matches shared wrapper resolution fixture`() throws {
        let fixtures = try Self.loadWrapperResolutionParityCases()
        for fixture in fixtures {
            let resolution = ExecCommandResolution.resolve(
                command: fixture.argv,
                cwd: nil,
                env: ["PATH": "/usr/bin:/bin"])
            #expect(resolution?.rawExecutable == fixture.expectedRawExecutable)
        }
    }

    @Test func `resolve for allowlist treats plain sh invocation as direct exec`() {
        let command = ["/bin/sh", "./script.sh"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: nil,
            cwd: "/tmp",
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.count == 1)
        #expect(resolutions[0].executableName == "sh")
    }

    @Test func `resolve for allowlist attaches shell script candidate path`() throws {
        let fixture = try Self.shellScriptFixture()

        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: ["bash", "scripts/save_crystal.sh"],
            rawCommand: nil,
            cwd: fixture.dir.path,
            env: ["PATH": "\(fixture.dir.path):/usr/bin:/bin"])

        #expect(resolutions.count == 1)
        #expect(resolutions[0].resolvedPath == fixture.bash.path)
        #expect(resolutions[0].scriptCandidatePath == fixture.script.path)
    }

    @Test func `resolve for allowlist unwraps env shell wrapper chains`() {
        let command = [
            "/usr/bin/env",
            "/bin/sh",
            "-lc",
            "echo allowlisted && /usr/bin/touch /tmp/openclaw-allowlist-test",
        ]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: nil,
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.count == 2)
        #expect(resolutions[0].executableName == "echo")
        #expect(resolutions[1].executableName == "touch")
    }

    @Test func `resolve for allowlist unwraps busybox shell applets`() throws {
        let tmp = try makeTempDirForTests()
        let busybox = tmp.appendingPathComponent("busybox")
        let whoami = tmp.appendingPathComponent("whoami")
        try makeExecutableForTests(at: busybox)
        try makeExecutableForTests(at: whoami)

        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: [busybox.path, "sh", "-lc", "echo allowlisted && whoami"],
            rawCommand: nil,
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(resolutions.count == 2)
        #expect(resolutions[0].executableName == "echo")
        #expect(resolutions[1].resolvedPath == whoami.path)
        #expect(resolutions[1].executableName == "whoami")
    }

    @Test func `resolve for allowlist unwraps dispatch wrappers before shell wrappers`() throws {
        let tmp = try makeTempDirForTests()
        let whoami = tmp.appendingPathComponent("whoami")
        try makeExecutableForTests(at: whoami)

        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: ["/usr/bin/nice", "/bin/zsh", "-lc", "echo allowlisted && whoami"],
            rawCommand: nil,
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(resolutions.count == 2)
        #expect(resolutions[0].executableName == "echo")
        #expect(resolutions[1].resolvedPath == whoami.path)
        #expect(resolutions[1].executableName == "whoami")
    }

    @Test func `resolve for allowlist recurses through nested shell wrappers after dispatch wrappers`() throws {
        let tmp = try makeTempDirForTests()
        let whoami = tmp.appendingPathComponent("whoami")
        try makeExecutableForTests(at: whoami)

        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: ["/bin/sh", "-lc", "nice /bin/zsh -lc whoami"],
            rawCommand: nil,
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(resolutions.count == 1)
        #expect(resolutions[0].resolvedPath == whoami.path)
        #expect(resolutions[0].executableName == "whoami")
    }

    @Test func `resolve for allowlist fails closed when nested shell wrapper depth exceeds max`() throws {
        let tmp = try makeTempDirForTests()
        let whoami = tmp.appendingPathComponent("whoami")
        try makeExecutableForTests(at: whoami)

        var payload = "whoami"
        for _ in 0...ExecWrapperResolution.maxWrapperDepth {
            let escaped = payload
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            payload = "/bin/sh -lc \"\(escaped)\""
        }

        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: ["/bin/sh", "-lc", payload],
            rawCommand: nil,
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(resolutions.isEmpty)
    }

    @Test func `resolve for allowlist unwraps direct dispatch wrappers with canonical raw command`() {
        let command = ["/usr/bin/nice", "/usr/bin/printf", "ok"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "/usr/bin/nice /usr/bin/printf ok",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])

        #expect(resolutions.count == 1)
        #expect(resolutions[0].resolvedPath == "/usr/bin/printf")
        #expect(resolutions[0].executableName == "printf")
    }

    @Test func `resolve for allowlist unwraps env dispatch wrappers inside shell segments`() {
        let command = ["/bin/sh", "-lc", "env /usr/bin/touch /tmp/openclaw-allowlist-test"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "env /usr/bin/touch /tmp/openclaw-allowlist-test",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.count == 1)
        #expect(resolutions[0].resolvedPath == "/usr/bin/touch")
        #expect(resolutions[0].executableName == "touch")
    }

    @Test func `resolve for allowlist preserves env assignments inside shell segments`() {
        let command = ["/bin/sh", "-lc", "env FOO=bar /usr/bin/touch /tmp/openclaw-allowlist-test"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: "env FOO=bar /usr/bin/touch /tmp/openclaw-allowlist-test",
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.count == 1)
        #expect(resolutions[0].resolvedPath == "/usr/bin/env")
        #expect(resolutions[0].executableName == "env")
    }

    @Test func `resolve for allowlist preserves env wrapper with modifiers`() {
        let command = ["/usr/bin/env", "FOO=bar", "/usr/bin/printf", "ok"]
        let resolutions = ExecCommandResolution.resolveForAllowlist(
            command: command,
            rawCommand: nil,
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])
        #expect(resolutions.count == 1)
        #expect(resolutions[0].resolvedPath == "/usr/bin/env")
        #expect(resolutions[0].executableName == "env")
    }

    @Test func `approval evaluator resolves shell payload from canonical wrapper text`() async {
        let command = ["/bin/sh", "-lc", "/usr/bin/printf ok"]
        let rawCommand = "/bin/sh -lc \"/usr/bin/printf ok\""
        let evaluation = await ExecApprovalEvaluator.evaluate(
            command: command,
            rawCommand: rawCommand,
            cwd: nil,
            envOverrides: ["PATH": "/usr/bin:/bin"],
            agentId: nil)

        #expect(evaluation.displayCommand == rawCommand)
        #expect(evaluation.allowlistResolutions.count == 1)
        #expect(evaluation.allowlistResolutions[0].resolvedPath == "/usr/bin/printf")
        #expect(evaluation.allowlistResolutions[0].executableName == "printf")
    }

    @Test func `allowlist matcher falls back to shell script candidate path`() throws {
        let fixture = try Self.shellScriptFixture()

        let resolution = ExecCommandResolution.resolveForAllowlist(
            command: ["/usr/bin/nice", "bash", "scripts/save_crystal.sh"],
            rawCommand: nil,
            cwd: fixture.dir.path,
            env: ["PATH": "\(fixture.dir.path):/usr/bin:/bin"]).first

        let match = ExecAllowlistMatcher.match(
            entries: [ExecAllowlistEntry(pattern: fixture.script.path)],
            resolution: resolution)

        #expect(match?.pattern == fixture.script.path)
    }

    @Test func `allow always patterns unwrap env wrapper modifiers to the inner executable`() {
        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: ["/usr/bin/env", "FOO=bar", "/usr/bin/printf", "ok"],
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])

        #expect(patterns == ["/usr/bin/printf"])
    }

    @Test func `allow always patterns unwrap dispatch wrappers before shell wrappers`() throws {
        let tmp = try makeTempDirForTests()
        let whoami = tmp.appendingPathComponent("whoami")
        try makeExecutableForTests(at: whoami)

        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: ["/usr/bin/nice", "/bin/zsh", "-lc", "whoami"],
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(patterns == [whoami.path])
        #expect(!patterns.contains("/usr/bin/nice"))
    }

    @Test func `allow always patterns persist shell script paths without inline commands`() throws {
        let fixture = try Self.shellScriptFixture()

        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: ["bash", "scripts/save_crystal.sh"],
            cwd: fixture.dir.path,
            env: ["PATH": "\(fixture.dir.path):/usr/bin:/bin"])

        #expect(patterns == [fixture.script.path])
        #expect(!patterns.contains(fixture.bash.path))
    }

    @Test func `allow always patterns persist shell script paths through dispatch wrappers`() throws {
        let fixture = try Self.shellScriptFixture()

        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: ["/usr/bin/nice", "bash", "scripts/save_crystal.sh"],
            cwd: fixture.dir.path,
            env: ["PATH": "\(fixture.dir.path):/usr/bin:/bin"])

        #expect(patterns == [fixture.script.path])
        #expect(!patterns.contains(fixture.bash.path))
    }

    @Test func `allow always patterns unwrap busybox shell applets to inner executables`() throws {
        let tmp = try makeTempDirForTests()
        let busybox = tmp.appendingPathComponent("busybox")
        let whoami = tmp.appendingPathComponent("whoami")
        try makeExecutableForTests(at: busybox)
        try makeExecutableForTests(at: whoami)

        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: [busybox.path, "sh", "-lc", "whoami"],
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(patterns == [whoami.path])
        #expect(!patterns.contains(busybox.path))
    }

    @Test func `allow always patterns fail closed for unsupported busybox applets`() throws {
        let tmp = try makeTempDirForTests()
        let busybox = tmp.appendingPathComponent("busybox")
        try makeExecutableForTests(at: busybox)

        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: [busybox.path, "sed", "-n", "1p"],
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(patterns.isEmpty)
    }

    @Test func `allow always patterns fail closed for blocked dispatch wrappers`() {
        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: ["sudo", "/bin/zsh", "-lc", "whoami"],
            cwd: nil,
            env: ["PATH": "/usr/bin:/bin"])

        #expect(patterns.isEmpty)
    }

    @Test func `allow always patterns stop at shared transparent wrapper depth limit`() throws {
        let tmp = try makeTempDirForTests()
        let whoami = tmp.appendingPathComponent("whoami")
        try makeExecutableForTests(at: whoami)

        let patterns = ExecCommandResolution.resolveAllowAlwaysPatterns(
            command: ["nice", "nohup", "timeout", "5", "whoami"],
            cwd: tmp.path,
            env: ["PATH": "\(tmp.path):/usr/bin:/bin"])

        #expect(patterns.isEmpty)
    }

    @Test func `match all requires every segment to match`() {
        let first = ExecCommandResolution(
            rawExecutable: "echo",
            resolvedPath: "/usr/bin/echo",
            executableName: "echo",
            cwd: nil)
        let second = ExecCommandResolution(
            rawExecutable: "/usr/bin/touch",
            resolvedPath: "/usr/bin/touch",
            executableName: "touch",
            cwd: nil)
        let resolutions = [first, second]

        let partial = ExecAllowlistMatcher.matchAll(
            entries: [ExecAllowlistEntry(pattern: "/usr/bin/echo")],
            resolutions: resolutions)
        #expect(partial.isEmpty)

        let full = ExecAllowlistMatcher.matchAll(
            entries: [ExecAllowlistEntry(pattern: "/USR/BIN/ECHO"), ExecAllowlistEntry(pattern: "/usr/bin/touch")],
            resolutions: resolutions)
        #expect(full.count == 2)
    }
}
