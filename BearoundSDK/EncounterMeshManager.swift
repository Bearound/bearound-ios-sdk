import CoreBluetooth
import CoreLocation
import Foundation
import os.log

/// Device-to-device encounter layer: the host both **transmits** (advertises a fixed
/// service UUID and serves its rotating identifier over one GATT characteristic) and
/// **receives** (recognises other hosts in the shared BLE scan and aggregates their
/// signal strength).
///
/// - RSSI comes from advertisements; the peer's identifier is read over GATT once per
///   rotation window, through a serial queue with per-peer cooldown and timeout.
/// - Discoveries arrive through ``BluetoothManager``'s existing central — no second
///   radio scan, no dedicated timers (identifier rotation is evaluated lazily on use).
/// - Aggregates keep four running integers per peer (no sample buffers); tracked peers
///   are capped and stale entries evicted.
final class EncounterMeshManager: NSObject {

    // MARK: - Constants

    /// Fixed service every Bearound host advertises for the mesh (encounter beacon).
    static let serviceUUID = CBUUID(string: "B3A20001-0000-4000-8000-BEA0BEA0BEA0")
    /// Read-only characteristic serving the host's current RPI (16 raw bytes) — the
    /// fallback identity path for iOS peers in background (their advertisement carries
    /// no name/service data there). Android never connects: it reads identities from
    /// the frames below.
    static let rpiCharacteristicUUID = CBUUID(string: "B3A20002-0000-4000-8000-BEA0BEA0BEA0")
    /// 16-bit service-data key Android peers use to carry their identifier on air.
    static let rpiDataUUID = CBUUID(string: "BEA1")

