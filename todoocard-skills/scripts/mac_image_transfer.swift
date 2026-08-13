import CoreBluetooth
import Foundation

private func log(_ message: String) {
    print(message)
    fflush(stdout)
}

private struct TodooAdvertisement {
    let manufacturerID: UInt16
    let screenType: UInt16
    let capabilityFlags: UInt8
    let firmwareVersion: UInt8

    var requiresEncryptedGatt: Bool {
        screenType == 0x134C && firmwareVersion >= 0x8C && (capabilityFlags & 0x01) != 0
    }

    var pairingWindowOpen: Bool {
        requiresEncryptedGatt && (capabilityFlags & 0x02) != 0
    }

    var otaRecoveryMode: Bool {
        (capabilityFlags & 0x08) != 0
    }
}

private func parseTodooAdvertisement(_ data: Data?) -> TodooAdvertisement? {
    guard let data, data.count >= 7 else { return nil }
    return TodooAdvertisement(
        manufacturerID: UInt16(data[0]) | UInt16(data[1]) << 8,
        screenType: UInt16(data[2]) | UInt16(data[6]) << 8,
        capabilityFlags: data[3],
        firmwareVersion: data[4]
    )
}

private func advertisementDescription(_ info: TodooAdvertisement?) -> String {
    guard let info else { return "manufacturer=unknown" }
    guard info.manufacturerID == 0x5053 else {
        return String(format: "manufacturer=0x%04X", info.manufacturerID)
    }
    return String(
        format: "manufacturer=0x%04X screen=0x%04X firmware=0x%02X flags=0x%02X secure=%@ pairing=%@ recovery=%@",
        info.manufacturerID,
        info.screenType,
        info.firmwareVersion,
        info.capabilityFlags,
        info.requiresEncryptedGatt ? "yes" : "no",
        info.pairingWindowOpen ? "open" : "closed",
        info.otaRecoveryMode ? "yes" : "no"
    )
}

private enum Command: UInt8 {
    case requestBlockSize = 1
    case requestScreenSize = 2
    case requestStartTransfer = 3
    case dataAck = 5
}

private enum Status: UInt8 {
    case success = 0
    case transferEnd = 8
}

private enum Profile {
    case standard
    case compressed
}

private let serviceUUIDs = [
    CBUUID(string: "0000FEF0-0000-1000-8000-00805F9B34FB"),
    CBUUID(string: "0000FDF0-0000-1000-8000-00805F9B34FB")
]
private let controlCharacteristicUUIDs = [
    CBUUID(string: "0000FEF1-0000-1000-8000-00805F9B34FB"),
    CBUUID(string: "0000FDF1-0000-1000-8000-00805F9B34FB")
]
private let dataCharacteristicUUIDs = [
    CBUUID(string: "0000FEF2-0000-1000-8000-00805F9B34FB"),
    CBUUID(string: "0000FDF2-0000-1000-8000-00805F9B34FB")
]
private let batteryServiceUUID = CBUUID(string: "180F")
private let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

