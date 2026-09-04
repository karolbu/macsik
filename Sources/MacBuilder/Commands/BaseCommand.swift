import Foundation
import ArgumentParser
import Virtualization

public struct BaseCommand: AsyncParsableCommand, Sendable {
    public static let configuration = CommandConfiguration(
        commandName: "base",
        abstract: "Installs macOS from an IPSW restore image into a managed base VM."
    )

    @Argument(help: "Target VM name")
    public var name: String

    @Option(name: .long, help: "Path to a local macOS IPSW file")
    public var ipsw: String?

    @Option(name: .long, help: "Allocated CPU cores (Default: 4)")
    public var cpu: Int = 4

    @Option(name: .long, help: "Allocated memory in GB (Default: 16)")
    public var memory: Int = 16

    @Option(name: .long, help: "Virtual disk size in GB (Default: 64)")
    public var diskSize: Int = 64

    public init() {}

    public func run() async throws {
        guard VZVirtualMachine.isSupported else {
            throw VMError.unsupportedHardware
        }

        let vmDir = VMConfig.baseStorageURL.appendingPathComponent(name, isDirectory: true)

        // Automatically clean up partial dirty directories from previous interrupted runs
        if FileManager.default.fileExists(atPath: vmDir.path) {
            print("Found existing/incomplete VM directory for '\(name)'. Cleaning up for fresh installation...")
            try FileManager.default.removeItem(at: vmDir)
        }

        guard let ipswPath = ipsw else {
            throw VMError.installationFailed("Please specify the path to a local macOS IPSW file using --ipsw <path>")
        }

        // Expand '~' and resolve to an absolute standardized URL
        let expandedPath = NSString(string: ipswPath).expandingTildeInPath
        let localRestoreImageURL: URL
        if expandedPath.hasPrefix("/") {
            localRestoreImageURL = URL(fileURLWithPath: expandedPath).standardizedFileURL.absoluteURL
        } else {
            let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            localRestoreImageURL = URL(fileURLWithPath: expandedPath, relativeTo: currentDir).standardizedFileURL.absoluteURL
        }

        guard FileManager.default.fileExists(atPath: localRestoreImageURL.path) else {
            throw VMError.fileNotFound(localRestoreImageURL.path)
        }

        print("=== Initializing Base macOS Installation [\(name)] ===")
        print("Using restore image: \(localRestoreImageURL.path)")

        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)

        // 1. Load Restore Image metadata
        print("Loading restore image metadata...")
        let restoreImage: VZMacOSRestoreImage
        do {
            restoreImage = try await VZMacOSRestoreImage.image(from: localRestoreImageURL)
        } catch {
            throw VMError.installationFailed("Failed to load restore image: \(error.localizedDescription)")
        }

        guard restoreImage.isSupported else {
            throw VMError.installationFailed("The restore image is not supported by this Mac host hardware.")
        }

        guard let supportedConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VMError.installationFailed("No compatible hardware configuration found for this Mac host.")
        }

        guard supportedConfig.hardwareModel.isSupported else {
            throw VMError.installationFailed("The hardware model in this restore image is not supported on this host.")
        }

        let diskSizeBytes = UInt64(diskSize) * 1024 * 1024 * 1024
        let macAddress = VZMACAddress.randomLocallyAdministered().string
        let config = VMConfig(
            name: name,
            cpuCount: cpu,
            memorySizeMB: UInt64(memory) * 1024,
            diskSizeBytes: diskSizeBytes,
            macAddress: macAddress
        )

        // 2. Allocate Sparse Disk
        print("[1/6] Allocating \(diskSize) GB sparse disk...")
        FileManager.default.createFile(atPath: config.diskURL.path, contents: nil)
        let diskHandle = try FileHandle(forWritingTo: config.diskURL)
        try diskHandle.truncate(atOffset: diskSizeBytes)
        try diskHandle.close()

        // 3. Initialize NVRAM Auxiliary Storage and keep instance
        print("[2/6] Initializing NVRAM auxiliary storage...")
        let auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: config.auxiliaryStorageURL,
            hardwareModel: supportedConfig.hardwareModel,
            options: [.allowOverwrite]
        )

        // 4. Persist Hardware Model, Machine Identifier, and Config
        print("[3/6] Saving VM hardware metadata...")
        let machineIdentifier = VZMacMachineIdentifier()
        try supportedConfig.hardwareModel.dataRepresentation.write(to: config.hardwareModelURL)
        try machineIdentifier.dataRepresentation.write(to: config.machineIdentifierURL)
        try config.save()

        // 5. Build minimal configuration required for installation
        print("[4/6] Building installation configuration...")
        let vmConfig = VZVirtualMachineConfiguration()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = supportedConfig.hardwareModel
        platform.auxiliaryStorage = auxiliaryStorage
        platform.machineIdentifier = machineIdentifier
        vmConfig.platform = platform

        vmConfig.bootLoader = VZMacOSBootLoader()

        // Ensure allocated resources meet Apple's minimum requirements for this image
        let effectiveCPU = max(config.cpuCount, supportedConfig.minimumSupportedCPUCount)
        let effectiveRAM = max(config.memorySizeMB * 1024 * 1024, supportedConfig.minimumSupportedMemorySize)
        vmConfig.cpuCount = min(effectiveCPU, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vmConfig.memorySize = min(effectiveRAM, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: config.diskURL, readOnly: false)
        vmConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        print("[5/6] Validating configuration...")
        try vmConfig.validate()

        // 6. Initialize Hypervisor and Installer
        print("[6/6] Initializing macOS installer...")
        let vm = VZVirtualMachine(configuration: vmConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: localRestoreImageURL)

        print("Starting installation into \(name)...")
        let observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            let percent = String(format: "%.1f%%", progress.fractionCompleted * 100)
            print("\rInstalling macOS: \(percent)", terminator: "")
            fflush(stdout)
        }
        defer {
            observation.invalidate()
        }

        try await installer.install()
        print("\nBase macOS installation completed successfully.")
        print("Run 'macbuilder inject \(name)' to complete Setup Assistant and enable Remote Login.")
    }
}