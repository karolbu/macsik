import Foundation

public enum VMError: LocalizedError, Sendable {
    case vmNotFound(String)
    case vmAlreadyExists(String)
    case invalidHardwareModel
    case invalidMachineIdentifier
    case configurationInvalid(String)
    case installationFailed(String)
    case bootFailed(String)
    case networkTimeout
    case guestCommandFailed(exitCode: Int32)
    case unsupportedHardware

    public var errorDescription: String? {
        switch self {
        case .vmNotFound(let name):
            return "Virtual machine '\(name)' does not exist."
        case .vmAlreadyExists(let name):
            return "Virtual machine '\(name)' already exists."
        case .invalidHardwareModel:
            return "Failed to deserialize VZMacHardwareModel from storage."
        case .invalidMachineIdentifier:
            return "Failed to deserialize VZMacMachineIdentifier from storage."
        case .configurationInvalid(let reason):
            return "Invalid virtual machine configuration: \(reason)"
        case .installationFailed(let reason):
            return "macOS installation failed: \(reason)"
        case .bootFailed(let reason):
            return "Failed to boot virtual machine: \(reason)"
        case .networkTimeout:
            return "Timed out waiting for guest IP address / SSH readiness."
        case .guestCommandFailed(let code):
            return "Guest execution terminated with non-zero exit code: \(code)"
        case .unsupportedHardware:
            return "Virtualization is only supported on Apple Silicon hardware."
        }
    }
}