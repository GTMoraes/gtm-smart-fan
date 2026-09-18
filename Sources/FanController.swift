import Foundation
import CoreBluetooth

/// Estado do ventilador, igual nas duas vias de comunicação.
struct FanState: Equatable {
    var speed: Int = 0
    var target: Int = 0
    var busy: Bool = false
    var source: Int = 0
    var timerMin: Int = 0
    var wifiOn: Bool = false
}

enum Link: Equatable {
    case offline
    case scanning
    case bluetooth
    case wifi(String)

    var label: String {
        switch self {
        case .offline:      return "sem conexão"
        case .scanning:     return "procurando…"
        case .bluetooth:    return "bluetooth"
        case .wifi(let h):  return "wi-fi · \(h)"
        }
    }
}

@MainActor
final class FanController: NSObject, ObservableObject {

    @Published var state = FanState()
    @Published var link: Link = .offline
    @Published var lastError: String?

    /// Host usado no fallback por Wi-Fi. `ventilador.local` na rede de casa,
    /// `192.168.4.1` quando o iPhone está no AP do próprio ventilador.
    @Published var wifiHost = "ventilador.local"

    // MARK: Bluetooth
    private let svcUUID   = CBUUID(string: "6F7A0001-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let cmdUUID   = CBUUID(string: "6F7A0002-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let stateUUID = CBUUID(string: "6F7A0003-4B2E-4A6D-9C1F-2B5D7E8A3C10")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var pollTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        startWifiPolling()
    }

    // MARK: comandos

    func setSpeed(_ speed: Int) {
        guard (0...3).contains(speed) else { return }
        state.target = speed
        state.busy = true

        if let p = peripheral, let c = cmdChar, p.state == .connected {
            p.writeValue(Data([0x01, UInt8(speed)]), for: c, type: .withResponse)
        } else {
            Task { await httpCall("/api/set?speed=\(speed)") }
        }
    }

    func setTimer(minutes: Int) {
        let m = UInt16(max(0, min(720, minutes)))
        if let p = peripheral, let c = cmdChar, p.state == .connected {
            p.writeValue(Data([0x02, UInt8(m & 0xFF), UInt8(m >> 8)]),
                         for: c, type: .withResponse)
        } else {
            Task { await httpCall("/api/timer?min=\(m)") }
        }
    }

    /// Liga ou desliga o Wi-Fi do ventilador — via BLE, que é o único caminho
    /// que funciona justamente quando o Wi-Fi está desligado.
    func setWifi(_ on: Bool) {
        guard let p = peripheral, let c = cmdChar, p.state == .connected else {
            lastError = "ligar o Wi-Fi só pelo Bluetooth"
            return
        }
        p.writeValue(Data([0x03, on ? 1 : 0]), for: c, type: .withResponse)
    }

    // MARK: Wi-Fi (fallback: só entra quando o Bluetooth não está disponível)

    private func startWifiPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.bluetoothActive == false {
                    await self.httpCall("/api/state")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var bluetoothActive: Bool {
        peripheral?.state == .connected && cmdChar != nil
    }

    @discardableResult
    private func httpCall(_ path: String) async -> Bool {
        guard let url = URL(string: "http://\(wifiHost)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            apply(json: j)
            link = .wifi(wifiHost)
            lastError = nil
            return true
        } catch {
            if case .bluetooth = link {} else { link = .offline }
            return false
        }
    }

    private func apply(json j: [String: Any]) {
        var s = FanState()
        s.speed    = j["speed"]  as? Int ?? 0
        s.target   = j["target"] as? Int ?? 0
        s.busy     = (j["busy"]  as? Int ?? 0) == 1
        s.source   = j["source"] as? Int ?? 0
        s.timerMin = j["timer"]  as? Int ?? 0
        s.wifiOn   = true
        state = s
    }
}

// MARK: - CoreBluetooth

extension FanController: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            link = .scanning
            c.scanForPeripherals(withServices: [svcUUID])
        } else {
            link = .offline
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        c.stopScan()
        peripheral = p
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        link = .bluetooth
        p.discoverServices([svcUUID])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        cmdChar = nil
        peripheral = nil
        link = .scanning
        c.scanForPeripherals(withServices: [svcUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral,
                        error: Error?) {
        link = .scanning
        c.scanForPeripherals(withServices: [svcUUID])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.filter { $0.uuid == svcUUID }.forEach {
            p.discoverCharacteristics([cmdUUID, stateUUID], for: $0)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService,
                    error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == cmdUUID { cmdChar = ch }
            if ch.uuid == stateUUID {
                p.setNotifyValue(true, for: ch)
                p.readValue(for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        guard ch.uuid == stateUUID, let d = ch.value, d.count >= 7 else { return }
        var s = FanState()
        s.speed    = Int(d[0])
        s.target   = Int(d[1])
        s.busy     = d[2] == 1
        s.source   = Int(d[3])
        s.timerMin = Int(d[4]) | (Int(d[5]) << 8)
        s.wifiOn   = (d[6] & 0x01) == 1
        state = s
        link = .bluetooth
        lastError = nil
    }
}
