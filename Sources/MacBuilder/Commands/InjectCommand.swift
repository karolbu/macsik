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

        try VMConfig.verifyVirtualizationEntitlement()

        let config = try VMConfig.load(name: name)
        try config.validateFilesExist()

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
    private var virtualMachineView: VZVirtualMachineView?
    private var virtualMachine: VZVirtualMachine?

    init(config: VMConfig) {
        self.config = config
        super.init()
    }

    // MARK: - NSApplicationDelegate Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupApplicationMenu()

        // 1. Setup Host Window and View hierarchy first (matching Apple's Storyboard/Nib model)
        let windowSize = NSSize(width: 1280, height: 800)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacBuilder Setup: \(config.name)"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let vmView = VZVirtualMachineView(frame: NSRect(origin: .zero, size: windowSize))
        vmView.autoresizingMask = [.width, .height]
        self.virtualMachineView = vmView
        window.contentView = vmView

        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // 2. Dispatch VM setup to the next runloop turn (matching Apple's sample implementation)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.startConfiguredVirtualMachine()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let vm = virtualMachine, vm.state == .running {
            if vm.canRequestStop {
                try? vm.requestStop()
            } else if vm.canStop {
                vm.stop { _ in
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
        }
        return .terminateNow
    }

    // MARK: - Virtual Machine Construction & Execution

    private func startConfiguredVirtualMachine() {
        do {
            print("=== Booting [\(config.name)] in GUI Mode ===")
            print("1. Complete macOS Setup Assistant in the opened window.")
            print("2. Create an admin user account (e.g., admin / admin).")
            print("3. Enable Remote Login: System Settings -> General -> Sharing -> Remote Login (SSH).")
            print("4. When finished, shut down the VM via Apple Menu -> Shut Down.")
            fflush(stdout)

            // 1. Construct VM Configuration
            let vmConfig = try buildVMConfiguration()

            // 2. Initialize VZVirtualMachine matching Apple's standard initializer
            let vm = VZVirtualMachine(configuration: vmConfig)
            self.virtualMachine = vm
            vm.delegate = self

            // 3. Attach Virtual Machine to the active View
            guard let vmView = self.virtualMachineView else {
                throw VMError.configurationInvalid("Host VM view was deallocated.")
            }
            vmView.virtualMachine = vm
            vmView.capturesSystemKeys = true

            if #available(macOS 14.0, *) {
                // Configure the view to respond to dynamic display changes
                vmView.automaticallyReconfiguresDisplay = true
            }

            print("Starting hypervisor and guest operating system...")
            fflush(stdout)

            // 4. Start Virtual Machine execution using completion handler
            vm.start { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    print("✅ Hypervisor running. macOS guest kernel is booting...")
                    print("macOS Setup Assistant will appear in the GUI window.")
                    fflush(stdout)
                case .failure(let error):
                    print("\n❌ Failed to start Virtual Machine: \(error.localizedDescription)")
                    if let vzError = error as? VZError {
                        print("Details: \(vzError)")
                    }
                    fflush(stdout)
                    self.terminateApp()
                }
            }
        } catch {
            print("\n❌ Configuration Error: \(error.localizedDescription)")
            fflush(stdout)
            terminateApp()
        }
    }

    // MARK: - Hardware Configuration Pipeline

    private func buildVMConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()

        // 1. Hardware Model & Machine Identifier
        let hwModelData = try Data(contentsOf: config.hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hwModelData) else {
            throw VMError.invalidHardwareModel
        }
        guard hardwareModel.isSupported else {
            throw VMError.unsupportedHardwareModel
        }

        let machineIDData = try Data(contentsOf: config.machineIdentifierURL)
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIDData) else {
            throw VMError.invalidMachineIdentifier
        }

        // 2. Platform Configuration using contentsOf for saved NVRAM
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: config.auxiliaryStorageURL)
        vmConfig.platform = platform

        // 3. Bootloader
        vmConfig.bootLoader = VZMacOSBootLoader()

        // 4. Resource Allocation
        let requestedCPU = config.cpuCount
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        vmConfig.cpuCount = min(max(requestedCPU, minCPU), maxCPU)

        let requestedRAM = config.memorySizeMB * 1024 * 1024
        let minRAM = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxRAM = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        vmConfig.memorySize = min(max(requestedRAM, minRAM), maxRAM)

        // 5. Virtual Block Storage (Disk Image)
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: config.diskURL, readOnly: false)
        vmConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // 6. Network Device
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        if let mac = VZMACAddress(string: config.macAddress) {
            networkDevice.macAddress = mac
        }
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        // 7. Graphics Display Configuration (matching Apple's 80 PPI baseline)
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
        ]
        vmConfig.graphicsDevices = [graphics]

        // 8. Human Interface Devices
        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // 9. Virtio Audio Device
        let audioConfig = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        audioConfig.streams = [outputStream]
        vmConfig.audioDevices = [audioConfig]

        // 10. Validate Full Configuration
        try vmConfig.validate()

        return vmConfig
    }

    // MARK: - Window and App Management

    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Setup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
    }

    func windowWillClose(_ notification: Notification) {
        print("\nWindow closed. Terminating virtual machine session...")
        fflush(stdout)
        if let vm = virtualMachine {
            if vm.canRequestStop {
                try? vm.requestStop()
            } else if vm.canStop {
                vm.stop { _ in }
            }
        }
        terminateApp()
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            print("\nGuest OS shutdown detected. Closing GUI session.")
            fflush(stdout)
            self.terminateApp()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor in
            print("\n❌ Virtual Machine stopped unexpectedly with error: \(error.localizedDescription)")
            fflush(stdout)
            self.terminateApp()
        }
    }

    private func terminateApp() {
        if NSApp.isRunning {
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
}