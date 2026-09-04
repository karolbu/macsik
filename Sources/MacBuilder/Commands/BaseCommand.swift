import Foundation
import ArgumentParser
import Virtualization

public struct BaseCommand: AsyncParsableCommand {
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

        let vmDir = VMConfig.baseStorageURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: vmDir.path) {
            throw VMError.vmAlreadyExists(name)
        }

        print("=== Initializing Base macOS Installation [\(name)] ===")

        let ipswURL: URL
        if let ipsw {
            ipswURL = URL(fileURLWithPath: ipsw)
        } else {
            print("No IPSW provided. Fetching latest supported restore image from Apple...")
            let restoreImage = try await VZMacOSRestoreImage.fetchLatestSupported()
            ipswURL = restoreImage.url
            print("Using restore image: \(ipswURL.lastPathComponent)")
        }

        print("Loading restore image metadata...")
        let restoreImage = try await VZMacOSRestoreImage.load(from: ipswURL)
        guard let supportedConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VMError.installationFailed("No compatible hardware configuration found for this Mac.")
        }

        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)

        let diskSizeBytes = UInt64(diskSize) * 1024 * 1024 * 1024
        let macAddress = VZMACAddress.randomLocallyAdministered().string
        let config = VMConfig(
            name: name,
            cpuCount: cpu,
            memorySizeMB: UInt64(memory) * 1024,
            diskSizeBytes: diskSizeBytes,
            macAddress: macAddress
        )

        // 1. Create Sparse Disk
        print("Allocating \(diskSize) GB sparse disk...")
        FileManager.default.createFile(atPath: config.diskURL.path, contents: nil)
        let diskHandle = try FileHandle(forWritingTo: config.diskURL)
        try diskHandle.truncate(atOffset: diskSizeBytes)
        try diskHandle.close()

        // 2. Auxiliary Storage
        print("Initializing NVRAM auxiliary storage...")
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: config.auxiliaryStorageURL,
            hardwareModel: supportedConfig.hardwareModel,
            options: []
        )

        // 3. Persist Model & Identifier
        let machineIdentifier = VZMacMachineIdentifier()
        try supportedConfig.hardwareModel.dataRepresentation.write(to: config.hardwareModelURL)
        try machineIdentifier.dataRepresentation.write(to: config.machineIdentifierURL)
        try config.save()

        // 4. Construct VM Configuration for Installer
        let vmConfig = VZVirtualMachineConfiguration()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = supportedConfig.hardwareModel
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: config.auxiliaryStorageURL)
        platform.machineIdentifier = machineIdentifier
        vmConfig.platform = platform

        vmConfig.bootLoader = VZMacOSBootLoader()
        vmConfig.cpuCount = min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vmConfig.memorySize = min(config.memorySizeMB * 1024 * 1024, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: config.diskURL, readOnly: false)
        vmConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.macAddress = VZMACAddress(string: config.macAddress)!
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        // Graphics configuration is strictly required by the framework
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)]
        vmConfig.graphicsDevices = [graphics]

        try vmConfig.validate()

        // 5. Run Installation
        let vm = VZVirtualMachine(configuration: vmConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)

        print("Starting installation into \(name)...")
        let observation = installer.progress.observe(\.fractionCompleted) { progress, _ in
            let percent = String(format: "%.1f%%", progress.fractionCompleted * 100)
            print("\rInstalling macOS: \(percent)", terminator: "")
            fflush(stdout)
        }

        try await installer.install()
        observation.invalidate()
        print("\nBase macOS installation completed successfully.")
        print("Execute 'macbuilder inject \(name)' to configure user credentials and remote login.")
    }
}