private final class MacImageTransfer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private lazy var central = CBCentralManager(delegate: self, queue: queue)
    private let queue = DispatchQueue(label: "com.todoocard.mac-image-transfer")
    private let payloadURL: URL
    private let profile: Profile
    private let targetID: UUID?
    private let listOnly: Bool
    private let probeOnly: Bool
    private let pairOnly: Bool
    private let allowDeviceButton: Bool
    private var seenIDs = Set<UUID>()
    private var payload = Data()
    private var peripheral: CBPeripheral?
    private var advertisedInfo: TodooAdvertisement?
    private var imageService: CBService?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var secureLinkVerified = false
    private var pairingSucceeded = false
    private var pairingWindowHintShown = false
    private var connectionAttempt = 0
    private var serviceDiscoveryCompleted = false
    private var notificationSettled = false
    private var notificationSettleScheduled = false
    private var transferStarted = false
    private var blockPayloadSize = 0
    private var nextCompressedBlockIndex: Int?
    private var lastProgress = -1
    private var finalAckTimer: DispatchSourceTimer?
    private var controlResponseTimer: DispatchSourceTimer?
    private var controlFallbackTimer: DispatchSourceTimer?
    private var lastControlCommand: UInt8?
    private var retriedControlWithoutResponse = false

    init(payloadURL: URL, profile: Profile, targetID: UUID?, listOnly: Bool, probeOnly: Bool, pairOnly: Bool, allowDeviceButton: Bool) {
        self.payloadURL = payloadURL
        self.profile = profile
        self.targetID = targetID
        self.listOnly = listOnly
        self.probeOnly = probeOnly
        self.pairOnly = pairOnly
        self.allowDeviceButton = allowDeviceButton
        super.init()
    }

    func run() {
        if !listOnly, !probeOnly, !pairOnly {
            do {
                payload = try Data(contentsOf: payloadURL)
            } catch {
                log("Failed to read payload: \(error)")
                Foundation.exit(2)
            }
            log("Payload: \(payloadURL.path)")
            log("Size: \(payload.count) bytes")
            log("Profile: \(profile == .compressed ? "compressed T3" : "standard")")
        }
        _ = central
        dispatchMain()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            log("Bluetooth state: \(central.state.rawValue)")
            return
        }
        if listOnly {
            log("Scanning nearby BLE devices for 30s ...")
            queue.asyncAfter(deadline: .now() + .seconds(30)) { Foundation.exit(0) }
        } else if pairOnly {
            log("Waiting for the physical pairing window on the exact target UUID ...")
            log("Hold the device's rear button for 10 seconds, until the front light fast-flashes.")
        } else if probeOnly {
            log("Scanning for probe target ...")
        } else {
            log("Scanning for image-transfer device ...")
        }
        if !listOnly {
            let scanTimeout = pairOnly ? 75 : 45
            queue.asyncAfter(deadline: .now() + .seconds(scanTimeout)) { [weak self] in
                guard let self, self.peripheral == nil else { return }
                if self.pairOnly {
                    log("Timed out waiting for the 60-second physical pairing window")
                } else {
                    log("Timed out scanning for target")
                }
                Foundation.exit(14)
            }
        }
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""
        let advertisement = parseTodooAdvertisement(
            advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        )
        if listOnly {
            guard !seenIDs.contains(peripheral.identifier) else { return }
            seenIDs.insert(peripheral.identifier)
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .map(\.uuidString)
                .joined(separator: ",") ?? ""
            log("BLE \(name.isEmpty ? "(no name)" : name) id=\(peripheral.identifier) RSSI=\(RSSI) services=\(services) \(advertisementDescription(advertisement))")
            return
        }

        if let targetID, peripheral.identifier != targetID { return }

        guard let advertisement else {
            log("TodooCard manufacturer data is missing")
            Foundation.exit(20)
        }
        guard advertisement.manufacturerID == 0x5053,
              advertisement.screenType == 0x134C else {
            log("TodooCard identity mismatch: \(advertisementDescription(advertisement))")
            Foundation.exit(20)
        }
        if pairOnly {
            guard advertisement.requiresEncryptedGatt else {
                log("Target firmware does not use the latest secure pairing protocol")
                Foundation.exit(21)
            }
            guard advertisement.pairingWindowOpen else {
                if !pairingWindowHintShown {
                    pairingWindowHintShown = true
                    log("Target found, but pairing=closed; keep holding the rear button until the light fast-flashes.")
                }
                return
            }
            log("Physical pairing window detected; starting encrypted system pairing.")
        } else if advertisement.pairingWindowOpen {
            log("Refusing probe/transfer while the new-device pairing window is open; use --pair for a new Mac or wait for the window to close.")
            Foundation.exit(26)
        }

        advertisedInfo = advertisement
        log("Advertisement verified: \(advertisementDescription(advertisement))")
        log("Found \(name.isEmpty ? peripheral.identifier.uuidString : name) id=\(peripheral.identifier) RSSI=\(RSSI)")
        self.peripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        connect(peripheral)
    }

    private func connect(_ peripheral: CBPeripheral) {
        connectionAttempt += 1
        let attempt = connectionAttempt
        log("Connecting (attempt \(attempt)/3) ...")
        central.connect(peripheral, options: nil)
        queue.asyncAfter(deadline: .now() + .seconds(15)) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.peripheral === peripheral,
                  self.connectionAttempt == attempt,
                  peripheral.state != .connected else { return }
            log("Timed out connecting")
            Foundation.exit(15)
        }
    }

    private func retryEncryptionTimeout(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        let systemError = error as NSError?
        guard advertisedInfo?.requiresEncryptedGatt == true,
              !secureLinkVerified,
              systemError?.domain == "CBErrorDomain",
              systemError?.code == 15,
              connectionAttempt < 3 else { return false }

        let delay = connectionAttempt == 1 ? 0.75 : 1.5
        imageService = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        batteryCharacteristic = nil
        log("Encryption timed out; retrying the same explicit connection in \(delay)s.")
        queue.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
            guard let self, let peripheral,
                  self.peripheral === peripheral,
                  peripheral.state == .disconnected else { return }
            self.connect(peripheral)
        }
        return true
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected")
        serviceDiscoveryCompleted = false
        notificationSettled = false
        notificationSettleScheduled = false
        peripheral.discoverServices(nil)
        for delay in [3, 8] {
            queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      peripheral.state == .connected,
                      !self.serviceDiscoveryCompleted else { return }
                log("Service discovery has not completed; retrying")
                peripheral.discoverServices(nil)
            }
        }
        if pairOnly {
            queue.asyncAfter(deadline: .now() + .seconds(30)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      !self.pairingSucceeded else { return }
                log("Timed out completing encrypted system pairing")
                self.central.cancelPeripheralConnection(peripheral)
                Foundation.exit(27)
            }
        } else {
            queue.asyncAfter(deadline: .now() + .seconds(35)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      !self.transferStarted else { return }
                log("Timed out preparing the verified TodooCard GATT connection")
                self.central.cancelPeripheralConnection(peripheral)
                Foundation.exit(19)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if retryEncryptionTimeout(peripheral, error: error) { return }
        log("Connect failed: \(error?.localizedDescription ?? "unknown")")
        Foundation.exit(3)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        if retryEncryptionTimeout(peripheral, error: error) { return }
        if pairOnly, !pairingSucceeded {
            log("Pairing did not complete; reopen the physical pairing window and try again.")
            Foundation.exit(27)
        }
        if advertisedInfo?.requiresEncryptedGatt == true, !secureLinkVerified {
            log("The secure bond is unavailable. Run --pair during a new physical pairing window, then probe again.")
            Foundation.exit(18)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Discover services failed: \(error)")
            Foundation.exit(4)
        }
        serviceDiscoveryCompleted = true
        guard let services = peripheral.services, !services.isEmpty else {
            log("Image-transfer service not found")
            Foundation.exit(5)
        }
        log("Services ready: \(services.map(\.uuid.uuidString).joined(separator: ","))")
        imageService = services.first { serviceUUIDs.contains($0.uuid) }

        if advertisedInfo?.requiresEncryptedGatt == true, !secureLinkVerified {
            guard let batteryService = services.first(where: { $0.uuid == batteryServiceUUID }) else {
                log("Encrypted Battery Service is missing; cannot verify the secure bond")
                Foundation.exit(18)
            }
            peripheral.discoverCharacteristics(
                [batteryLevelCharacteristicUUID],
                for: batteryService
            )
            return
        }

        guard let imageService else {
            log("Image-transfer service not found after secure pairing")
            Foundation.exit(5)
        }
        peripheral.discoverCharacteristics(
            controlCharacteristicUUIDs + dataCharacteristicUUIDs,
            for: imageService
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("Discover characteristics failed for \(service.uuid.uuidString): \(error)")
            Foundation.exit(6)
        }
        service.characteristics?.forEach { characteristic in
            if probeOnly || pairOnly {
                log("Characteristic service=\(service.uuid.uuidString) uuid=\(characteristic.uuid.uuidString) props=\(Self.propertiesDescription(characteristic.properties))")
            }
            if controlCharacteristicUUIDs.contains(characteristic.uuid) {
                controlCharacteristic = characteristic
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if dataCharacteristicUUIDs.contains(characteristic.uuid) {
                dataCharacteristic = characteristic
            } else if characteristic.uuid == batteryLevelCharacteristicUUID {
                batteryCharacteristic = characteristic
            }
        }

        if service.uuid == batteryServiceUUID {
            guard let batteryCharacteristic else {
                log("Encrypted Battery Level characteristic is missing")
                Foundation.exit(18)
            }
            log(pairOnly
                ? "Requesting encrypted Battery Level to create and verify the system bond ..."
                : "Verifying the existing encrypted system bond ...")
            peripheral.readValue(for: batteryCharacteristic)
            return
        }

        if probeOnly,
           controlCharacteristic != nil,
           dataCharacteristic != nil,
           (advertisedInfo?.requiresEncryptedGatt != true || secureLinkVerified) {
            transferStarted = true
            log("Probe completed: exact UUID, manufacturer=0x5053, screen=0x134C, and secure FEF1/FEF2 access verified")
            Foundation.exit(0)
        }
        beginIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Enable notify failed: \(error)")
            Foundation.exit(7)
        }
        guard !notificationSettleScheduled else { return }
        notificationSettleScheduled = true
        log("Control notification enabled; settling for 400ms")
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            guard let self else { return }
            self.notificationSettled = true
            self.beginIfReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == batteryLevelCharacteristicUUID {
            if let error {
                log("Encrypted pairing verification failed: \(error)")
                Foundation.exit(pairOnly ? 27 : 18)
            }
            guard let data = characteristic.value, data.count == 1 else {
                log("Encrypted Battery Level returned an invalid value")
                Foundation.exit(pairOnly ? 27 : 18)
            }
            secureLinkVerified = true
            log("Encrypted link verified; battery=\(data[0])%")
            if pairOnly {
                pairingSucceeded = true
                log("Pairing completed. The macOS system bond is ready for a separate --probe.")
                Foundation.exit(0)
            }
            log("Encrypted link ready; allowing 1.8s for Service Changed cache refresh")
            imageService = nil
            controlCharacteristic = nil
            dataCharacteristic = nil
            notificationSettled = false
            notificationSettleScheduled = false
            serviceDiscoveryCompleted = false
            queue.asyncAfter(deadline: .now() + .milliseconds(1800)) { [weak self, weak peripheral] in
                guard let self, let peripheral,
                      self.peripheral === peripheral,
                      peripheral.state == .connected else { return }
                log("Rediscovering transfer services after secure cache refresh")
                peripheral.discoverServices(nil)
            }
            return
        }
        if let error {
            log("Notification failed: \(error)")
            Foundation.exit(8)
        }
        guard let data = characteristic.value else { return }
        handleControlMessage(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Write failed for \(characteristic.uuid.uuidString): \(error)")
            Foundation.exit(17)
        }
        log("Write ok for \(characteristic.uuid.uuidString)")
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if profile == .compressed {
            pumpCompressed()
        }
    }

    private func beginIfReady() {
        guard peripheral != nil, let controlCharacteristic, dataCharacteristic != nil else { return }
        guard advertisedInfo?.requiresEncryptedGatt != true || secureLinkVerified else { return }
        guard !transferStarted else { return }
        let waits = controlCharacteristic.properties.contains(.notify) || controlCharacteristic.properties.contains(.indicate)
        guard !waits || (controlCharacteristic.isNotifying && notificationSettled) else { return }
        transferStarted = true
        log("Characteristics ready: control=\(controlCharacteristic.uuid.uuidString), data=\(dataCharacteristic?.uuid.uuidString ?? "")")
        log("Control props: \(Self.propertiesDescription(controlCharacteristic.properties))")
        if let dataCharacteristic {
            log("Data props: \(Self.propertiesDescription(dataCharacteristic.properties))")
        }
        writeCommand(Data([Command.requestBlockSize.rawValue]))
    }

    private func writeCommand(_ data: Data) {
        guard let peripheral, let controlCharacteristic else { return }
        // Native CoreBluetooth provides a definitive ATT result for
        // withResponse. If that path stalls, the 600ms fallback below retries
        // the same command withoutResponse, matching the current App flow.
        let type: CBCharacteristicWriteType = controlCharacteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        lastControlCommand = data.first
        retriedControlWithoutResponse = false
        startControlResponseTimer(command: data.first, originalData: data, writeType: type)
        startControlFallbackTimer(command: data.first, originalData: data)
        log("Control -> \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        peripheral.writeValue(data, for: controlCharacteristic, type: type)
    }

    private func handleControlMessage(_ data: Data) {
        let bytes = [UInt8](data)
        guard let first = bytes.first, let command = Command(rawValue: first) else {
            log("Control <- \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
            return
        }
        controlResponseTimer?.cancel()
        controlResponseTimer = nil
        controlFallbackTimer?.cancel()
        controlFallbackTimer = nil
        retriedControlWithoutResponse = false
        log("Control <- \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        switch command {
        case .requestBlockSize:
            guard bytes.count >= 3, bytes[2] == Status.success.rawValue else {
                log("Block size rejected")
                Foundation.exit(9)
            }
            blockPayloadSize = max(0, Int(bytes[1]) - 4)
            log("Block payload size: \(blockPayloadSize)")
            requestScreenSize()
        case .requestScreenSize:
            guard bytes.count >= 2, bytes[1] == Status.success.rawValue else {
                log("Payload length rejected")
                Foundation.exit(10)
            }
            writeCommand(Data([Command.requestStartTransfer.rawValue]))
        case .dataAck:
            guard bytes.count >= 2 else { return }
            if bytes[1] == Status.transferEnd.rawValue {
                finalAckTimer?.cancel()
                log("Transfer completed and refresh acknowledged")
                Foundation.exit(0)
            }
            guard bytes[1] == Status.success.rawValue, bytes.count >= 6 else {
                log("Data block rejected")
                Foundation.exit(11)
            }
            let index = Int(bytes[2]) | Int(bytes[3]) << 8 | Int(bytes[4]) << 16 | Int(bytes[5]) << 24
            if profile == .compressed {
                nextCompressedBlockIndex = index
                pumpCompressed()
            } else {
                sendStandardBlock(index)
            }
        default:
            break
        }
    }

    private func requestScreenSize() {
        var data = Data([Command.requestScreenSize.rawValue])
        data.append(UInt8(payload.count & 0xff))
        data.append(UInt8((payload.count >> 8) & 0xff))
        data.append(UInt8((payload.count >> 16) & 0xff))
        data.append(UInt8((payload.count >> 24) & 0xff))
        var flags: UInt8 = profile == .compressed ? 0x01 : 0x03
        if allowDeviceButton { flags |= 0x10 }
        data.append(flags)
        writeCommand(data)
    }

    private func makeBlock(index: Int) -> (packet: Data, percent: Int, isLast: Bool)? {
        guard blockPayloadSize > 0 else { return nil }
        let offset = index * blockPayloadSize
        guard offset < payload.count else { return nil }
        let length = min(blockPayloadSize, payload.count - offset)
        var packet = Data()
        packet.append(UInt8(index & 0xff))
        packet.append(UInt8((index >> 8) & 0xff))
        packet.append(UInt8((index >> 16) & 0xff))
        packet.append(UInt8((index >> 24) & 0xff))
        packet.append(payload.subdata(in: offset ..< offset + length))
        let written = offset + length
        return (packet, Int(Double(written) / Double(payload.count) * 100), written >= payload.count)
    }

    private func sendStandardBlock(_ index: Int) {
        guard let peripheral, let dataCharacteristic, let block = makeBlock(index: index) else { return }
        let type: CBCharacteristicWriteType = dataCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(block.packet, for: dataCharacteristic, type: type)
        emitProgress(block.percent, index: index)
        if block.isLast {
            waitForFinalAck(seconds: 5)
        }
    }

    private func pumpCompressed() {
        guard let peripheral, let dataCharacteristic else { return }
        guard dataCharacteristic.properties.contains(.writeWithoutResponse) else {
            log("Compressed transfer requires writeWithoutResponse data characteristic")
            Foundation.exit(12)
        }
        while peripheral.canSendWriteWithoutResponse {
            guard let index = nextCompressedBlockIndex, let block = makeBlock(index: index) else { return }
            peripheral.writeValue(block.packet, for: dataCharacteristic, type: .withoutResponse)
            emitProgress(block.percent, index: index)
            if block.isLast {
                nextCompressedBlockIndex = nil
                log("Payload written; waiting for refresh ack")
                waitForFinalAck(seconds: 90)
                return
            }
            nextCompressedBlockIndex = index + 1
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(6)) { [weak self] in
            self?.pumpCompressed()
        }
    }

    private func emitProgress(_ percent: Int, index: Int) {
        guard percent != lastProgress, percent.isMultiple(of: 5) || percent >= 100 else { return }
        lastProgress = percent
        log("Progress: \(percent)% block=\(index)")
    }

    private func waitForFinalAck(seconds: Int) {
        finalAckTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds))
        timer.setEventHandler {
            log("Timed out waiting for final refresh ack")
            Foundation.exit(13)
        }
        finalAckTimer = timer
        timer.resume()
    }

    private func startControlResponseTimer(command: UInt8?, originalData: Data, writeType: CBCharacteristicWriteType) {
        controlResponseTimer?.cancel()
        guard command != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if writeType == .withResponse,
               !self.retriedControlWithoutResponse,
               let peripheral = self.peripheral,
               let controlCharacteristic = self.controlCharacteristic,
               controlCharacteristic.properties.contains(.writeWithoutResponse) {
                self.retriedControlWithoutResponse = true
                log("Control response timed out; retrying withoutResponse")
                peripheral.writeValue(originalData, for: controlCharacteristic, type: .withoutResponse)
                self.startControlResponseTimer(command: command, originalData: originalData, writeType: .withoutResponse)
                return
            }
            log("Control response timed out")
            Foundation.exit(16)
        }
        controlResponseTimer = timer
        timer.resume()
    }

    private func startControlFallbackTimer(command: UInt8?, originalData: Data) {
        controlFallbackTimer?.cancel()
        guard let command,
              let controlCharacteristic,
              controlCharacteristic.properties.contains(.writeWithoutResponse) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(600))
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.lastControlCommand == command,
                  self.controlResponseTimer != nil,
                  !self.retriedControlWithoutResponse,
                  let peripheral = self.peripheral,
                  let controlCharacteristic = self.controlCharacteristic else { return }
            self.retriedControlWithoutResponse = true
            log("Control reply pending; retrying after 600ms withoutResponse")
            peripheral.writeValue(originalData, for: controlCharacteristic, type: .withoutResponse)
        }
        controlFallbackTimer = timer
        timer.resume()
    }

    private static func propertiesDescription(_ properties: CBCharacteristicProperties) -> String {
        var values: [String] = []
        if properties.contains(.broadcast) { values.append("broadcast") }
        if properties.contains(.read) { values.append("read") }
        if properties.contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if properties.contains(.write) { values.append("write") }
        if properties.contains(.notify) { values.append("notify") }
        if properties.contains(.indicate) { values.append("indicate") }
        return values.joined(separator: ",")
    }
}

