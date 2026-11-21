import LocalAuthentication

/// The phone's own lock (Face ID / Touch ID, falling back to the passcode).
enum DeviceAuth {
    static func check(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return await withCheckedContinuation { c in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in c.resume(returning: ok) }
        }
    }
}