    /// 22-char base64url of the 16 identifier bytes — travels as the advertised local
    /// name so Android scanners read an iOS host's identity without connecting.
    static func encodeRpiName(_ hex: String) -> String? {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == 16 else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeRpiName(_ name: String) -> String? {
        guard name.count == 22 else { return nil }
        var b64 = name.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), data.count == 16 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// How often the rotating identifier is renewed.
    static let rpiRotationInterval: TimeInterval = 15 * 60

    /// Reserved iBeacon major announced by SDK hosts while in foreground. Both receive
    /// paths (CoreBluetooth parser and CoreLocation ranging) filter the whole reserved
    /// BAND (``virtualBeaconMajorFloor``...0xFFFF) out so a host — or an air-corrupted
    /// copy of its frame — is never mistaken for a physical beacon; region monitoring
    /// still fires on the shared UUID, which is the point.
    static let virtualBeaconMajor: UInt16 = 0xFFFF

    /// Majors at or above this are reserved for virtual-beacon frames — physical
    /// Bearound beacons never use them. Field observation: a damaged 0xFFFF byte
    /// arrived as 0xFF32; band filtering drops those too.
    static let virtualBeaconMajorFloor: UInt16 = 0xFF00

    /// While in foreground the transmitter interleaves two advertisement payloads —
    /// iBeacon (region monitoring visibility) and the encounter service UUID (RSSI +
    /// identity for scanners) — switching every few seconds, like the physical beacons
    /// interleave their own frames. Background always advertises the service UUID only
    /// (iBeacon emission is a foreground-only platform capability).
    private static let advertiseInterleaveInterval: TimeInterval = 6

    private static let maxTrackedPeers = 64
    private static let peerStaleEviction: TimeInterval = 10 * 60
    private static let gattCooldownPerPeer: TimeInterval = 60
    private static let gattReadTimeout: TimeInterval = 8

    private let log = OSLog(subsystem: "io.bearound.sdk", category: "encounterMesh")

    // MARK: - Rotating identifier

    /// Persisted rotation state so an app relaunch inside the same window keeps the
    /// same identifier.
    struct RpiStore {
        private let defaults: UserDefaults
        private let currentKey = "io.bearound.sdk.mesh.rpi.current"
        private let previousKey = "io.bearound.sdk.mesh.rpi.previous"
        private let rotatedAtKey = "io.bearound.sdk.mesh.rpi.rotatedAt"
        private let rotationInterval: TimeInterval

        init(defaults: UserDefaults = .standard,
             rotationInterval: TimeInterval = EncounterMeshManager.rpiRotationInterval) {
            self.defaults = defaults
            self.rotationInterval = rotationInterval
        }

        /// Current identifier as 32 lowercase hex chars, rotating lazily on read.
        mutating func current(now: Date = Date()) -> String {
            let rotatedAt = defaults.double(forKey: rotatedAtKey)
            if let existing = defaults.string(forKey: currentKey),
               rotatedAt > 0, now.timeIntervalSince1970 - rotatedAt < rotationInterval {
                return existing
            }
            let fresh = Self.randomRpi()
            if let old = defaults.string(forKey: currentKey) {
                defaults.set(old, forKey: previousKey)
            }
            defaults.set(fresh, forKey: currentKey)
            defaults.set(now.timeIntervalSince1970, forKey: rotatedAtKey)
            return fresh
        }

        /// The identifier from the previous window, if any — reported beside the
        /// current one so observations spanning a rotation edge still resolve.
        func previous() -> String? { defaults.string(forKey: previousKey) }

        static func randomRpi() -> String {
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    // MARK: - Peer aggregation (O(1) per advertisement, no sample arrays)

    struct PeerAggregate {
        var rpi: String?
        var lastRssi = 0
        var sampleCount = 0
        var rssiMin = 0
        var rssiMax = Int.min
        var rssiSum = 0
        var firstSeen = Date()
        var lastSeen = Date()
        var lastGattAttempt = Date.distantPast
        var rpiReadAt = Date.distantPast

        mutating func addSample(rssi: Int, now: Date) {
            if sampleCount == 0 { firstSeen = now; rssiMin = rssi; rssiMax = rssi }
            lastRssi = rssi
            sampleCount += 1
            rssiMin = min(rssiMin, rssi)
            rssiMax = max(rssiMax, rssi)
            rssiSum += rssi
            lastSeen = now
        }

        var rssiAvg: Int {
            sampleCount == 0 ? 0 : Int((Double(rssiSum) / Double(sampleCount)).rounded())
        }
    }

    // MARK: - State (all mutated on `queue`)

    private let queue: DispatchQueue
    private var rpiStore = RpiStore()
    private var peers: [UUID: PeerAggregate] = [:]
    private var peripheralManager: CBPeripheralManager?
    private var isStarted = false
    private var isInForeground = true
    private var interleaveTimer: DispatchSourceTimer?
    private var advertisingIBeaconPhase = false

    /// GATT identity reads: strictly one in flight, retained here so CoreBluetooth
    /// keeps the CBPeripheral alive for the duration.
    private var gattInFlight: CBPeripheral?
    private var gattTimeoutWork: DispatchWorkItem?

    /// Connect/cancel are owned by ``BluetoothManager``'s central — injected so the mesh
    /// never creates a second CBCentralManager.
    var connectPeripheral: ((CBPeripheral) -> Void)?
    var cancelConnection: ((CBPeripheral) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            os_log("[Mesh] starting encounter mesh (TX + RX)", log: self.log, type: .info)
            // Creating the manager triggers didUpdateState, which begins advertising.
            self.peripheralManager = CBPeripheralManager(
                delegate: self, queue: self.queue,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.isStarted = false
            self.stopInterleaveTimer()
            if let inFlight = self.gattInFlight { self.cancelConnection?(inFlight) }
            self.gattInFlight = nil
            self.gattTimeoutWork?.cancel()
            self.peripheralManager?.stopAdvertising()
            self.peripheralManager?.removeAllServices()
            self.peripheralManager = nil
            self.peers.removeAll()
            os_log("[Mesh] stopped", log: self.log, type: .info)
        }
    }

    /// Tracks app state: foreground interleaves iBeacon + service UUID; background
    /// advertises the service UUID only.
    func setForeground(_ foreground: Bool) {
        queue.async { [weak self] in
            guard let self, self.isInForeground != foreground else { return }
            self.isInForeground = foreground
            self.refreshAdvertising()
        }
    }

    /// The host's identifiers for the payload (`[current, previous]`).
    ///
    /// - Important: Never call from `queue` (the shared bleQueue) — it hops there
    ///   synchronously, same as ``snapshotEncounters()``.
    func currentEncounterIds() -> [String] {
        queue.sync {
            var ids = [rpiStore.current()]
            if let previous = rpiStore.previous() { ids.append(previous) }
            return ids
        }
    }

    /// Whether any identified peer has been seen after `since` — the cheap check the
    /// sync path uses to decide if an encounters-only upload is worth making when no
    /// physical beacon is pending.
    ///
    /// - Important: Never call from `queue` (the shared bleQueue) — deadlock.
    func hasFreshEncounters(since: Date) -> Bool {
        queue.sync {
            peers.values.contains { $0.rpi != nil && $0.lastSeen > since }
        }
    }

    /// Non-destructive snapshot of every identified peer, for the sync payload.
    /// Peers whose identifier has not been read yet are withheld — they join a later
    /// sync once the GATT read lands.
    ///
    /// - Important: Never call from `queue` (the shared bleQueue) — deadlock.
    func snapshotEncounters() -> [EncounterObservation] {
        queue.sync {
            peers.values.compactMap { peer in
                guard let rpi = peer.rpi, peer.sampleCount > 0 else { return nil }
                return EncounterObservation(
                    rpi: rpi,
                    rssi: peer.lastRssi,
                    sampleCount: peer.sampleCount,
                    rssiMin: peer.rssiMin,
                    rssiMax: peer.rssiMax,
                    rssiAvg: peer.rssiAvg,
                    firstSeen: Int(peer.firstSeen.timeIntervalSince1970 * 1000),
                    lastSeen: Int(peer.lastSeen.timeIntervalSince1970 * 1000)
                )
            }
        }
    }

    // MARK: - RX (fed by BluetoothManager's existing scan)

    /// Called on `queue` for every non-beacon discovery. Cheap guard: only frames that
    /// advertise our service (foreground), came through the filtered background scan,
    /// or belong to an already-tracked peer are processed.
    func handleDiscovery(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int,
        cameThroughFilteredScan: Bool
    ) {
        guard isStarted, rssi < 0 else { return }

        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData["kCBAdvDataHashedServiceUUIDs"] as? [CBUUID] ?? []
        let isKnown = peers[peripheral.identifier] != nil
        guard isKnown
            || advertised.contains(Self.serviceUUID)
            || overflow.contains(Self.serviceUUID)
            || cameThroughFilteredScan else { return }

        let now = Date()
        var peer = peers[peripheral.identifier] ?? PeerAggregate()
        if peers[peripheral.identifier] == nil {
            guard peers.count < Self.maxTrackedPeers else {
                evictStalePeers(now: now)
                guard peers.count < Self.maxTrackedPeers else { return }
                peers[peripheral.identifier] = peer
                return
            }
        }
        peer.addSample(rssi: rssi, now: now)

        // Identity from the frame itself — Android peers put it in service data,
        // iOS foreground peers in the advertised name. Zero connections.
        var frameRpi: String?
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let data = serviceData[Self.rpiDataUUID], data.count == 16 {
            frameRpi = data.map { String(format: "%02x", $0) }.joined()
        } else if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            frameRpi = Self.decodeRpiName(name)
        }
        if let frameRpi {
            if let old = peer.rpi, old != frameRpi {
                // Rotated identity = new logical presence: restart the aggregate.
                peer = PeerAggregate()
                peer.addSample(rssi: rssi, now: now)
            }
            peer.rpi = frameRpi
            peer.rpiReadAt = now
            peers[peripheral.identifier] = peer
            return
        }

        // GATT fallback (iOS peers in background — nothing identifying in their frames):
        // once per peer, re-read every rotation window, one connection at a time.
        let rpiIsFresh = now.timeIntervalSince(peer.rpiReadAt) < Self.rpiRotationInterval
        if !(peer.rpi != nil && rpiIsFresh),
           gattInFlight == nil,
           now.timeIntervalSince(peer.lastGattAttempt) > Self.gattCooldownPerPeer {
            peer.lastGattAttempt = now
            gattInFlight = peripheral
            peripheral.delegate = self
            os_log("[Mesh] reading identity of peer %{public}@", log: log, type: .info,
                   peripheral.identifier.uuidString)
            connectPeripheral?(peripheral)
            armGattTimeout(for: peripheral)
        }
        peers[peripheral.identifier] = peer
    }

    /// Routed from BluetoothManager when a mesh-owned connection succeeds/fails/drops.
    func ownsPeripheral(_ peripheral: CBPeripheral) -> Bool {
        gattInFlight?.identifier == peripheral.identifier
    }

    func handleConnected(_ peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func handleConnectionEnded(_ peripheral: CBPeripheral) {
        guard ownsPeripheral(peripheral) else { return }
        clearInFlight()
    }

    private func armGattTimeout(for peripheral: CBPeripheral) {
        gattTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral, self.ownsPeripheral(peripheral) else { return }
            os_log("[Mesh] identity read timed out for %{public}@", log: self.log, type: .error,
                   peripheral.identifier.uuidString)
            self.cancelConnection?(peripheral)
            self.clearInFlight()
        }
        gattTimeoutWork = work
        queue.asyncAfter(deadline: .now() + Self.gattReadTimeout, execute: work)
    }

    private func clearInFlight() {
        gattInFlight = nil
        gattTimeoutWork?.cancel()
        gattTimeoutWork = nil
    }

    private func evictStalePeers(now: Date) {
        peers = peers.filter { now.timeIntervalSince($0.value.lastSeen) < Self.peerStaleEviction }
    }
}

// MARK: - TX (peripheral role)

extension EncounterMeshManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn, isStarted else { return }
        // Dynamic characteristic (value nil): reads reach didReceiveRead, so rotation
        // never requires re-registering the service.
        let characteristic = CBMutableCharacteristic(
            type: Self.rpiCharacteristicUUID, properties: [.read], value: nil, permissions: [.readable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheral.removeAllServices()
        peripheral.add(service)
        refreshAdvertising()
    }

    /// Applies the advertising payload for the current app state. Foreground runs the
    /// interleave timer (iBeacon ↔ service UUID); background pins the service UUID.
    /// The timer exists only while started + powered on + foreground — zero cost
    /// otherwise.
    private func refreshAdvertising() {
        guard isStarted, let manager = peripheralManager, manager.state == .poweredOn else { return }
        stopInterleaveTimer()
        if isInForeground {
            advertisingIBeaconPhase = false
            advanceInterleave()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.advertiseInterleaveInterval,
                           repeating: Self.advertiseInterleaveInterval)
            timer.setEventHandler { [weak self] in self?.advanceInterleave() }
            timer.resume()
            interleaveTimer = timer
        } else {
            manager.stopAdvertising()
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
            os_log("[Mesh] advertising service UUID (background)", log: log, type: .info)
        }
    }

    private func stopInterleaveTimer() {
        interleaveTimer?.cancel()
        interleaveTimer = nil
    }

    private func advanceInterleave() {
        guard isStarted, let manager = peripheralManager, manager.state == .poweredOn else { return }
        advertisingIBeaconPhase.toggle()
        manager.stopAdvertising()
        if advertisingIBeaconPhase {
            // iBeacon phase: same UUID the SDK's region monitoring watches, reserved
            // major, minor derived from the rotating identifier (nothing stable).
            let minor = UInt16(rpiStore.current().prefix(4), radix: 16) ?? 0
            let region = CLBeaconRegion(
                uuid: BeaconConstants.uuid,
                major: Self.virtualBeaconMajor,
                minor: minor,
                identifier: "io.bearound.sdk.mesh.virtualbeacon"
            )
            let payload = region.peripheralData(withMeasuredPower: nil) as? [String: Any] ?? [:]
            manager.startAdvertising(payload)
        } else {
            var payload: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]]
            // Identity as local name (foreground only — iOS drops it in background):
            // lets Android scanners read who we are without connecting.
            if let name = Self.encodeRpiName(rpiStore.current()) {
                payload[CBAdvertisementDataLocalNameKey] = name
            }
            manager.startAdvertising(payload)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.rpiCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        // Answer the *current* identifier as 16 raw bytes (rotation is lazy-on-read).
        let hex = rpiStore.current()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        let data = Data(bytes)
        guard request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }
}

// MARK: - GATT identity read (central side callbacks)

extension EncounterMeshManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            cancelConnection?(peripheral)
            clearInFlight()
            return
        }
        peripheral.discoverCharacteristics([Self.rpiCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let characteristic = service.characteristics?
                  .first(where: { $0.uuid == Self.rpiCharacteristicUUID }) else {
            cancelConnection?(peripheral)
            clearInFlight()
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer {
            cancelConnection?(peripheral)
            clearInFlight()
        }
        guard error == nil, let data = characteristic.value, data.count == 16 else { return }
        let rpi = data.map { String(format: "%02x", $0) }.joined()
        let now = Date()
        var peer = peers[peripheral.identifier] ?? PeerAggregate()
        if let old = peer.rpi, old != rpi {
            // Rotated identity = new logical presence: restart the aggregate so old
            // samples never attach to the new identifier.
            peer = PeerAggregate()
        }
        peer.rpi = rpi
        peer.rpiReadAt = now
        peers[peripheral.identifier] = peer
        os_log("[Mesh] peer identity read: %{public}@…", log: log, type: .info,
               String(rpi.prefix(8)))
    }
}
