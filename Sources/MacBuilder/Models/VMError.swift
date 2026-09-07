import Foundation

public enum VMError: LocalizedError, Sendable {
    case vmNotFound(String)
    case vmAlreadyExists(String)
    case invalidHardwareModel
    case invalidMachineIdentifier
    case unsupportedHardwareModel
    case missingAuxiliaryStorage
    case missingDiskImage
    case missingEntitlement(String)
    case configurationInvalid(String)
    case installationFailed(String)
    case bootFailed(String)
    case networkTimeout
    case guestCommandFailed(exitCode: Int32)
    case unsupportedHardware
    case fileNotFound(String)

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
        case .unsupportedHardwareModel:
            return "The serialized hardware model is not supported on this host hardware."
        case .missingAuxiliaryStorage:
            return "The NVRAM auxiliary storage file is missing from the VM directory."
        case .missingDiskImage:
            return "The virtual disk image (Disk.img) is missing from the VM directory."
        case .missingEntitlement(let details):
            return "Code signing validation failed: \(details)"
        case .configurationInvalid(let reason):
            return "Invalid virtual machine configuration: \(reason)"
        case .installationFailed(let reason):
            return "macOS installation failed: \(reason)"
        case .bootFailed(let reason):
            return "Failed to boot virtual machine: \(reason)"
        case .networkTimeout:
            return "Timed out waiting for guest IP lease or SSH service readiness."
        case .guestCommandFailed(let code):
            return "Guest execution failed with non-zero exit code: \(code)"
        case .unsupportedHardware:
            return "Apple Virtualization framework is only supported on Apple Silicon Macs."
        case .fileNotFound(let path):
            return "Required file not found at path: \(path)"
        }
    }
}