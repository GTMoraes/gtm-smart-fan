import Foundation
import CoreBluetooth
import Security

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
    /// O ventilador está conectado ao broker MQTT (acesso remoto no ar).
    var mqttOn: Bool = false
    /// Estado veio do Home Assistant: só velocidade é conhecida — timer,
    /// origem e o resto não passam pelo HA.
    var viaRemote: Bool = false
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
    var mqttUri     = ""
    var mqttUser    = ""
    var hasMqttPass = false
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
    case mqttUri  = 0x09
    case mqttUser = 0x0A
    case mqttPass = 0x0B
    case factory = 0x7F
}

/// Uma rede encontrada pela busca do próprio ventilador.
struct WifiNet: Identifiable, Equatable {
    var ssid: String
    var rssi: Int
    var locked: Bool
    var id: String { ssid }

    /// 0...1, para o ícone de Wi-Fi com preenchimento variável.
    var bars: Double { rssi >= -60 ? 1.0 : (rssi >= -70 ? 0.66 : 0.33) }
}

enum WifiScan: Equatable {
    case idle
    case running
    case done(nets: [WifiNet], ignored: Int, cut: Int)
    case failed(String)
}

enum WifiTest: Equatable {
    case idle
    case running
    case ok(ip: String, rssi: Int)
    case failed(String)
}

enum Link: Equatable {
    case offline
    case scanning
    case bluetooth
    case wifi(String)
    case remote(String)

    var label: String {
        switch self {
        case .offline:        return "sem conexão"
        case .scanning:       return "procurando…"
        case .bluetooth:      return "bluetooth"
        case .wifi(let h):    return "wi-fi · \(h)"
        case .remote(let h):  return "remoto · \(h)"
        }
    }
}

enum RemoteTest: Equatable {
    case idle
    case running
    case ok(String)
    case failed(String)
}

struct HAError: Error { let msg: String; init(_ m: String) { msg = m } }

/// Token do Home Assistant: no Keychain, nunca em UserDefaults.
/// `AfterFirstUnlock` para os atalhos funcionarem com o iPhone bloqueado.
enum Keychain {
    private static let service = "com.gtm.ventilador.ha"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Valor vazio apaga. Devolve o OSStatus — erro de Keychain tem de aparecer.
    @discardableResult
    static func write(_ account: String, _ value: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return errSecSuccess }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
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
    @Published var wifiScan: WifiScan = .idle
    @Published var wifiTest: WifiTest = .idle

    // Acesso remoto pelo Home Assistant — o último degrau:
    // Bluetooth > HTTP local > HA. A URL mora no UserDefaults, o token no Keychain.
    @Published var haURL: String = UserDefaults.standard.string(forKey: "haURL") ?? ""
    @Published var haEntity: String = UserDefaults.standard.string(forKey: "haEntity") ?? ""
    @Published var remoteTest: RemoteTest = .idle
    @Published private(set) var hasHAToken: Bool = Keychain.read("haToken") != nil
    private var haToken: String? = Keychain.read("haToken")
    /// Com o remoto ativo, a rede local só é tentada de vez em quando.
    private var localCooldown = 0

    /// Host usado no fallback por Wi-Fi. `ventilador.local` na rede de casa,
    /// `192.168.4.1` quando o iPhone está no AP do próprio ventilador.
    @Published var wifiHost = "ventilador.local"

    // MARK: Bluetooth
    private let svcUUID   = CBUUID(string: "6F7A0001-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let cmdUUID   = CBUUID(string: "6F7A0002-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let stateUUID = CBUUID(string: "6F7A0003-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let cfgWUUID  = CBUUID(string: "6F7A0004-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let cfgRUUID  = CBUUID(string: "6F7A0005-4B2E-4A6D-9C1F-2B5D7E8A3C10")
    private let netUUID   = CBUUID(string: "6F7A0006-4B2E-4A6D-9C1F-2B5D7E8A3C10")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var cfgWChar: CBCharacteristic?
    private var cfgRChar: CBCharacteristic?
    private var netChar: CBCharacteristic?
    private var netTimeout: Task<Void, Never>?
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
            Task { _ = await sendSpeedOffBLE(speed) }
        }
    }

