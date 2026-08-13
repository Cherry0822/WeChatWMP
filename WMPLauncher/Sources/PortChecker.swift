import Foundation

struct PortOccupant {
    let pid: Int32
    let name: String
}

struct PortConflict {
    let port: Int
    let occupants: [PortOccupant]
}

enum PortChecker {
    static func conflicts(ports: [Int]) -> [PortConflict] {
        ports.compactMap { port in
            let occupants = occupants(port: port)
            return occupants.isEmpty ? nil : PortConflict(port: port, occupants: occupants)
        }
    }

    static func occupants(port: Int) -> [PortOccupant] {
        let lsofPath = FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof")
            ? "/usr/sbin/lsof"
            : "/usr/bin/lsof"
        let output = EnvChecker.runCommand(
            lsofPath,
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        )
        var result: [PortOccupant] = []
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[1]) else { continue }
            result.append(PortOccupant(pid: pid, name: String(fields[0])))
        }
        return result
    }

    static func release(_ conflict: PortConflict) {
        for occupant in conflict.occupants {
            _ = EnvChecker.runCommand("/bin/kill", [String(occupant.pid)])
        }
        Thread.sleep(forTimeInterval: 0.5)
        for occupant in occupants(port: conflict.port) {
            _ = EnvChecker.runCommand("/bin/kill", ["-9", String(occupant.pid)])
        }
    }
}
