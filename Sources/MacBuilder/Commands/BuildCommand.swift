import Foundation
import ArgumentParser
import Virtualization

public struct BuildCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Boots a headless VM instance and executes declared workloads inside the guest."
    )

    @Argument(help: "Base VM name")
    public var name: String

    @Option(name: .long, help: "Command to execute inside the guest")
    public var cmd: String = "echo \"success\""

    @Option(name: .long, help: "SSH username inside guest")
    public var user: String = "admin"

    @Option(name: .long, help: "SSH password inside guest")
    public var password: String = "admin"

    @Option(name: .long, help: "Optional path to SSH private key")
    public var sshKey: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Use an ephemeral APFS clone to maintain base cleanliness")
    public var ephemeral: Bool = true

    @Option(name: .long, help: "Boot & network readiness timeout (seconds)")
    public var timeout: Double = 120.0

    public init() {}

    public func run() async throws {
        try await VMRunner.runBuild(
            name: name,
            cmd: cmd,
            user: user,
            password: password,
            sshKey: sshKey,
            ephemeral: ephemeral,
            timeout: timeout
        )
    }
}

// MARK: - MainActor-Isolated Build Runner Engine

@MainActor
public enum VMRunner {
    public static func runBuild(
        name: String,
        cmd: String,
        user: String,
        password: String,
        sshKey: String?,
        ephemeral: Bool,
        timeout: Double
    ) async throws {
        guard VZVirtualMachine.isSupported else {
            throw VMError.unsupportedHardware
        }

        let runName = ephemeral ? "\(name)-ephemeral-\(UUID().uuidString.prefix(8))" : name
        let targetConfig: VMConfig

        if ephemeral {
            print("Creating APFS Copy-on-Write clone: \(runName)...")
            targetConfig = try VMConfig.clone(from: name, to: runName)
        } else {
            targetConfig = try VMConfig.load(name: name)
        }

        defer {
            if ephemeral {
                print("Cleaning up ephemeral instance [\(runName)]...")
                try? VMConfig.remove(name: runName)
            }
        }

        print("=== Booting [\(runName)] in Headless Mode ===")
        let vm = try buildHeadlessVM(config: targetConfig)

        try await vm.start()
        print("Hypervisor running. Waiting for guest OS boot and DHCP lease...")

        let networkService = NetworkService()
        let guestIP = try await networkService.resolveGuestIP(macAddress: targetConfig.macAddress, timeout: timeout)
        print("Guest network online. IP Address: \(guestIP)")

        print("Waiting for SSH service readiness on port 22...")
        try await networkService.waitForPort(host: guestIP, port: 22, timeout: timeout)
        print("Guest SSH ready. Executing workload: \(cmd)\n----------------------------------------")

        let sshService = SSHService()
        let exitCode = try sshService.execute(
            host: guestIP,
            port: 22,
            user: user,
            password: password,
            keyPath: sshKey,
            command: cmd
        )

        print("----------------------------------------\nWorkload completed with exit code: \(exitCode)")

        print("Powering down VM...")
        if vm.canRequestStop {
            try? vm.requestStop()
            for _ in 0..<10 {
                if vm.state == .stopped { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        if vm.state != .stopped {
            try? await vm.stop()
        }

        if exitCode != 0 {
            throw VMError.guestCommandFailed(exitCode: exitCode)
        }
    }

    private static func buildHeadlessVM(config: VMConfig) throws -> VZVirtualMachine {
        let vmConfig = VZVirtualMachineConfiguration()

        guard let hwModelData = try? Data(contentsOf: config.hardwareModelURL),
              let hardwareModel = VZMacHardwareModel(dataRepresentation: hwModelData) else {
            throw VMError.invalidHardwareModel
        }

        guard let machineIDData = try? Data(contentsOf: config.machineIdentifierURL),
              let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIDData) else {
            throw VMError.invalidMachineIdentifier
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: config.auxiliaryStorageURL)
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

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)]
        vmConfig.graphicsDevices = [graphics]

        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        try vmConfig.validate()
        return VZVirtualMachine(configuration: vmConfig, queue: .main)
    }
}