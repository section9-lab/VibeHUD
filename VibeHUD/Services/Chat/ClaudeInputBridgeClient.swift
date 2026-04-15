//
//  ClaudeInputBridgeClient.swift
//  VibeHUD
//
//  Sends interactive answers to a user-space Claude bridge over a Unix socket.
//

import Foundation

actor ClaudeInputBridgeClient {
    static let shared = ClaudeInputBridgeClient()

    func sendMessage(
        _ message: String,
        toSocketPath socketPath: String,
        submit: Bool = true,
        submitSequence: String? = nil,
        allowEmpty: Bool = false
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.sendSync(
                    message,
                    toSocketPath: socketPath,
                    submit: submit,
                    submitSequence: submitSequence,
                    allowEmpty: allowEmpty
                ))
            }
        }
    }

    private static func sendSync(
        _ message: String,
        toSocketPath socketPath: String,
        submit: Bool,
        submitSequence: String?,
        allowEmpty: Bool
    ) -> Bool {
        let socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFd >= 0 else { return false }
        defer { close(socketFd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socketFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else { return false }

        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuffer = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuffer, ptr, maxLen - 1)
                pathBuffer[maxLen - 1] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(socketFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return false }

        var payload: [String: Any] = ["text": message, "submit": submit]
        if let submitSequence, !submitSequence.isEmpty {
            payload["submit_sequence"] = submitSequence
        }
        if allowEmpty {
            payload["allow_empty"] = true
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }

        let writeSucceeded = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(socketFd, baseAddress, data.count) == data.count
        }
        guard writeSucceeded else { return false }

        var ack = [UInt8](repeating: 0, count: 16)
        let bytesRead = read(socketFd, &ack, ack.count)
        guard bytesRead > 0 else { return false }

        let response = String(bytes: ack.prefix(bytesRead), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return response == "ok"
    }
}
