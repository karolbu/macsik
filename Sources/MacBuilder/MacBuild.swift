import Foundation
import ArgumentParser

@main
public struct MacBuilder: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "macbuilder",
        abstract: "Apple Silicon Native macOS VM Automation Engine for CI/CD Infrastructure.",
        version: "1.0.0",
        subcommands: [
            BaseCommand.self,
            InjectCommand.self,
            BuildCommand.self
        ]
    )

    public init() {}
}