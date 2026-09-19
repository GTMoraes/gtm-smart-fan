import Foundation
import CoreBluetooth

/// Estado do ventilador, igual nas duas vias de comunicação.
struct FanState: Equatable {
    var speed: Int = 0
    var target: Int = 0
    var busy: Bool = false
    var source: Int = 0
    var timerMin: Int = 0
    /// O que o timer fará ao disparar: 0 desliga, 1..3 liga naquela velocidade.
    var timerAct: Int = 0
    var wifiOn: Bool = false
    /// "Voltar como estava depois de faltar energia" — ajuste guardado no
    /// próprio ventilador, não no telefone.
    var restoreOn: Bool = false
    /// Wi-Fi NÃO se desliga sozinho por ociosidade.
    var wifiStaysOn: Bool = false
}

/// Ajustes que moram no ventilador, não no telefone. Nenhuma senha vem junto —
/// só a informação de que existe uma.
struct FanConfig: Equatable {
    var bleName     = ""
    var staSsid     = ""
    var apSsid      = ""
    var mdns        = ""
    var hasStaPass  = false
    var hasApPass   = false
    var hasToken    = false
    var bleSecOn    = false
    var wifiIdleMin = 20
}

/// Ids dos ajustes — os mesmos do firmware e do PROTOCOLO.md.
enum CfgId: UInt8 {
    case bleName = 0x01
    case staSsid = 0x02
    case staPass = 0x03
    case apSsid  = 0x04
    case apPass  = 0x05
    case mdns    = 0x06
    case token   = 0x07
    case passkey = 0x08
    case factory = 0x7F
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

    /// Instância única — os App Intents precisam alcançar o mesmo rádio que a
    /// interface usa, senão cada atalho abriria uma conexão paralela.
    static let shared = FanController()

    @Published var state = FanState()
    @Published var config = FanConfig()
    @Published var link: Link = .offline
    @Published var lastError: String?

    /// Host usado no fallback por Wi-Fi. `ventilador.local` na rede de casa,
    /// `192.168.4.1` quando o iPhone está no AP do próprio ventilador.
    @Published var wifiHost = "ventilador.local"

