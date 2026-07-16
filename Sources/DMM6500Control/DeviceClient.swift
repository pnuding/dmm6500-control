// Raw-SCPI-over-TCP backend for the Keithley/Tektronix DMM6500, ported
// from the equivalent UDP3000S-control backend: connect to the LAN raw
// socket port (5025 on this instrument too), one synchronous reply per
// query, newline-terminated commands.
//
// This being an actor does NOT by itself serialize scpi() calls the way an
// explicit lock would: actors only guarantee exclusivity *between* await
// points, and scpi() suspends twice (once sending, once waiting for the
// reply). With two independent poll loops both calling in here, a second
// call's send+receive could interleave with the first's, and readLine()
// would then hand back whichever call's query happened to check the
// buffer first - not necessarily the one that actually asked. The explicit
// lock below closes that window.
//
// Unlike some other Keithley families, the DMM6500 sends no login/welcome
// banner on raw-socket connect and needs none drained before the first
// command (confirmed against Tektronix's own Python sockets driver).

import Foundation
import Network

/// NWConnection's stateUpdateHandler can fire from multiple states in
/// quick succession; this guards a continuation against being resumed
/// more than once, safely across whatever queue the handler runs on.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func markIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum DeviceError: LocalizedError {
    case notConnected
    case noReply
    case connectionClosed
    case decodeFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "not connected")
        case .noReply: return String(localized: "no reply")
        case .connectionClosed: return String(localized: "connection closed by device")
        case .decodeFailed: return String(localized: "could not decode reply")
        case .timeout: return String(localized: "timed out waiting for device")
        }
    }
}

struct DeviceIdentity { let manufacturer: String; let model: String; let serial: String; let firmware: String }