private func usage() -> Never {
    log("""
    Usage:
      MacImageTransfer --list
      MacImageTransfer --pair --id UUID
      MacImageTransfer --probe --id UUID
      MacImageTransfer --payload /path/final-180.protocol.qlz --compressed --id UUID
      MacImageTransfer --payload /path/file.bin --standard --id UUID
    """)
    Foundation.exit(64)
}

private var payloadPath: String?
private var profile: Profile = .compressed
private var targetID: UUID?
private var listOnly = false
private var probeOnly = false
private var pairOnly = false
private var allowDeviceButton = false
private var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--list":
        listOnly = true
    case "--probe":
        probeOnly = true
    case "--pair":
        pairOnly = true
    case "--payload":
        guard !args.isEmpty else { usage() }
        payloadPath = args.removeFirst()
    case "--compressed":
        profile = .compressed
    case "--standard":
        profile = .standard
    case "--id":
        guard !args.isEmpty, let uuid = UUID(uuidString: args.removeFirst()) else { usage() }
        targetID = uuid
    case "--allow-device-button":
        allowDeviceButton = true
    default:
        usage()
    }
}

let payloadURL = URL(fileURLWithPath: payloadPath ?? "/dev/null")
if (listOnly ? 1 : 0) + (probeOnly ? 1 : 0) + (pairOnly ? 1 : 0) > 1 {
    usage()
}
if !listOnly, !probeOnly, !pairOnly, payloadPath == nil {
    usage()
}
if !listOnly, targetID == nil {
    usage()
}
MacImageTransfer(
    payloadURL: payloadURL,
    profile: profile,
    targetID: targetID,
    listOnly: listOnly,
    probeOnly: probeOnly,
    pairOnly: pairOnly,
    allowDeviceButton: allowDeviceButton
).run()