    // MARK: Bluetooth
    private let svcUUID   = CBUUID(string: "6F7A0001-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let cmdUUID   = CBUUID(string: "6F7A0002-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let stateUUID = CBUUID(string: "6F7A0003-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let cfgWUUID  = CBUUID(string: "6F7A0004-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let cfgRUUID  = CBUUID(string: "6F7A0005-4B2E-4A6D-9C1F-2B5D7E8A3C10")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var cfgWChar: CBCharacteristic?
    private var cfgRChar: CBCharacteristic?
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

    /// `act`: 0 desliga, 1..3 liga naquela velocidade. Um timer por vez.
    func setTimer(minutes: Int, act: Int = 0) {
        let m = UInt16(max(0, min(1440, minutes)))   // teto 24 h
        let a = UInt8(max(0, min(3, act)))
        state.timerAct = Int(a)
        if let p = peripheral, let c = cmdChar, p.state == .connected {
            p.writeValue(Data([0x02, UInt8(m & 0xFF), UInt8(m >> 8), a]),
                         for: c, type: .withResponse)
        } else {
            Task { await httpCall("/api/timer?min=\(m)&act=\(a)") }
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

    /// Wi-Fi permanente x desliga sozinho. O valor "desliga sozinho" volta para
    /// 20 min; a página web permite escolher outros degraus.
    func setWifiStaysOn(_ on: Bool) {
        state.wifiStaysOn = on
        let m: UInt16 = on ? 0 : 20
        let pkt = Data([0x05, UInt8(m & 0xFF), UInt8(m >> 8)])
        if let p = peripheral, let c = cmdChar, p.state == .connected {
            p.writeValue(pkt, for: c, type: .withResponse)
        } else {
            Task { await httpCall("/api/wifioff?min=\(m)") }
        }
    }

    // MARK: ajustes

    /// Grava um ajuste no ventilador. O pacote é `<id><texto UTF-8>`.
    func setSetting(_ id: CfgId, _ value: String) {
        if let p = peripheral, p.state == .connected {
            // Conectado por BLE mas sem a característica de ajustes: é firmware
            // antigo na placa. Dizer isso é melhor que cair calado no HTTP.
            guard let c = cfgWChar else {
                lastError = "conectado, mas o ventilador não expõe ajustes por Bluetooth — regrave o firmware"
                return
            }
            var pkt = Data([id.rawValue])
            pkt.append(contentsOf: Array(value.utf8))
            p.writeValue(pkt, for: c, type: .withResponse)
            lastError = nil
            // dá tempo do firmware gravar antes de reler
            Task { try? await Task.sleep(for: .milliseconds(400)); refreshConfig() }
        } else {
            let esc = value.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? ""
            Task {
                await httpCall("/api/setcfg?id=\(id.rawValue)&v=\(esc)")
                await httpConfig()
            }
        }
    }

    /// Reinicia o ventilador — necessário para nome BLE e pareamento.
    func reboot() {
        if let p = peripheral, let c = cmdChar, p.state == .connected {
            p.writeValue(Data([0x06, 0x01]), for: c, type: .withResponse)
        } else {
            Task { await httpCall("/api/reboot") }
        }
    }

    func refreshConfig() {
        if let p = peripheral, p.state == .connected {
            guard let c = cfgRChar else {
                lastError = "conectado, mas o ventilador não expõe ajustes por Bluetooth — regrave o firmware"
                return
            }
            p.readValue(for: c)
        } else {
            Task {
                if await httpConfig() == false {
                    lastError = "sem Bluetooth e sem Wi-Fi — não consegui ler os ajustes"
                }
            }
        }
    }

    @discardableResult
    private func httpConfig() async -> Bool {
        guard let url = URL(string: "http://\(wifiHost)/api/config") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            applyConfig(data)
            return true
        } catch { return false }
    }

    private func applyConfig(_ data: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var c = FanConfig()
        c.bleName     = j["blename"] as? String ?? ""
        c.staSsid     = j["sta"]     as? String ?? ""
        c.apSsid      = j["ap"]      as? String ?? ""
        c.mdns        = j["mdns"]    as? String ?? ""
        c.hasStaPass  = (j["hasstapass"] as? Int ?? 0) == 1
        c.hasApPass   = (j["hasappass"]  as? Int ?? 0) == 1
        c.hasToken    = (j["hastoken"]   as? Int ?? 0) == 1
        c.bleSecOn    = (j["blesec"]     as? Int ?? 0) == 1
        c.wifiIdleMin = j["wifioff"] as? Int ?? 20
        config = c
    }

    // MARK: para os App Intents

    /// Espera o BLE ficar utilizável, até `timeout`. Um atalho disparado com o
    /// app fechado chega aqui antes de o rádio ter conectado.
    @discardableResult
    func waitForBluetooth(timeout: TimeInterval = 6) async -> Bool {
        let limite = Date().addingTimeInterval(timeout)
        while Date() < limite {
            if bluetoothActive { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Liga ou desliga o "voltar como estava". Vale pelas duas vias, porque o
    /// ajuste mora na memória do ventilador.
    func setRestore(_ on: Bool) {
        state.restoreOn = on                      // otimista; o notify confirma
        if let p = peripheral, let c = cmdChar, p.state == .connected {
            p.writeValue(Data([0x04, on ? 1 : 0]), for: c, type: .withResponse)
        } else {
            Task { await httpCall("/api/restore?on=\(on ? 1 : 0)") }
        }
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
        s.timerAct = j["timeract"] as? Int ?? 0
        s.wifiOn   = true
        s.restoreOn   = (j["restore"] as? Int ?? 0) == 1
        s.wifiStaysOn = (j["wifioff"] as? Int ?? 20) == 0
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
        cfgWChar = nil
        cfgRChar = nil
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
            // As quatro. Esquecer as de configuração aqui faz cfgWChar/cfgRChar
            // ficarem nil para sempre, e a tela de ajustes silenciosamente cai
            // no fallback HTTP — que não funciona com o Wi-Fi desligado.
            p.discoverCharacteristics([cmdUUID, stateUUID, cfgWUUID, cfgRUUID], for: $0)
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
            if ch.uuid == cfgWUUID { cfgWChar = ch }
            if ch.uuid == cfgRUUID { cfgRChar = ch; p.readValue(for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        if ch.uuid == cfgRUUID, let d = ch.value { applyConfig(d); lastError = nil; return }
        guard ch.uuid == stateUUID, let d = ch.value, d.count >= 7 else { return }
        var s = FanState()
        s.speed    = Int(d[0])
        s.target   = Int(d[1])
        s.busy     = d[2] == 1
        s.source   = Int(d[3])
        s.timerMin = Int(d[4]) | (Int(d[5]) << 8)
        s.timerAct = d.count >= 8 ? Int(d[7]) : 0
        s.wifiOn    = (d[6] & 0x01) != 0
        s.restoreOn    = (d[6] & 0x02) != 0
        s.wifiStaysOn  = (d[6] & 0x04) != 0
        state = s
        link = .bluetooth
        lastError = nil
    }
}
