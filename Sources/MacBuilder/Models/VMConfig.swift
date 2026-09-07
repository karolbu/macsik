import Foundation
import Virtualization

public struct VMConfig: Codable, Sendable {
    public let name: String
    public var cpuCount: Int
    public var memorySizeMB: UInt64
    public var diskSizeBytes: UInt64
    public var macAddress: String

    public init(
        name: String,
        cpuCount: Int = 4,
        memorySizeMB: UInt64 = 16384,
        diskSizeBytes: UInt64 = 68719476736, // 64 GB
        macAddress: String
    ) {
        self.name = name
        self.cpuCount = cpuCount
        self.memorySizeMB = memorySizeMB
        self.diskSizeBytes = diskSizeBytes
        self.macAddress = macAddress
    }

    public static var baseStorageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".macbuilder", isDirectory: true)
            .appendingPathComponent("vms", isDirectory: true)
    }

    public var vmDirectory: URL {
        Self.baseStorageURL.appendingPathComponent(name, isDirectory: true)
    }

    public var diskURL: URL {
        vmDirectory.appendingPathComponent("Disk.img")
    }

    public var auxiliaryStorageURL: URL {
        vmDirectory.appendingPathComponent("AuxiliaryStorage.bin")
    }

    public var hardwareModelURL: URL {
        vmDirectory.appendingPathComponent("HardwareModel.bin")
    }

    public var machineIdentifierURL: URL {
        vmDirectory.appendingPathComponent("MachineIdentifier.bin")
    }

    public var configFileURL: URL {
        vmDirectory.appendingPathComponent("config.json")
    }

    public func validateFilesExist() throws {
        guard FileManager.default.fileExists(atPath: diskURL.path) else {
            throw VMError.missingDiskImage
        }
        guard FileManager.default.fileExists(atPath: auxiliaryStorageURL.path) else {
            throw VMError.missingAuxiliaryStorage
        }
        guard FileManager.default.fileExists(atPath: hardwareModelURL.path) else {
            throw VMError.fileNotFound(hardwareModelURL.path)
        }
        guard FileManager.default.fileExists(atPath: machineIdentifierURL.path) else {
            throw VMError.fileNotFound(machineIdentifierURL.path)
        }
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(self)
        try data.write(to: configFileURL)
    }

    public static func load(name: String) throws -> VMConfig {
        let dir = Self.baseStorageURL.appendingPathComponent(name, isDirectory: true)
        let configURL = dir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw VMError.vmNotFound(name)
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(VMConfig.self, from: data)
    }

    /// Performs an instantaneous APFS Copy-on-Write clone of the VM bundle.
    public static func clone(from sourceName: String, to targetName: String) throws -> VMConfig {
        let sourceConfig = try load(name: sourceName)
        try sourceConfig.validateFilesExist()

        let targetDir = Self.baseStorageURL.appendingPathComponent(targetName, isDirectory: true)

        try FileManager.default.createDirectory(at: Self.baseStorageURL, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.removeItem(at: targetDir)
        }

        try FileManager.default.copyItem(at: sourceConfig.vmDirectory, to: targetDir)

        let newMac = VZMACAddress.randomLocallyAdministered().string
        let newConfig = VMConfig(
            name: targetName,
            cpuCount: sourceConfig.cpuCount,
            memorySizeMB: sourceConfig.memorySizeMB,
            diskSizeBytes: sourceConfig.diskSizeBytes,
            macAddress: newMac
        )
        try newConfig.save()
        return newConfig
    }

    public static func remove(name: String) throws {
        let dir = Self.baseStorageURL.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Validates that the current running process possesses the required com.apple.security.virtualization entitlement.
    public static func verifyVirtualizationEntitlement() throws {
        var secCode: SecCode?
        guard SecCodeCopySelf([], &secCode) == errSecSuccess, let code = secCode else {
            throw VMError.missingEntitlement("Unable to inspect process dynamic code signature.")
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw VMError.missingEntitlement("Unable to obtain static code object.")
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            throw VMError.missingEntitlement("Unable to extract code signing dictionary.")
        }

        guard let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            throw VMError.missingEntitlement("No entitlements dictionary embedded in binary. Execute: codesign --force --sign - --entitlements entitlements.plist <binary>")
        }

        guard entitlements["com.apple.security.virtualization"] as? Bool == true else {
            throw VMError.missingEntitlement("The 'com.apple.security.virtualization' entitlement is missing or set to false.")
        }
    }
}