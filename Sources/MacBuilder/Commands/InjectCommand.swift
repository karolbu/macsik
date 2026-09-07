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
    private var virtualMachine: VZVirtualMachine?
    private var virtualMachineView: VZVirtualMachineView?

    init(config: VMConfig) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            print("=== Booting [\(config.name)] in GUI Mode ===")
            print("1. Complete macOS Setup Assistant in the opened window.")
            print("2. Create an admin user account (e.g., admin / admin).")
            print("3. Enable Remote Login: System Settings -> General -> Sharing -> Remote Login (SSH).")
            print("4. When finished, shut down the VM via Apple Menu -> Shut Down.")
            fflush(stdout)

            setupApplicationMenu()

            // 1. Build and validate configuration according to Apple reference guidelines
            let vmConfig = try buildVMConfiguration()

            // 2. Initialize Virtual Machine strictly bound to DispatchQueue.main
            let vm = VZVirtualMachine(configuration: vmConfig, queue: .main)
            self.virtualMachine = vm
            vm.delegate = self

            // 3. Create Host Window
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

            // 4. Configure Virtual Machine View with explicit geometry before display attachment
            let vmView = VZVirtualMachineView(frame: NSRect(origin: .zero, size: windowSize))
            vmView.wantsLayer = true
            vmView.autoresizingMask = [.widthSizable, .heightSizable]
            vmView.virtualMachine = vm
            vmView.capturesSystemKeys = true
            if #available(macOS 14.0, *) {
                vmView.automaticallyReconfiguresDisplay = true
            }
            self.virtualMachineView = vmView

            window.contentView = vmView
            window.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }

            print("Starting hypervisor...")
            fflush(stdout)

            // 5. Asynchronous boot using completion handler directly on main queue
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

    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Setup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
    }

    private func buildVMConfiguration() throws -> VZVirtualMachineConfiguration {
        let vmConfig = VZVirtualMachineConfiguration()

        // 1. Hardware Model
        let hwModelData = try Data(contentsOf: config.hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hwModelData) else {
            throw VMError.invalidHardwareModel
        }
        guard hardwareModel.isSupported else {
            throw VMError.unsupportedHardwareModel
        }

        // 2. Machine Identifier
        let machineIDData = try Data(contentsOf: config.machineIdentifierURL)
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIDData) else {
            throw VMError.invalidMachineIdentifier
        }

        // 3. Platform Configuration
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: config.auxiliaryStorageURL)
        vmConfig.platform = platform

        vmConfig.bootLoader = VZMacOSBootLoader()

        // 4. Resource Allocation clamped within framework supported ranges
        let requestedCPU = config.cpuCount
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        vmConfig.cpuCount = min(max(requestedCPU, minCPU), maxCPU)

        let requestedRAM = config.memorySizeMB * 1024 * 1024
        let minRAM = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxRAM = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        vmConfig.memorySize = min(max(requestedRAM, minRAM), maxRAM)

        // 5. Virtual Storage Devices
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: config.diskURL, readOnly: false)
        vmConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // 6. Network Devices
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        guard let mac = VZMACAddress(string: config.macAddress) else {
            throw VMError.configurationInvalid("Invalid MAC address: \(config.macAddress)")
        }
        networkDevice.macAddress = mac
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [networkDevice]

        // 7. Graphics Display Configuration
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 220)
        ]
        vmConfig.graphicsDevices = [graphics]

        // 8. Input Devices
        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // 9. Audio Device (Output stream prevents guest CoreAudio setup daemon stalls)
        let audioConfig = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        audioConfig.streams = [outputStream]
        vmConfig.audioDevices = [audioConfig]

        try vmConfig.validate()
        return vmConfig
    }

    // MARK: - Lifecycle Management

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

    func terminateApp() {
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