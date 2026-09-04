import Foundation
import ArgumentParser
import Virtualization
import AppKit

public struct InjectCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "inject",
        abstract: "Launches the VM in GUI mode for interactive Setup Assistant completion."
    )

    @Argument(help: "Name of the VM image to configure")
    public var name: String

    public init() {}

    public func run() async throws {
        guard VZVirtualMachine.isSupported else {
            throw VMError.unsupportedHardware
        }

        let config = try VMConfig.load(name: name)

        // Asynchronously hop to Thread #1 (the Main Actor) to run AppKit
        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            let delegate = InjectAppDelegate(config: config)
            app.delegate = delegate
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

// MARK: - AppKit GUI Host Application Delegate

@MainActor
final class InjectAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    private let config: VMConfig
    private var window: NSWindow?
    private var virtualMachine: VZVirtualMachine?

    init(config: VMConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            print("=== Booting [\(config.name)] in GUI Mode ===")
            print("1. Complete macOS Setup Assistant.")
            print("2. Create an admin user account (e.g., admin / admin).")
            print("3. Enable Remote Login: System Settings -> General -> Sharing -> Remote Login (SSH).")
            print("4. When finished, shut down the VM via Apple Menu -> Shut Down.")

            let vmConfig = try buildVMConfiguration()
            let vm = VZVirtualMachine(configuration: vmConfig, queue: .main)
            self.virtualMachine = vm
            vm.delegate = self

            // Setup Host GUI Window
            let windowRect = NSRect(x: 100, y: 100, width: 1280, height: 800)
            let window = NSWindow(
                contentRect: windowRect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacBuilder Setup: \(config.name)"
            window.center()
            window.delegate = self

            // Embed Virtualization Display View
            let vmView = VZVirtualMachineView(frame: window.contentView!.bounds)
            vmView.autoresizingMask = [.width, .height]
            vmView.virtualMachine = vm
            vmView.capturesSystemKeys = true

            window.contentView?.addSubview(vmView)
            self.window = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate()

            vm.start { [weak self] result in
                switch result {
                case .success:
                    print("Hypervisor running. GUI window ready.")
                case .failure(let error):
                    print("Failed to start VM: \(error.localizedDescription)")
                    self?.terminateApp()
                }
            }
        } catch {
            print("Configuration Error: \(error.localizedDescription)")
            terminateApp()
        }
    }

    private func buildVMConfiguration() throws -> VZVirtualMachineConfiguration {
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
        if let mac = VZMACAddress(string: config.macAddress) {
            networkDevice.macAddress = mac
        }
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)]
        vmConfig.graphicsDevices = [graphics]

        // Input Devices for Setup Assistant Interaction
        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.pointingDevices = [
            VZUSBScreenCoordinatePointingDeviceConfiguration(),
            VZMacTrackpadConfiguration()
        ]

        try vmConfig.validate()
        return vmConfig
    }

    // MARK: - Lifecycle Management

    func windowWillClose(_ notification: Notification) {
        print("Window closed by user. Requesting guest shutdown...")
        if let vm = virtualMachine, vm.canRequestStop {
            try? vm.requestStop()
        }
        terminateApp()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            print("Guest OS shutdown detected. Closing GUI session.")
            self.terminateApp()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor in
            print("Virtual Machine stopped with error: \(error.localizedDescription)")
            self.terminateApp()
        }
    }

    func terminateApp() {
        NSApp.stop(nil)
        let dummyEvent = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        if let dummyEvent {
            NSApp.postEvent(dummyEvent, atStart: true)
        }
    }
}