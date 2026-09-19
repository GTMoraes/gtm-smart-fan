import SwiftUI

struct ContentView: View {
    // Instância única: os App Intents comandam o mesmo rádio que esta tela.
    @ObservedObject private var fan = FanController.shared
    @State private var mostrarAjustes = false
    @State private var timerH = 0
    @State private var timerM = 30
    @State private var timerAct = 0
    private let nomes = ["Desligado", "Lento", "Médio", "Rápido"]
    private let fontes = ["boot", "chave física", "celular", "bluetooth", "timer"]

    var body: some View {
        VStack(spacing: 18) {

            HStack {
                Text("Ventilador").font(.title2.weight(.semibold))
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(corDoLink)
                        .frame(width: 8, height: 8)
                    Text(fan.link.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button { mostrarAjustes = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
                .accessibilityLabel("Ajustes")
            }

            VStack(spacing: 4) {
                Text(nomes[min(fan.state.speed, 3)])
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text(legenda)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

            LazyVGrid(columns: [GridItem(), GridItem()], spacing: 12) {
                ForEach(0..<4, id: \.self) { n in
                    Button { fan.setSpeed(n) } label: {
                        VStack(spacing: 4) {
                            Text("\(n)").font(.system(size: 26, weight: .bold, design: .rounded))
                            Text(nomes[n]).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            fan.state.target == n ? Color.accentColor.opacity(0.22)
                                                  : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(fan.state.target == n ? Color.accentColor : .clear,
                                        lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("TEMPORIZADOR")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(legendaTimer)
                        .font(.caption2)
                        .foregroundStyle(fan.state.timerMin > 0 ? Color.accentColor : .secondary)
                }

                Picker("Ação", selection: $timerAct) {
                    Text("Desligar").tag(0)
                    Text("Ligar 1").tag(1)
                    Text("Ligar 2").tag(2)
                    Text("Ligar 3").tag(3)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 0) {
                    Picker("Horas", selection: $timerH) {
                        ForEach(0..<25, id: \.self) { Text("\($0) h").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104)
                    .clipped()

                    Picker("Minutos", selection: $timerM) {
                        ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104)
                    .clipped()
                }

                HStack(spacing: 8) {
                    Button("Programar") {
                        let m = min(1440, timerH * 60 + timerM)
                        if m > 0 { fan.setTimer(minutes: m, act: timerAct) }
                    }
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                    .buttonStyle(.plain)
                    .disabled(timerH == 0 && timerM == 0)
                    .opacity(timerH == 0 && timerM == 0 ? 0.4 : 1)

                    Button("Cancelar") { fan.setTimer(minutes: 0, act: 0) }
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .buttonStyle(.plain)
                        .disabled(fan.state.timerMin == 0)
                        .opacity(fan.state.timerMin == 0 ? 0.4 : 1)
                }
            }
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))

            Toggle(isOn: Binding(
                get: { fan.state.restoreOn },
                set: { fan.setRestore($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voltar como estava").font(.footnote)
                    Text(fan.state.restoreOn
                         ? "depois de faltar energia, religa na última velocidade"
                         : "depois de faltar energia, fica desligado")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))

            if case .bluetooth = fan.link {
                Toggle(isOn: Binding(
                    get: { fan.state.wifiOn },
                    set: { fan.setWifi($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi do ventilador").font(.footnote)
                        Text(fan.state.wifiOn
                             ? "no ar — abra ventilador.local no navegador"
                             : "desligado (economiza energia)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))

                Toggle(isOn: Binding(
                    get: { fan.state.wifiStaysOn },
                    set: { fan.setWifiStaysOn($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi permanente").font(.footnote)
                        Text(fan.state.wifiStaysOn
                             ? "fica no ar até você desligar"
                             : "cai sozinho após 20 min sem uso")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            }

            Spacer()

            HStack {
                Text("Host Wi-Fi")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("ventilador.local", text: $fan.wifiHost)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.055, green: 0.067, blue: 0.086).ignoresSafeArea())
        .tint(Color(red: 0.37, green: 0.69, blue: 0.94))
        .onChange(of: fan.state.timerAct) { _, novo in timerAct = novo }
        .sheet(isPresented: $mostrarAjustes) {
            NavigationStack { SettingsView(fan: fan) }
                .tint(Color(red: 0.37, green: 0.69, blue: 0.94))
        }
    }

    /// Quanto falta, em horas e minutos.
    private var legendaTimer: String {
        let m = fan.state.timerMin
        guard m > 0 else { return "sem timer" }
        let h = m / 60, mm = m % 60
        var p: [String] = []
        if h > 0  { p.append("\(h) h") }
        if mm > 0 { p.append("\(mm) min") }
        let oque = fan.state.timerAct == 0 ? "desliga" : "liga no \(fan.state.timerAct)"
        return oque + " em " + p.joined(separator: " e ")
    }

    private var legenda: String {
        if fan.state.busy || fan.state.speed != fan.state.target {
            return "mudando para \(nomes[min(fan.state.target, 3)].lowercased())…"
        }
        if fan.state.timerMin > 0 { return legendaTimer }
        return "último comando: \(fontes[min(fan.state.source, 4)])"
    }

    private var corDoLink: Color {
        switch fan.link {
        case .offline:   return .gray
        case .scanning:  return .yellow
        case .bluetooth: return .blue
        case .wifi:      return .green
        }
    }
}
