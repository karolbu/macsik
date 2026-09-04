import Foundation
import Virtualization
import Darwin

public final class NetworkService: Sendable {
    public init() {}

    /// Resolves the guest IP address assigned to a specific MAC address via Apple NAT DHCP or ARP cache.
    public func resolveGuestIP(macAddress: String, timeout: TimeInterval = 60.0) async throws -> String {
        let normalizedTargetMAC = normalizeMAC(macAddress)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let ip = parseDHCPLeases(targetMAC: normalizedTargetMAC) {
                return ip
            }
            if let ip = parseARPTable(targetMAC: normalizedTargetMAC) {
                return ip
            }
            try await Task.sleep(for: .seconds(1))
        }

        throw VMError.networkTimeout
    }

    /// Polls a TCP port (default 22 for SSH) until the guest accepts socket connections.
    public func waitForPort(host: String, port: Int32 = 22, timeout: TimeInterval = 90.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if isPortOpen(host: host, port: port) {
                try await Task.sleep(for: .seconds(2))
                return
            }
            try await Task.sleep(for: .seconds(1))
        }

        throw VMError.networkTimeout
    }

    // MARK: - Format Normalization

    private func normalizeMAC(_ mac: String) -> String {
        let cleaned = mac.lowercased().replacingOccurrences(of: "-", with: ":")
        let components = cleaned.components(separatedBy: ":")
        var paddedParts: [String] = []

        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed.count == 1 {
                    paddedParts.append("0" + trimmed)
                } else {
                    paddedParts.append(trimmed)
                }
            }
        }
        return paddedParts.joined(separator: ":")
    }

    // MARK: - DHCP & ARP Parsers

    private func parseDHCPLeases(targetMAC: String) -> String? {
        let leasePath = "/var/db/dhcpd_leases"
        guard let content = try? String(contentsOfFile: leasePath, encoding: .utf8) else {
            return nil
        }

        let ipPattern = #"ip_address=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"#
        let hwPattern = #"hw_address=(?:[0-9]+,)?([0-9a-fA-F:]+)"#

        guard let ipRegex = try? NSRegularExpression(pattern: ipPattern),
              let hwRegex = try? NSRegularExpression(pattern: hwPattern) else {
            return nil
        }

        let blocks = content.components(separatedBy: "}")
        for block in blocks {
            let nsBlock = block as NSString
            let blockRange = NSRange(location: 0, length: nsBlock.length)

            guard let ipMatch = ipRegex.firstMatch(in: block, options: [], range: blockRange),
                  let hwMatch = hwRegex.firstMatch(in: block, options: [], range: blockRange) else {
                continue
            }

            if ipMatch.numberOfRanges >= 2 && hwMatch.numberOfRanges >= 2 {
                let foundIP: String = nsBlock.substring(with: ipMatch.range(at: 1))
                let foundHW: String = nsBlock.substring(with: hwMatch.range(at: 1))

                if normalizeMAC(foundHW) == targetMAC {
                    return foundIP
                }
            }
        }
        return nil
    }

    private func parseARPTable(targetMAC: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Matches ARP lines formatted as: ? (192.168.64.4) at 5a:94:ef:12:34:56 on bridge100 ...
            let arpPattern = #"\(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\)\s+at\s+([0-9a-fA-F:]+)"#
            guard let regex = try? NSRegularExpression(pattern: arpPattern) else { return nil }

            for line in output.components(separatedBy: .newlines) {
                let nsLine = line as NSString
                let fullRange = NSRange(location: 0, length: nsLine.length)

                if let match = regex.firstMatch(in: line, options: [], range: fullRange) {
                    if match.numberOfRanges >= 3 {
                        let ipFound: String = nsLine.substring(with: match.range(at: 1))
                        let macFound: String = nsLine.substring(with: match.range(at: 2))

                        if normalizeMAC(macFound) == targetMAC {
                            return ipFound
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - POSIX Socket Probe

    private func isPortOpen(host: String, port: Int32) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let res else {
            return false
        }
        defer { freeaddrinfo(res) }

        let sock = socket(res.pointee.ai_family, res.pointee.ai_socktype, res.pointee.ai_protocol)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        return connect(sock, res.pointee.ai_addr, res.pointee.ai_addrlen) == 0
    }
}