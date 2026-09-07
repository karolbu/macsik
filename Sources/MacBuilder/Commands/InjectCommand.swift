import Foundation
import ArgumentParser
import Virtualization
import AppKit
import Security

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

        // Pre-flight check: Verify the executing binary has the virtualization entitlement
        try Self.verifyVirtualizationEntitlement()

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

    private static func verifyVirtualizationEntitlement() throws {
        var secCode: SecCode?
        guard SecCodeCopySelf([], &secCode) == errSecSuccess, let code = secCode else {
            return
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return
        }

        var information: CFDictionary?
        // SecCSFlags() initializes the default flags (rawValue = 0)
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return
        }

        if let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            if entitlements["com.apple.security.virtualization"] as? Bool != true {
                print("\n❌ FATAL: The executing binary is missing the 'com.apple.security.virtualization' entitlement.")
                print("Run the following command to sign the binary before executing:\n")
                print("  codesign --force --sign - --entitlements entitlements.plist .build/release/macbuilder\n")
                throw VMError.configurationInvalid("Missing com.apple.security.virtualization entitlement.")
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
    private var bootTimeoutTask: Task<Void, Never>?

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

            setupApplicationMenu()

            // 1. Build and validate configuration
            let vmConfig = try buildVMConfiguration()

            // 2. Initialize Virtual Machine
            let vm = VZVirtualMachine(configuration: vmConfig)
            self.virtualMachine = vm
            vm.delegate = self

            // 3. Configure Virtual Machine View
            let vmView = VZVirtualMachineView()
            vmView.virtualMachine = vm
            vmView.capturesSystemKeys = true
            if #available(macOS 14.0, *) {
                vmView.automaticallyReconfiguresDisplay = true
            }

            // 4. Create Host Window
            let windowSize = NSSize(width: 1200, height: 750)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacBuilder Setup: \(config.name)"
            window.contentView = vmView
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window

            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

            print("Starting hypervisor and spawning virtualization service...")
            fflush(stdout)

            // 5. Watchdog: Catch silent XPC service spawn failures
            startWatchdogTimer()

            // 6. Asynchronous boot using Swift Concurrency
            Task {
                do {
                    try await vm.start()
                    self.bootTimeoutTask?.cancel()
                    print("✅ Hypervisor running. macOS guest kernel is booting...")
                    print("Note: First boot takes ~25-40 seconds for the Apple logo and language picker to appear.")
                    fflush(stdout)
                } catch {
                    self.bootTimeoutTask?.cancel()
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

    private func startWatchdogTimer() {
        bootTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled {
                print("\n❌ ERROR: Hypervisor service (com.apple.Virtualization.VirtualMachine) failed to respond within 20 seconds.")
                print("Probable causes:")
                print(" 1. The binary code signature does not contain 'com.apple.security.virtualization'.")
                print(" 2. Another hypervisor or VM instance holds an exclusive lock on the disk image.")
                print(" 3. System Integrity / AMFI blocked the XPC helper service.")
                fflush(stdout)
                self.terminateApp()
            }
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
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 220)
        ]
        vmConfig.graphicsDevices = [graphics]

        vmConfig.keyboards = [VZUSBKeyboardConfiguration()]
        vmConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        try vmConfig.validate()
        return vmConfig
    }

    // MARK: - Lifecycle Management

    func windowWillClose(_ notification: Notification) {
        print("\nWindow closed. Terminating session...")
        fflush(stdout)
        bootTimeoutTask?.cancel()
        if let vm = virtualMachine, vm.canRequestStop {
            try? vm.requestStop()
        }
        terminateApp()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            print("\nGuest OS shutdown detected. Closing GUI session.")
            fflush(stdout)
            self.bootTimeoutTask?.cancel()
            self.terminateApp()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor in
            print("\n❌ Virtual Machine stopped unexpectedly with error: \(error.localizedDescription)")
            fflush(stdout)
            self.bootTimeoutTask?.cancel()
            self.terminateApp()
        }
    }

    func terminateApp() {
        bootTimeoutTask?.cancel()
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