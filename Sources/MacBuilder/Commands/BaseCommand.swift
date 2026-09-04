import Foundation
import ArgumentParser
import Virtualization

public struct BaseCommand: ParsableCommand {
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

    public mutating func run() throws {
        guard VZVirtualMachine.isSupported else {
            throw VMError.unsupportedHardware
        }

        let vmDir = VMConfig.baseStorageURL.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: vmDir.path) {
            throw VMError.vmAlreadyExists(name)
        }

        guard let ipswPath = ipsw else {
            throw VMError.installationFailed("Please specify the path to a local macOS IPSW file using --ipsw <path>")
        }

        // 1. Resolve to an absolute, standardized file URL
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let localRestoreImageURL = URL(fileURLWithPath: ipswPath, relativeTo: currentDir).standardizedFileURL.absoluteURL

        guard FileManager.default.fileExists(atPath: localRestoreImageURL.path) else {
            throw VMError.fileNotFound(localRestoreImageURL.path)
        }

        print("=== Initializing Base macOS Installation [\(name)] ===")
        print("Using restore image: \(localRestoreImageURL.path)")

        try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)

        // 2. Load Restore Image on the Main RunLoop
        print("Loading restore image metadata...")
        var loadedImage: VZMacOSRestoreImage?
        var loadError: Error?
        let currentRunLoop = CFRunLoopGetCurrent()

        VZMacOSRestoreImage.load(from: localRestoreImageURL) { result in
            switch result {
            case .success(let image):
                loadedImage = image
            case .failure(let error):
                loadError = error
            }
            CFRunLoopStop(currentRunLoop)
        }
        CFRunLoopRun()

        if let loadError {
            throw VMError.installationFailed("Failed to load restore image: \(loadError.localizedDescription)")
        }
        guard let restoreImage = loadedImage else {
            throw VMError.installationFailed("Failed to load restore image: unknown error.")
        }
        guard restoreImage.isSupported else {
            throw VMError.installationFailed("The restore image is not supported by this host.")
        }
        guard let supportedConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VMError.installationFailed("No compatible hardware configuration found for this Mac host.")
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

        // 3. Allocate Sparse Disk
        print("Allocating \(diskSize) GB sparse disk...")
        FileManager.default.createFile(atPath: config.diskURL.path, contents: nil)
        let diskHandle = try FileHandle(forWritingTo: config.diskURL)
        try diskHandle.truncate(atOffset: diskSizeBytes)
        try diskHandle.close()

        // 4. Initialize NVRAM Auxiliary Storage
        print("Initializing NVRAM auxiliary storage...")
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: config.auxiliaryStorageURL,
            hardwareModel: supportedConfig.hardwareModel,
            options: []
        )

        // 5. Persist Model, Identifier, and Config
        let machineIdentifier = VZMacMachineIdentifier()
        try supportedConfig.hardwareModel.dataRepresentation.write(to: config.hardwareModelURL)
        try machineIdentifier.dataRepresentation.write(to: config.machineIdentifierURL)
        try config.save()

        // 6. Construct VM Configuration
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
        if let mac = VZMACAddress(string: config.macAddress) {
            networkDevice.macAddress = mac
        }
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)]
        vmConfig.graphicsDevices = [graphics]

        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.pointingDevices = [
            VZUSBScreenCoordinatePointingDeviceConfiguration(),
            VZMacTrackpadConfiguration()
        ]

        try vmConfig.validate()

        // 7. Execute Installer bound explicitly to the Main RunLoop
        let vm = VZVirtualMachine(configuration: vmConfig, queue: .main)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: localRestoreImageURL)

        print("Starting macOS installation into \(name)...")
        var installError: Error?
        let installRunLoop = CFRunLoopGetCurrent()

        let observer = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            let percent = String(format: "%.1f%%", progress.fractionCompleted * 100)
            print("\rInstalling macOS: \(percent)", terminator: "")
            fflush(stdout)
        }

        installer.install { result in
            if case .failure(let error) = result {
                installError = error
            }
            CFRunLoopStop(installRunLoop)
        }

        CFRunLoopRun()
        observer.invalidate()

        if let installError {
            print("")
            throw VMError.installationFailed(installError.localizedDescription)
        }

        print("\nBase macOS installation completed successfully.")
        print("Execute 'macbuilder inject \(name)' to configure user credentials and remote login.")
    }
}