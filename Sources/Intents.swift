import AppIntents
import SwiftUI

/// Velocidades como enum, para o Atalhos mostrar uma lista em vez de pedir um
/// número solto.
enum FanSpeed: Int, AppEnum {
    case desligado = 0
    case lento     = 1
    case medio     = 2
    case rapido    = 3

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Velocidade"
    static var caseDisplayRepresentations: [FanSpeed: DisplayRepresentation] = [
        .desligado: "Desligado",
        .lento:     "Lento",
        .medio:     "Médio",
        .rapido:    "Rápido",
    ]
}

/// Tenta o Bluetooth primeiro; se o rádio não subir a tempo, o próprio
/// `setSpeed` cai para HTTP, que funciona se o Wi-Fi do ventilador estiver no ar.
@MainActor
private func comandar(_ acao: (FanController) -> Void) async {
    let fan = FanController.shared
    await fan.waitForBluetooth(timeout: 6)
    acao(fan)
    try? await Task.sleep(for: .milliseconds(700))
}

struct SetSpeedIntent: AppIntent {
    static var title: LocalizedStringResource = "Definir velocidade"
    static var description = IntentDescription("Põe o ventilador numa velocidade de 0 a 3.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Velocidade")
    var speed: FanSpeed

    static var parameterSummary: some ParameterSummary {
        Summary("Pôr o ventilador em \(\.$speed)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await comandar { $0.setSpeed(speed.rawValue) }
        return .result()
    }
}

struct TurnOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Desligar o ventilador"
    static var description = IntentDescription("Desliga o ventilador.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await comandar { $0.setSpeed(0) }
        return .result()
    }
}

struct SetTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Programar temporizador"
    static var description = IntentDescription("Liga ou desliga o ventilador depois de N minutos.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutos", default: 30, inclusiveRange: (0, 1440))
    var minutes: Int

    @Parameter(title: "Depois, ir para")
    var action: FanSpeed

    static var parameterSummary: some ParameterSummary {
        Summary("Em \(\.$minutes) minutos, pôr o ventilador em \(\.$action)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await comandar { $0.setTimer(minutes: minutes, act: action.rawValue) }
        return .result()
    }
}

struct SetWifiIntent: AppIntent {
    static var title: LocalizedStringResource = "Wi-Fi do ventilador"
    static var description = IntentDescription("Liga ou desliga o Wi-Fi do ventilador.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Ligado", default: true)
    var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        await comandar { $0.setWifi(on) }
        return .result()
    }
}

/// Faz os atalhos aparecerem prontos no app Atalhos, sem o usuário ter que
/// procurar. As frases precisam conter o nome do app.
struct VentiladorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetSpeedIntent(),
            phrases: ["Ajustar o \(.applicationName)", "Velocidade do \(.applicationName)"],
            shortTitle: "Definir velocidade",
            systemImageName: "wind"
        )
        AppShortcut(
            intent: TurnOffIntent(),
            phrases: ["Desligar o \(.applicationName)"],
            shortTitle: "Desligar",
            systemImageName: "power"
        )
        AppShortcut(
            intent: SetTimerIntent(),
            phrases: ["Programar o \(.applicationName)"],
            shortTitle: "Programar desligamento",
            systemImageName: "timer"
        )
    }
}
