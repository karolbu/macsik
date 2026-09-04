import Foundation
import Virtualization
import Darwin

public final class NetworkService: Sendable {
    public init() {}

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

    private func normalizeMAC(_ mac: String) -> String {
        mac.lowercased()
            .replacingOccurrences(of: "-", with: ":")
            .split(separator: ":")
            .map { part in
                part.count == 1 ? "0\(part)" : String(part)
            }
            .joined(separator: ":")
    }

    private func parseDHCPLeases(targetMAC: String) -> String? {
        let leasePath = "/var/db/dhcpd_leases"
        guard let content = try? String(contentsOfFile: leasePath, encoding: .utf8) else {
            return nil
        }

        let entries = content.components(separatedBy: "}")
        for entry in entries {
            guard let hwIndex = entry.range(of: "hw_address=")?.upperBound,
                  let ipIndex = entry.range(of: "ip_address=")?.upperBound else {
                continue
            }

            let hwPart = entry[hwIndex...].split(whereSeparator: \.isNewline).first ?? ""
            let ipPart = entry[ipIndex...].split(whereSeparator: \.isNewline).first ?? ""

            let rawHW = hwPart.components(separatedBy: ",").last ?? String(hwPart)
            let normalizedHW = normalizeMAC(rawHW.trimmingCharacters(in: .whitespacesAndNewlines))
            let ip = String(ipPart).trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedHW == targetMAC && !ip.isEmpty {
                return ip
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

            for line in output.components(separatedBy: .newlines) {
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 4 else { continue }
                let ipRaw = parts 1 .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                let macRaw = parts 3 
                if normalizeMAC(macRaw) == targetMAC {
                    return ipRaw
                }
            }
        } catch {
            return nil
        }
        return nil
    }

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