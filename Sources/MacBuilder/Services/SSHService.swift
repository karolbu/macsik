import Foundation

public final class SSHService: Sendable {
    public init() {}

    public func execute(
        host: String,
        port: Int = 22,
        user: String,
        password: String? = nil,
        keyPath: String? = nil,
        command: String
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "-p", "\(port)"
        ]

        var askpassScriptURL: URL? = nil
        var environment = ProcessInfo.processInfo.environment

        if let keyPath {
            arguments += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
        } else if let password {
            let tempDir = FileManager.default.temporaryDirectory
            let scriptURL = tempDir.appendingPathComponent("askpass-\(UUID().uuidString).sh")
            let scriptContent = "#!/bin/sh\nexec echo '\(password)'\n"
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            askpassScriptURL = scriptURL
            environment["SSH_ASKPASS"] = scriptURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "dummy:0"
        }

        arguments.append("\(user)@\(host)")
        arguments.append(command)

        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        defer {
            if let askpassScriptURL {
                try? FileManager.default.removeItem(at: askpassScriptURL)
            }
        }

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}