actor DeviceClient {
    private var connection: NWConnection?
    // No default - always set via setHost() before connect(); a connect
    // attempt against "" fails immediately rather than probing some
    // baked-in address.
    private var host: String = ""
    private let port: NWEndpoint.Port = 5025
    private var buffer = Data()

    // A minimal async mutex: acquireLock()/releaseLock() are only ever
    // called from within this actor's own isolated methods, and neither
    // does anything awaitable while touching lockBusy/lockWaiters, so
    // there's no reentrancy window inside the lock itself - only the
    // critical section it guards is allowed to suspend.
    private var lockBusy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireLock() async {
        if !lockBusy {
            lockBusy = true
            return
        }
        await withCheckedContinuation { cont in
            lockWaiters.append(cont)
        }
    }

    private func releaseLock() {
        if let next = lockWaiters.first {
            lockWaiters.removeFirst()
            next.resume()
        } else {
            lockBusy = false
        }
    }

    // NWConnection has no built-in operation timeout: if the device goes
    // dark mid-call with no more traffic to provoke a TCP-level failure, a
    // receive()/send() completion handler can simply never fire, leaving
    // the caller suspended forever - still holding the lock above - and
    // blocking every future call including a user-initiated reconnect.
    // This races the real completion against a GCD deadline for exactly
    // one winner (via ResumeGuard), and the loser is deterministically
    // cancelled rather than left to run unsupervised.
    private func withDeadline<T>(_ seconds: Double, _ start: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let resumeGuard = ResumeGuard()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            start { result in
                if resumeGuard.markIfFirst() { cont.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if resumeGuard.markIfFirst() { cont.resume(throwing: DeviceError.timeout) }
            }
        }
    }

    func setHost(_ h: String) {
        host = h
    }

    func connect() async throws {
        await acquireLock()
        defer { releaseLock() }
        try await connectLocked()
    }

    // scpi() already holds the lock when it auto-reconnects on a dropped
    // connection, so it calls this directly - going through connect()
    // there would deadlock trying to acquire a lock it's already holding.
    private func connectLocked() async throws {
        connection?.cancel()
        connection = nil
        buffer.removeAll()

        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let resumeGuard = ResumeGuard()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumeGuard.markIfFirst() { cont.resume() }
                    case .failed(let err):
                        if resumeGuard.markIfFirst() { cont.resume(throwing: err) }
                    case .cancelled:
                        if resumeGuard.markIfFirst() { cont.resume(throwing: DeviceError.connectionClosed) }
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
                // A dead/blackholed route can leave the socket neither
                // ready nor failed for a very long time. If our deadline
                // wins the race, explicitly cancel this attempt so a late
                // ".ready" can never sneak in afterwards and get assigned
                // below once we've already moved on.
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                    if resumeGuard.markIfFirst() {
                        conn.cancel()
                        cont.resume(throwing: DeviceError.timeout)
                    }
                }
            }
        } catch {
            conn.cancel()
            throw error
        }
        connection = conn
    }

    private func receiveChunk() async throws -> Data {
        guard let conn = connection else { throw DeviceError.notConnected }
        // Some replies (e.g. right after changing NPLC/averaging) can take
        // several seconds to arrive, so this is more generous than the
        // send-side deadline below.
        return try await withDeadline(10) { complete in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error = error {
                    complete(.failure(error))
                } else if let data = data, !data.isEmpty {
                    complete(.success(data))
                } else if isComplete {
                    complete(.failure(DeviceError.connectionClosed))
                } else {
                    complete(.success(Data()))
                }
            }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<idx]
                buffer.removeSubrange(...idx)
                guard let s = String(data: lineData, encoding: .utf8) else { throw DeviceError.decodeFailed }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let chunk = try await receiveChunk()
            buffer.append(chunk)
        }
    }

    /// Sends one SCPI line. Returns the reply for a query ("?" in cmd), or
    /// nil for a plain write command, which gets no reply from the device.
    @discardableResult
    func scpi(_ cmd: String) async throws -> String? {
        await acquireLock()
        defer { releaseLock() }

        do {
            if connection == nil { try await connectLocked() }
            guard let conn = connection else { throw DeviceError.notConnected }
            let isQuery = cmd.contains("?")
            let line = (cmd + "\n").data(using: .utf8)!

            try await withDeadline(3) { complete in
                conn.send(content: line, completion: .contentProcessed { error in
                    complete(error.map { .failure($0) } ?? .success(()))
                })
            }

            guard isQuery else { return nil }
            return try await readLine()
        } catch {
            // A dead socket (device unplugged, network drop, etc.) never
            // fixes itself: without this, every future call kept reusing
            // the same broken `connection` object forever instead of
            // retrying connectLocked() above, so the app could never
            // recover once the device went away.
            connection?.cancel()
            connection = nil
            buffer.removeAll()
            throw error
        }
    }

    // ---------- identity ----------

    /// "KEITHLEY INSTRUMENTS,MODEL DMM6500,<serial>,<firmware>"
    func identify() async throws -> DeviceIdentity {
        guard let line = try await scpi("*IDN?") else { throw DeviceError.noReply }
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // The manual's own example is "KEITHLEY INSTRUMENTS,MODEL DMM6500,
        // <serial>,<firmware>" - the second field literally contains the
        // word "MODEL" as part of its text, not just the bare model
        // number, so it's stripped here rather than left in the window title.
        var model = parts.count > 1 ? parts[1] : ""
        if model.uppercased().hasPrefix("MODEL ") {
            model = String(model.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return DeviceIdentity(
            manufacturer: parts.count > 0 ? parts[0] : "",
            model: model,
            serial: parts.count > 2 ? parts[2] : "",
            firmware: parts.count > 3 ? parts[3] : ""
        )
    }

    /// `*LANG?` defaults to SCPI on this instrument but can be left in TSP
    /// or an emulation mode by a previous user; switching it back requires
    /// a reboot, so this only reports the current value rather than trying
    /// to change it.
    func commandLanguage() async throws -> String {
        guard let s = try await scpi("*LANG?") else { throw DeviceError.noReply }
        return s.trimmingCharacters(in: .whitespaces).uppercased()
    }

    func reset() async throws {
        try await scpi("*RST")
    }

    /// Releases the front panel from remote lockout back to local control -
    /// a bare command, no arguments. NOT the common SCPI/Keithley-family
    /// convention `SYSTem:LOCal`, which a direct user report confirmed does
    /// NOT work on this instrument; `LOGOUT` is what the manual actually
    /// documents for it (per that same report, found by searching the
    /// manual text for "logout" - it isn't under a command reference
    /// section this app's own manual research happened to pull). Called
    /// on app quit so the instrument doesn't sit there after the LAN
    /// session ends still reporting an active remote connection.
    /// Community/manual-confirmed, not yet hardware-tested by this app.
    func logout() async throws {
        try await scpi("LOGOUT")
    }

    /// Resumes the instrument's own free-running continuous-measurement
    /// loop (the front panel's "CONT" state with the revolving-arrows
    /// annunciator). This app's own MEASure?/READ? polling implicitly
    /// leaves the instrument idle-between-triggers instead once it
    /// disconnects (shown as "IDLE" with a speech-bubble icon on the front
    /// panel) - hardware-confirmed by the user directly comparing the
    /// front panel's state before connecting (continuous) against after
    /// quitting (idle) without this. Send before `logout()`, matching the
    /// same disconnect sequence a direct user report used successfully.
    func restartContinuousTrigger() async throws {
        try await scpi("TRIGger:CONTinuous RESTart")
    }

    /// Pops the oldest unread entry from the error queue:
    /// `code,"message;...;timestamp"`, or `0,"No error;..."` when empty.
    func lastError() async throws -> (code: Int, message: String) {
        guard let line = try await scpi("SYSTem:ERRor?") else { throw DeviceError.noReply }
        guard let commaIdx = line.firstIndex(of: ",") else { return (0, line) }
        let code = Int(line[line.startIndex..<commaIdx].trimmingCharacters(in: .whitespaces)) ?? 0
        var message = String(line[line.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
        if message.hasPrefix("\"") { message.removeFirst() }
        return (code, message)
    }

    // ---------- measurement ----------

    /// Selects the active measurement function. `MEASure:<function>?`
    /// below does this implicitly too, but this is used on its own when
    /// switching functions from the UI without immediately needing a
    /// reading back.
    func setFunction(_ f: DMMFunction) async throws {
        try await scpi("SENSe:FUNCtion \"\(f.scpiNode)\"")
    }

    /// Whatever function is currently active on the instrument (e.g. left
    /// over from the front panel, or a previous session) - quoted in the
    /// reply per SCPI string-response convention, e.g. `"VOLT:DC"`.
    func getFunction() async throws -> String {
        guard let line = try await scpi("SENSe:FUNCtion?") else { throw DeviceError.noReply }
        return line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// `MEASure:<function>?` selects the function (equivalent to
    /// `SENSe:FUNCtion` + `READ?`) and returns one fresh reading. Overrange
    /// comes back as 9.9e37 from the instrument and is passed through
    /// as-is; callers decide how to display that.
    func measure(_ f: DMMFunction) async throws -> Double {
        guard let line = try await scpi("MEASure:\(f.scpiNode)?") else { throw DeviceError.noReply }
        guard let value = Double(line.trimmingCharacters(in: .whitespaces)) else { throw DeviceError.decodeFailed }
        return value
    }

    /// `READ?` against whatever function is currently active - cheaper
    /// than `measure(_:)` when the function hasn't changed since the last
    /// call, since it skips re-sending `SENSe:FUNCtion`.
    func read() async throws -> Double {
        guard let line = try await scpi("READ?") else { throw DeviceError.noReply }
        guard let value = Double(line.trimmingCharacters(in: .whitespaces)) else { throw DeviceError.decodeFailed }
        return value
    }

    // ---------- NPLC (integration time) ----------

    func getNPLC(_ f: DMMFunction) async throws -> Double {
        guard let line = try await scpi("SENSe:\(f.scpiNode):NPLCycles?") else { throw DeviceError.noReply }
        return Double(line.trimmingCharacters(in: .whitespaces)) ?? 1
    }

    /// Valid range is 0.0005 to 12 (50/400Hz line) or 15 (60Hz line) power
    /// line cycles; callers should clamp to the conservative 0.0005...12
    /// range so the same value works regardless of the instrument's line
    /// frequency setting.
    func setNPLC(_ f: DMMFunction, _ n: Double) async throws {
        try await scpi("SENSe:\(f.scpiNode):NPLCycles \(n)")
    }

    // ---------- detector bandwidth (AC functions' speed control) ----------

    // Confirmed against real hardware: AC Voltage/AC Current reject both
    // NPLCycles and APERture outright - this instrument controls AC
    // measurement speed via a detector bandwidth (low-frequency filter)
    // setting instead, which only accepts 3, 30, or 300 Hz.
    func getDetectorBandwidth(_ f: DMMFunction) async throws -> Double {
        guard let line = try await scpi("SENSe:\(f.scpiNode):DETector:BANDwidth?") else { throw DeviceError.noReply }
        return Double(line.trimmingCharacters(in: .whitespaces)) ?? 30
    }

    func setDetectorBandwidth(_ f: DMMFunction, _ hz: Double) async throws {
        try await scpi("SENSe:\(f.scpiNode):DETector:BANDwidth \(Int(hz))")
    }

    // ---------- aperture (Frequency/Period's speed control) ----------

    // Manual-confirmed (Section 4, p.4-68/4-69) and hardware-confirmed:
    // Frequency and Period reject NPLC entirely and use Aperture (an
    // integration time in seconds) instead - unlike AC Voltage/Current,
    // which reject Aperture too and use Detector Bandwidth. Valid range
    // 2ms-273ms, default 200ms.
    func getAperture(_ f: DMMFunction) async throws -> Double {
        guard let line = try await scpi("SENSe:\(f.scpiNode):APERture?") else { throw DeviceError.noReply }
        return Double(line.trimmingCharacters(in: .whitespaces)) ?? 0.2
    }

    func setAperture(_ f: DMMFunction, _ seconds: Double) async throws {
        try await scpi("SENSe:\(f.scpiNode):APERture \(seconds)")
    }

    // ---------- range ----------

    func getRange(_ f: DMMFunction) async throws -> (auto: Bool, value: Double) {
        guard let autoLine = try await scpi("SENSe:\(f.scpiNode):RANGe:AUTO?") else { throw DeviceError.noReply }
        guard let rangeLine = try await scpi("SENSe:\(f.scpiNode):RANGe?") else { throw DeviceError.noReply }
        // An exact "1" string match was too brittle - this instrument (or
        // its current :FORMat:ASCII setting) can echo a boolean query in
        // scientific notation like "1.000000e+00" rather than a bare "1",
        // which silently read as "auto off" and showed a stale fixed
        // range while the device was actually still auto-ranging. Treat
        // any nonzero numeric reply (or a literal "ON") as true.
        let autoRaw = autoLine.trimmingCharacters(in: .whitespaces).uppercased()
        let auto = (Double(autoRaw).map { $0 != 0 }) ?? (autoRaw == "ON")
        let value = Double(rangeLine.trimmingCharacters(in: .whitespaces)) ?? 0
        return (auto, value)
    }

    func setAutoRange(_ f: DMMFunction, _ on: Bool) async throws {
        try await scpi("SENSe:\(f.scpiNode):RANGe:AUTO \(on ? "ON" : "OFF")")
    }

    /// Setting an explicit range value automatically turns auto-range off
    /// on the device side; the instrument snaps to the smallest fixed
    /// range that still covers the requested value.
    func setRange(_ f: DMMFunction, _ value: Double) async throws {
        try await scpi("SENSe:\(f.scpiNode):RANGe \(value)")
    }

    /// "FRON" or "REAR" - which input terminals are physically selected.
    /// This is a hardware switch with no remote command to change it (per
    /// the manual), but it gates whether the 10A current range is usable:
    /// that range only exists on the rear AMPS jack.
    func getTerminals() async throws -> String {
        guard let line = try await scpi("ROUTe:TERMinals?") else { throw DeviceError.noReply }
        return line.trimmingCharacters(in: .whitespaces).uppercased()
    }

    // ---------- auto zero (read-only in this app - display only) ----------

    /// Per-function, not global - confirmed against the manual (no
    /// system-wide AZERo command exists). Uses the same lenient numeric
    /// parsing as getRange's auto flag, since a bare "1" vs "1.000000e+00"
    /// bug already bit us once here.
    func getAutoZero(_ f: DMMFunction) async throws -> Bool {
        guard let line = try await scpi("SENSe:\(f.scpiNode):AZERo?") else { throw DeviceError.noReply }
        let raw = line.trimmingCharacters(in: .whitespaces).uppercased()
        return (Double(raw).map { $0 != 0 }) ?? (raw == "ON")
    }

    // ---------- input impedance (DC Voltage only - read-only display) ----------

    /// `MOHM10` (fixed 10MΩ divider, the default) or `AUTO` (>10GΩ on the
    /// lower ranges). Per the manual, explicitly documented only for DC
    /// Voltage (and Digitize Voltage, not used here) - not sent to other
    /// functions since the manual doesn't confirm what they do with it.
    func getInputImpedanceAuto(_ f: DMMFunction) async throws -> Bool {
        guard let line = try await scpi("SENSe:\(f.scpiNode):INPutimpedance?") else { throw DeviceError.noReply }
        return line.trimmingCharacters(in: .whitespaces).uppercased() == "AUTO"
    }

    // ---------- diode/other functions' bias (test current) level ----------

    /// Generic across several functions per the manual, but this app only
    /// exposes it for Diode, where it's the forward-voltage-drop test
    /// current: 10µA/100µA/1mA/10mA (default 1mA).
    func getBiasLevel(_ f: DMMFunction) async throws -> Double {
        guard let line = try await scpi("SENSe:\(f.scpiNode):BIAS:LEVel?") else { throw DeviceError.noReply }
        return Double(line.trimmingCharacters(in: .whitespaces)) ?? 0.001
    }

    func setBiasLevel(_ f: DMMFunction, _ value: Double) async throws {
        try await scpi("SENSe:\(f.scpiNode):BIAS:LEVel \(value)")
    }

    // ---------- averaging filter ----------

    func getFilter(_ f: DMMFunction) async throws -> (enabled: Bool, type: FilterType, count: Int) {
        guard let stateLine = try await scpi("SENSe:\(f.scpiNode):AVERage:STATe?") else { throw DeviceError.noReply }
        guard let typeLine = try await scpi("SENSe:\(f.scpiNode):AVERage:TCONtrol?") else { throw DeviceError.noReply }
        guard let countLine = try await scpi("SENSe:\(f.scpiNode):AVERage:COUNt?") else { throw DeviceError.noReply }
        let enabled = stateLine.trimmingCharacters(in: .whitespaces) == "1"
        let type = FilterType(scpi: typeLine.trimmingCharacters(in: .whitespaces)) ?? .repeating
        let count = Int(countLine.trimmingCharacters(in: .whitespaces)) ?? 10
        return (enabled, type, count)
    }

    /// Any parameter left nil is not sent, so a caller can e.g. change just
    /// the count without re-sending the type/state.
    func setFilter(_ f: DMMFunction, enabled: Bool? = nil, type: FilterType? = nil, count: Int? = nil) async throws {
        if let type { try await scpi("SENSe:\(f.scpiNode):AVERage:TCONtrol \(type.scpiValue)") }
        if let count { try await scpi("SENSe:\(f.scpiNode):AVERage:COUNt \(count)") }
        // State last: flipping the filter on before its type/count are set
        // would otherwise briefly run with whatever the device's own
        // stale/default values were.
        if let enabled { try await scpi("SENSe:\(f.scpiNode):AVERage:STATe \(enabled ? "ON" : "OFF")") }
    }
}
