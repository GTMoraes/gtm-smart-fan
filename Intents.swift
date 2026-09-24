import AppIntents
import Foundation

// =====================================================================
//  Ações para o app Atalhos.
//
//  TODAS SEM PARÂMETRO, e isso é deliberado.
//
//  A primeira versão deste arquivo usava um `@Parameter` de um `AppEnum`
//  customizado (FanSpeed). O build passava, o app instalava, e NENHUMA ação
//  aparecia no Atalhos — porque o `appintentsmetadataprocessor` falha em
//  silêncio com tipos customizados de parâmetro e não gera o
//  `Metadata.appintents` dentro do .app. Sem esse diretório, o iOS não tem o
//  que registrar.
//
//  O ChargeSpeed, do mesmo autor e mesmo pipeline de build, funciona — e tem
//  exatamente esta forma: intents sem parâmetro. Copiamos a forma que funciona.
//
//  Se um dia quiser um parâmetro (minutos livres no timer), acrescente UM
//  intent com tipo primitivo (Int), rode o build, e confira o passo
//  "Conferir ícone e App Intents no bundle" antes de instalar.
// =====================================================================

/// Tenta o Bluetooth primeiro; se o rádio não subir a tempo, o próprio
/// `setSpeed` cai para HTTP, que funciona se o Wi-Fi do ventilador estiver no ar.
@MainActor
private func comandar(_ acao: (FanController) -> Void) async {
    let fan = FanController.shared
    await fan.waitForBluetooth(timeout: 6)
    acao(fan)
    try? await Task.sleep(for: .milliseconds(700))
}

/// Velocidade: Bluetooth > rede local > Home Assistant, e ESPERA a confirmação.
/// O atalho só diz "feito" se algum caminho confirmou — e diz qual.
@MainActor
private func velocidade(_ n: Int, _ feito: String) async -> String {
    let fan = FanController.shared
    await fan.waitForBluetooth(timeout: 6)
    if let via = await fan.setSpeedConfirmed(n) { return "\(feito), \(via)." }
    return "Não consegui falar com o ventilador: \(fan.lastError ?? "nenhum caminho respondeu")."
}

/// Timer: não passa pelo HA — só Bluetooth ou rede local.
@MainActor
private func timer(_ min: Int, _ feito: String) async -> String {
    let fan = FanController.shared
    await fan.waitForBluetooth(timeout: 6)
    if let via = await fan.setTimerConfirmed(minutes: min, act: 0) { return "\(feito), \(via)." }
    return "Não programei: o temporizador só funciona por Bluetooth ou na rede local."
}

// MARK: - Velocidades

struct DesligarIntent: AppIntent {
    static var title: LocalizedStringResource = "Desligar o ventilador"
    static var description = IntentDescription("Desliga o ventilador.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await velocidade(0, "Ventilador desligado")
        return .result(dialog: "\(msg)")
    }
}

struct Velocidade1Intent: AppIntent {
    static var title: LocalizedStringResource = "Ventilador na velocidade 1"
    static var description = IntentDescription("Põe o ventilador no lento.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await velocidade(1, "Ventilador no lento")
        return .result(dialog: "\(msg)")
    }
}

struct Velocidade2Intent: AppIntent {
    static var title: LocalizedStringResource = "Ventilador na velocidade 2"
    static var description = IntentDescription("Põe o ventilador no médio.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await velocidade(2, "Ventilador no médio")
        return .result(dialog: "\(msg)")
    }
}

struct Velocidade3Intent: AppIntent {
    static var title: LocalizedStringResource = "Ventilador na velocidade 3"
    static var description = IntentDescription("Põe o ventilador no rápido.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await velocidade(3, "Ventilador no rápido")
        return .result(dialog: "\(msg)")
    }
}

// MARK: - Temporizador

struct Desligar30Intent: AppIntent {
    static var title: LocalizedStringResource = "Desligar o ventilador em 30 minutos"
    static var description = IntentDescription("Programa o desligamento para daqui a 30 minutos.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await timer(30, "Desliga em 30 minutos")
        return .result(dialog: "\(msg)")
    }
}

struct Desligar1hIntent: AppIntent {
    static var title: LocalizedStringResource = "Desligar o ventilador em 1 hora"
    static var description = IntentDescription("Programa o desligamento para daqui a 1 hora.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await timer(60, "Desliga em 1 hora")
        return .result(dialog: "\(msg)")
    }
}

struct CancelarTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancelar o temporizador do ventilador"
    static var description = IntentDescription("Cancela o temporizador, sem mexer na velocidade.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let msg = await timer(0, "Temporizador cancelado")
        return .result(dialog: "\(msg)")
    }
}

// MARK: - Wi-Fi

struct LigarWifiIntent: AppIntent {
    static var title: LocalizedStringResource = "Ligar o Wi-Fi do ventilador"
    static var description = IntentDescription("Sobe o rádio Wi-Fi do ventilador.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await comandar { $0.setWifi(true) }
        return .result(dialog: "Wi-Fi do ventilador no ar.")
    }
}

// MARK: - Atalhos prontos na galeria

struct VentiladorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DesligarIntent(),
                    phrases: ["Desligar o \(.applicationName)"],
                    shortTitle: "Desligar",
                    systemImageName: "power")
        AppShortcut(intent: Velocidade1Intent(),
                    phrases: ["\(.applicationName) no lento"],
                    shortTitle: "Velocidade 1",
                    systemImageName: "wind")
        AppShortcut(intent: Velocidade2Intent(),
                    phrases: ["\(.applicationName) no médio"],
                    shortTitle: "Velocidade 2",
                    systemImageName: "wind")
        AppShortcut(intent: Velocidade3Intent(),
                    phrases: ["\(.applicationName) no rápido"],
                    shortTitle: "Velocidade 3",
                    systemImageName: "wind")
        AppShortcut(intent: Desligar30Intent(),
                    phrases: ["Programar o \(.applicationName)"],
                    shortTitle: "Desligar em 30 min",
                    systemImageName: "timer")
    }
}
