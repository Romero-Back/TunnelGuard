import Dispatch
import Foundation
import Network

enum Transport: String {
    case tcp, udp
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

func checkUDPEcho(on connection: NWConnection) {
    let payload = Data(UUID().uuidString.utf8)
    connection.send(content: payload, completion: .contentProcessed { error in
        if let error {
            fail("UDP send failed: \(error)")
        }
        connection.receiveMessage { response, _, _, error in
            if let error {
                fail("UDP receive failed: \(error)")
            }
            guard response == payload else {
                fail("UDP reply did not match the probe payload")
            }
            print("UDP echo received")
            exit(0)
        }
    })
}

let arguments = CommandLine.arguments
guard arguments.count == 4 || arguments.count == 5,
      let transport = Transport(rawValue: arguments[1]),
      !arguments[2].isEmpty,
      let portNumber = UInt16(arguments[3]), portNumber > 0,
      let port = NWEndpoint.Port(rawValue: portNumber) else {
    fail("Usage: tunnelguard-network-probe <tcp|udp> <host> <port> [timeout-seconds]", status: 64)
}

let timeout = arguments.count == 5 ? Int(arguments[4]) : 5
guard let timeout, (1...60).contains(timeout) else {
    fail("Timeout must be a whole number from 1 to 60 seconds", status: 64)
}

let queue = DispatchQueue(label: "app.tunnelguard.lab.networkprobe")
let connection = NWConnection(host: NWEndpoint.Host(arguments[2]), port: port,
                              using: transport == .tcp ? .tcp : .udp)

connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        if transport == .tcp {
            print("TCP connection established")
            exit(0)
        }
        checkUDPEcho(on: connection)
    case .waiting(let error):
        // Network.framework may retry a waiting connection until the deadline.
        FileHandle.standardError.write(Data("Waiting for connection: \(error)\n".utf8))
    case .failed(let error):
        fail("Connection failed: \(error)")
    case .cancelled:
        fail("Connection cancelled")
    default:
        break
    }
}

queue.asyncAfter(deadline: .now() + .seconds(timeout)) {
    fail("Probe timed out after \(timeout) s")
}
connection.start(queue: queue)
dispatchMain()
