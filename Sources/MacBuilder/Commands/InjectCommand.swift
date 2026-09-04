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
            fflush(stdout)

            let vmConfig = try buildVMConfiguration()
            let vm = VZVirtualMachine(configuration: vmConfig, queue: .main)
            self.virtualMachine = vm
            vm.delegate = self

            // 1. Configure the Virtual Machine View
            let vmView = VZVirtualMachineView()
            vmView.virtualMachine = vm
            vmView.capturesSystemKeys = true
            vmView.automaticallyReconfiguresDisplay = true

            // 2. Setup Host Window sized appropriately for 1512x982 display
            let windowSize = NSSize(width: 1200, height: 750)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacBuilder Setup: \(config.name)"
            
            // Set vmView directly as root contentView to enable Metal layer compositing
            window.contentView = vmView
            window.center()
            window.delegate = self
            self.window = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate()

            print("Starting hypervisor...")
            fflush(stdout)

            vm.start { [weak self] result in
                switch result {
                case .success:
                    print("Hypervisor running. macOS guest kernel is booting...")
                    print("Note: First boot takes 25-45 seconds to initialize WindowServer and show Setup Assistant.")
                    fflush(stdout)
                case .failure(let error):
                    print("Failed to start VM: \(error.localizedDescription)")
                    fflush(stdout)
                    self?.terminateApp()
                }
            }
        } catch {
            print("Configuration Error: \(error.localizedDescription)")
            fflush(stdout)
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

        // Dynamically match the host MacBook's Liquid Retina display characteristics
        let graphics = VZMacGraphicsDeviceConfiguration()
        if let screen = NSScreen.main {
            let display = VZMacGraphicsDisplayConfiguration(
                for: screen,
                sizeInPoints: NSSize(width: 1200, height: 750)
            )
            graphics.displays = [display]
        } else {
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 144)
            ]
        }
        vmConfig.graphicsDevices = [graphics]

        // Input Devices
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
        print("\nWindow closed by user. Requesting guest shutdown...")
        fflush(stdout)
        if let vm = virtualMachine, vm.canRequestStop {
            try? vm.requestStop()
        }
        terminateApp()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            print("\nGuest OS shutdown detected. Closing GUI session.")
            fflush(stdout)
            self.terminateApp()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor in
            print("\nVirtual Machine stopped with error: \(error.localizedDescription)")
            fflush(stdout)
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