    /// Para os atalhos: manda e ESPERA a confirmação. Devolve por onde foi, ou
    /// nil se nenhum caminho respondeu — o atalho não pode dizer "feito" à toa.
    func setSpeedConfirmed(_ speed: Int) async -> String? {
        guard (0...3).contains(speed) else { return nil }
        if bluetoothActive { setSpeed(speed); return "por Bluetooth" }
        state.target = speed
        return await sendSpeedOffBLE(speed)
    }

    /// Sem Bluetooth: rede local primeiro, HA depois. Se o remoto é o caminho
    /// ativo, vai direto nele (a rede local já se mostrou ausente).
    private func sendSpeedOffBLE(_ speed: Int) async -> String? {
        var triedRemote = false
        if case .remote = link, remoteConfigured {
            triedRemote = true
            if await haSetSpeed(speed) { return "pelo Home Assistant" }
        }
        if await httpCall("/api/set?speed=\(speed)", timeout: 1.5) { return "pela rede local" }
        if !triedRemote, remoteConfigured, await haSetSpeed(speed) { return "pelo Home Assistant" }
        if !remoteConfigured && lastError == nil {
            lastError = "sem Bluetooth e sem rede local — configure o acesso remoto nos Ajustes"
        }
        return nil
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
            Task { _ = await timerOffBLE(m, a) }
        }
    }

    /// Para os atalhos: o timer não passa pelo HA (decisão do projeto).
    func setTimerConfirmed(minutes: Int, act: Int = 0) async -> String? {
        if bluetoothActive { setTimer(minutes: minutes, act: act); return "por Bluetooth" }
        let m = UInt16(max(0, min(1440, minutes)))
        return await timerOffBLE(m, UInt8(max(0, min(3, act))))
    }

    private func timerOffBLE(_ m: UInt16, _ a: UInt8) async -> String? {
        if await httpCall("/api/timer?min=\(m)&act=\(a)", timeout: 1.5) { return "pela rede local" }
        lastError = "o temporizador só funciona por Bluetooth ou na rede local"
        return nil
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
        c.mqttUri     = j["mqtt"]     as? String ?? ""
        c.mqttUser    = j["mqttuser"] as? String ?? ""
        c.hasMqttPass = (j["hasmqttpass"] as? Int ?? 0) == 1
        config = c
    }

    // MARK: busca de redes e teste de conexão (só por Bluetooth)

    /// O ventilador procura as redes de 2,4 GHz em volta dele — que é o que
    /// importa: o sinal que chega ao ventilador, não ao telefone.
    func scanWifi() {
        guard let link = netLink() else {
            wifiScan = .failed(lastError ?? "sem Bluetooth")
            return
        }
        let (p, c) = link
        wifiScan = .running
        p.writeValue(Data([0x08, 0x00]), for: c, type: .withResponse)
        armNetTimeout(seconds: 25)
    }

    /// Testa a rede de casa JÁ GRAVADA no ventilador. Quem chama tem de salvar
    /// SSID e senha antes (a fila do firmware garante a ordem).
    func testWifi() {
        guard let link = netLink() else {
            wifiTest = .failed(lastError ?? "sem Bluetooth")
            return
        }
        let (p, c) = link
        wifiTest = .running
        p.writeValue(Data([0x08, 0x01]), for: c, type: .withResponse)
        armNetTimeout(seconds: 35)
    }

    private func netLink() -> (CBPeripheral, CBCharacteristic)? {
        guard let p = peripheral, let c = cmdChar, p.state == .connected else {
            lastError = "a busca de redes funciona só pelo Bluetooth"
            return nil
        }
        // Conectado mas sem a característica nova: firmware antigo na placa.
        guard netChar != nil else {
            lastError = "o firmware da placa não tem a busca de redes — regrave"
            return nil
        }
        return (p, c)
    }

    /// Nada volta calado: se o ventilador não responder, a tela diz.
    private func armNetTimeout(seconds: Int) {
        netTimeout?.cancel()
        netTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if self.wifiScan == .running {
                self.wifiScan = .failed("o ventilador não respondeu em \(seconds) s")
            }
            if self.wifiTest == .running {
                self.wifiTest = .failed("o ventilador não respondeu em \(seconds) s")
            }
        }
    }

    /// Texto da característica 6f7a0006 — formato no PROTOCOLO.md.
    private func applyNet(_ d: Data) {
        let txt = String(decoding: d, as: UTF8.self)
        var lines = txt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return }
        let head = lines.removeFirst().split(separator: " ").map(String.init)
        guard head.count >= 2 else { return }
        let kind = head[0], st = head[1]

        if kind == "S" {
            guard wifiScan == .running else { return }      // resultado velho: ignora
            switch st {
            case "0": return                                  // ainda procurando
            case "1":
                var nets: [WifiNet] = []
                for l in lines where !l.isEmpty {
                    let f = l.split(separator: "\t", maxSplits: 2,
                                    omittingEmptySubsequences: false).map(String.init)
                    guard f.count == 3, let r = Int(f[0]) else { continue }
                    nets.append(WifiNet(ssid: f[2], rssi: r, locked: f[1] != "0"))
                }
                let ign = head.count > 2 ? Int(head[2]) ?? 0 : 0
                let cut = head.count > 3 ? Int(head[3]) ?? 0 : 0
                wifiScan = .done(nets: nets, ignored: ign, cut: cut)
            default:
                let m = head.count > 2 ? head[2] : "?"
                wifiScan = .failed(m == "semwifi" ? "firmware compilado sem Wi-Fi"
                                   : m == "tempo" ? "a busca não terminou em 15 s"
                                   : "a busca falhou (\(m))")
            }
        } else if kind == "T" {
            guard wifiTest == .running else { return }
            switch st {
            case "0": return
            case "1":
                let ip = head.count > 2 ? head[2] : "?"
                let rssi = head.count > 3 ? Int(head[3]) ?? 0 : 0
                wifiTest = .ok(ip: ip, rssi: rssi)
            default:
                let m = head.count > 2 ? head[2] : "?"
                let cod = head.count > 3 ? head[3] : "?"
                switch m {
                case "senha":    wifiTest = .failed("a rede recusou a senha (código \(cod))")
                case "naoachou": wifiTest = .failed("o ventilador não encontrou a rede — confira o nome e se ela é de 2,4 GHz (código \(cod))")
                case "tempo":    wifiTest = .failed("não conectou em 20 s (último código \(cod))")
                case "semrede":  wifiTest = .failed("nenhuma rede de casa gravada no ventilador")
                case "semwifi":  wifiTest = .failed("firmware compilado sem Wi-Fi")
                default:         wifiTest = .failed("falhou: \(m) (código \(cod))")
                }
            }
        }
        if wifiScan != .running && wifiTest != .running { netTimeout?.cancel() }
    }

    // MARK: acesso remoto (Home Assistant)

    var remoteConfigured: Bool { !haURL.isEmpty && haToken != nil }

    var haHost: String { URL(string: haURL)?.host ?? haURL }

    /// Grava URL e token. Token vazio mantém o atual; URL vazia desliga tudo.
    /// Devolve uma mensagem de erro, ou nil.
    func saveRemote(url: String, token: String) -> String? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if !u.isEmpty && !(u.hasPrefix("https://") || u.hasPrefix("http://")) {
            return "a URL precisa começar com https://"
        }
        if u.isEmpty {
            Keychain.write("haToken", "")
            haToken = nil
        } else if !token.isEmpty {
            let st = Keychain.write("haToken", token.trimmingCharacters(in: .whitespacesAndNewlines))
            if st != errSecSuccess { return "não consegui guardar o token no Keychain (código \(st))" }
            haToken = Keychain.read("haToken")
            if haToken == nil { return "o Keychain aceitou o token mas não devolveu — tente de novo" }
        }
        hasHAToken = haToken != nil
        haURL = u
        UserDefaults.standard.set(u, forKey: "haURL")
        setEntity("")                                // URL/token novos: redescobre
        remoteTest = .idle
        return nil
    }

    private func setEntity(_ id: String) {
        haEntity = id
        UserDefaults.standard.set(id, forKey: "haEntity")
    }

    private func haRequest(_ method: String, _ path: String,
                           body: [String: Any]? = nil,
                           timeout: TimeInterval = 6) async throws -> (Int, Data) {
        guard let tok = haToken, let url = URL(string: haURL + path) else {
            throw HAError("acesso remoto não configurado")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw HAError("o HA recusou o token (401) — gere outro em Perfil → Segurança") }
        return (code, d)
    }

    /// Acha a entidade do ventilador no HA: primeiro o nome padrão que o
    /// Discovery cria (fan.ventilador); se não existir, procura um fan.* cujo
    /// nome tenha "ventilador", preferindo o de 3 velocidades.
    private func haFindEntity() async throws -> String {
        if !haEntity.isEmpty { return haEntity }
        let (c1, _) = try await haRequest("GET", "/api/states/fan.ventilador")
        if c1 == 200 { setEntity("fan.ventilador"); return haEntity }
        let (c2, d2) = try await haRequest("GET", "/api/states", timeout: 10)
        guard c2 == 200,
              let arr = try JSONSerialization.jsonObject(with: d2) as? [[String: Any]] else {
            throw HAError("resposta inesperada do HA ao listar entidades (\(c2))")
        }
        var achados: [(String, Bool)] = []
        for e in arr {
            guard let id = e["entity_id"] as? String, id.hasPrefix("fan.") else { continue }
            let a = e["attributes"] as? [String: Any] ?? [:]
            let nome = (a["friendly_name"] as? String ?? "").lowercased()
            guard nome.contains("ventilador") else { continue }
            let passo = (a["percentage_step"] as? Double) ?? 0
            achados.append((id, abs(passo - 100.0 / 3) < 1))
        }
        guard let melhor = achados.first(where: { $0.1 }) ?? achados.first else {
            throw HAError("não achei o ventilador no HA — ele aparece no MQTT?")
        }
        setEntity(melhor.0)
        return haEntity
    }

    /// Lê o estado pelo HA. true = o HA respondeu (mesmo que o ventilador
    /// esteja indisponível — aí o erro diz isso).
    @discardableResult
    private func haPollState() async -> Bool {
        do {
            let id = try await haFindEntity()
            let (c, d) = try await haRequest("GET", "/api/states/\(id)")
            if c == 404 { setEntity(""); return false }      // renomeado: redescobre
            guard c == 200,
                  let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return false
            }
            link = .remote(haHost)
            let st = j["state"] as? String ?? ""
            if st == "unavailable" || st == "unknown" {
                var s = FanState(); s.viaRemote = true
                state = s
                lastError = "o ventilador está fora do ar no Home Assistant (sem Wi-Fi ou sem energia)"
                return true
            }
            let a = j["attributes"] as? [String: Any] ?? [:]
            let pct = (a["percentage"] as? Double) ?? Double(a["percentage"] as? Int ?? 0)
            // Mesma conta do HA: velocidade = teto(pct × 3 / 100).
            let sp = st == "on" ? max(1, min(3, Int((pct * 3 / 100).rounded(.up)))) : 0
            var s = FanState()
            s.speed = sp; s.target = sp; s.viaRemote = true; s.mqttOn = true
            state = s
            lastError = nil
            return true
        } catch let e as HAError {
            lastError = e.msg
            return false
        } catch {
            return false
        }
    }

    private func haSetSpeed(_ speed: Int) async -> Bool {
        do {
            let id = try await haFindEntity()
            // 33 / 66 / 100: o HA faz teto(pct × 3 / 100). 67 daria 3, não 2.
            let resp: (Int, Data)
            if speed == 0 {
                resp = try await haRequest("POST", "/api/services/fan/turn_off",
                                           body: ["entity_id": id])
            } else {
                resp = try await haRequest("POST", "/api/services/fan/set_percentage",
                                           body: ["entity_id": id,
                                                  "percentage": [0, 33, 66, 100][speed]])
            }
            let c = resp.0
            guard c == 200 else { lastError = "o HA recusou o comando (\(c))"; return false }
            link = .remote(haHost)
            lastError = nil
            // O HA responde antes de o ventilador aplicar: relê em seguida.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                await self?.haPollState()
            }
            return true
        } catch let e as HAError {
            lastError = e.msg
            return false
        } catch {
            lastError = "sem resposta de \(haHost): \(error.localizedDescription)"
            return false
        }
    }

    /// Botão "Testar acesso remoto": cada etapa falha com o motivo dela.
    func testRemote() async {
        remoteTest = .running
        guard remoteConfigured else { remoteTest = .failed("preencha a URL e o token"); return }
        do {
            let (c, _) = try await haRequest("GET", "/api/")
            guard c == 200 else {
                remoteTest = .failed("o HA respondeu \(c) em /api/ — a URL está certa?")
                return
            }
            setEntity("")
            let id = try await haFindEntity()
            let (c2, d2) = try await haRequest("GET", "/api/states/\(id)")
            guard c2 == 200,
                  let j = try JSONSerialization.jsonObject(with: d2) as? [String: Any] else {
                remoteTest = .failed("achei \(id), mas não consegui ler o estado (\(c2))")
                return
            }
            let st = j["state"] as? String ?? "?"
            remoteTest = (st == "unavailable")
                ? .ok("acesso ok · \(id) — mas o ventilador está indisponível no HA agora")
                : .ok("acesso ok · \(id) · \(st == "on" ? "ligado" : "desligado")")
        } catch let e as HAError {
            remoteTest = .failed(e.msg)
        } catch {
            remoteTest = .failed("sem resposta de \(haHost): \(error.localizedDescription)")
        }
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
                await self.pollOffBLE()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Sem Bluetooth: rede local; se não responder, o HA. Com o remoto ativo,
    /// a rede local é retentada a cada ~10 s — voltou para casa, ela assume.
    private func pollOffBLE() async {
        if bluetoothActive { return }
        if localCooldown > 0 && remoteConfigured {
            localCooldown -= 1
        } else if await httpCall("/api/state", timeout: 1.5) {
            localCooldown = 0
            return
        }
        if remoteConfigured, await haPollState() {
            if localCooldown == 0 { localCooldown = 5 }
        }
    }

    private var bluetoothActive: Bool {
        peripheral?.state == .connected && cmdChar != nil
    }

    @discardableResult
    private func httpCall(_ path: String, timeout: TimeInterval = 3) async -> Bool {
        guard let url = URL(string: "http://\(wifiHost)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
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
            switch link {
            case .bluetooth, .remote: break      // outro caminho segue valendo
            default: link = .offline
            }
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
        s.mqttOn      = (j["mqtt"] as? String ?? "") == "conectado"
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
        netChar = nil
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
            // (O workflow de build confere que todo UUID declarado está nesta lista.)
            p.discoverCharacteristics([cmdUUID, stateUUID, cfgWUUID, cfgRUUID, netUUID], for: $0)
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
            if ch.uuid == netUUID {
                netChar = ch
                p.setNotifyValue(true, for: ch)
                // Reconectou no meio de uma busca/teste (o Bluetooth pode piscar
                // enquanto o rádio varre os canais): o resultado pode já estar lá.
                if wifiScan == .running || wifiTest == .running { p.readValue(for: ch) }
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic,
                    error: Error?) {
        if ch.uuid == cfgRUUID, let d = ch.value { applyConfig(d); lastError = nil; return }
        if ch.uuid == netUUID, let d = ch.value {
            // Notify traz só "!" (o valor inteiro não cabe num notify): lê o completo.
            if d == Data([0x21]) { p.readValue(for: ch) } else { applyNet(d) }
            return
        }
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
        s.mqttOn       = (d[6] & 0x10) != 0
        state = s
        link = .bluetooth
        lastError = nil
    }
}
