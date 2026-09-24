import SwiftUI

/// Tela de ajustes. Tudo aqui mora no ventilador, não no telefone — trocar de
/// celular não perde nada, e a página web mostra os mesmos valores.
struct SettingsView: View {
    @ObservedObject var fan: FanController
    @Environment(\.dismiss) private var dismiss

    @State private var bleName  = ""
    @State private var staSsid  = ""
    @State private var staPass  = ""
    @State private var apSsid   = ""
    @State private var apPass   = ""
    @State private var mdns     = ""
    @State private var token    = ""
    @State private var passkey  = ""
    @State private var precisaReiniciar = false
    @State private var aviso: String?
    /// Rede tocada na lista da busca — é por ela que se sabe se é aberta.
    @State private var escolhida: WifiNet?
    /// A lista da busca só fica aberta até uma rede ser tocada — depois some,
    /// para não ficar no caminho do "Testar" nem receber toque acidental.
    @State private var listaAberta = false
    @FocusState private var focoSenha: Bool

    var body: some View {
        Form {
            Section {
                TextField("Ventilador", text: $bleName)
                    .autocorrectionDisabled()
                if !passkeyPlaceholder.isEmpty {
                    TextField(passkeyPlaceholder, text: $passkey)
                        .keyboardType(.numberPad)
                }
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("Pareamento: 6 dígitos para ligar, ou **0** para desligar. "
                     + "Ligado, o iPhone pede o código no primeiro pareamento. "
                     + "Se você esquecer o código, só regravando o firmware. "
                     + "O botão físico do ventilador funciona sempre.")
            }

            Section {
                TextField("nome da sua rede", text: $staSsid)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if redeAberta {
                    Text("rede aberta — sem senha").foregroundStyle(.secondary)
                } else {
                    SecureField(fan.config.hasStaPass ? "definida — em branco mantém" : "sem senha",
                                text: $staPass)
                        .focused($focoSenha)
                }

                Button { listaAberta = true; fan.scanWifi() } label: {
                    HStack {
                        Text(fan.wifiScan == .running ? "Procurando redes…" : "Procurar redes")
                        Spacer()
                        if fan.wifiScan == .running { ProgressView() }
                    }
                }
                .disabled(ocupado)

                if listaAberta, case .done(let redes, _, _) = fan.wifiScan {
                    ForEach(redes) { rede in
                        Button { escolher(rede) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "wifi", variableValue: rede.bars)
                                    .foregroundStyle(.secondary)
                                Text(rede.ssid).foregroundStyle(.primary)
                                Spacer()
                                if rede.locked {
                                    Image(systemName: "lock.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if rede.ssid == staSsid {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Button { testar() } label: {
                    HStack {
                        Text(fan.wifiTest == .running ? "Testando…"
                             : (nadaMudou ? "Testar conexão" : "Salvar e testar conexão"))
                        Spacer()
                        if fan.wifiTest == .running { ProgressView() }
                    }
                }
                .disabled(staSsid.isEmpty || ocupado)
            } header: {
                Text("Rede de casa")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    rodapeBusca
                    rodapeTeste
                    Text("Com a rede de casa configurada, o ventilador atende em "
                         + "**\(mdns.isEmpty ? "ventilador" : mdns).local** de qualquer cômodo.")
                }
            }

            Section {
                TextField("Ventilador", text: $apSsid)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(fan.config.hasApPass ? "definida — em branco mantém" : "rede aberta",
                            text: $apPass)
                TextField("ventilador", text: $mdns)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Wi-Fi do próprio ventilador")
            } footer: {
                Text("A senha precisa de 8 caracteres ou mais. Em branco, a rede "
                     + "sobe aberta. Esta é a rede que funciona onde não há Wi-Fi nenhum.")
            }

            Section {
                SecureField(fan.config.hasToken ? "definido — em branco mantém" : "sem token",
                            text: $token)
            } header: {
                Text("Token da página web")
            } footer: {
                Text("Com token, as rotas de escrita da API exigem `?k=TOKEN`. "
                     + "Se você usa atalhos do iOS por URL, lembre de incluí-lo.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { fan.state.restoreOn },
                    set: { fan.setRestore($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voltar como estava")
                        Text(fan.state.restoreOn
                             ? "depois de faltar energia, religa na última velocidade"
                             : "depois de faltar energia, fica desligado")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(
                    get: { fan.state.wifiStaysOn },
                    set: { fan.setWifiStaysOn($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi permanente")
                        Text(fan.state.wifiStaysOn
                             ? "fica no ar sempre, inclusive depois de reiniciar"
                             : "cai sozinho após 20 min sem uso")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Comportamento")
            } footer: {
                Text("O temporizador também sobrevive a queda de energia e retoma "
                     + "de onde parou. Wi-Fi permanente é o que mantém "
                     + "**\(mdns.isEmpty ? "ventilador" : mdns).local** de pé para atalhos do iOS "
                     + "— ao custo de o Bluetooth ficar um pouco mais lento, porque "
                     + "os dois dividem o mesmo rádio.")
            }

            Section {
                Button("Salvar") { _ = salvar() }
                    .disabled(nadaMudou)
                Button("Reiniciar o ventilador") { fan.reboot(); precisaReiniciar = false }
                    .foregroundStyle(precisaReiniciar ? Color.orange : Color.accentColor)
            } footer: {
                if let erro = fan.lastError { Text(erro).foregroundStyle(.red) }
                else if let aviso { Text(aviso).foregroundStyle(.orange) }
                else if precisaReiniciar {
                    Text("Nome do Bluetooth e pareamento só valem depois de reiniciar.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button("Restaurar padrão de fábrica", role: .destructive) {
                    fan.setSetting(.factory, "")
                    aviso = "restaurado — o ventilador está reiniciando"
                }
            } footer: {
                Text("Apaga todos os ajustes gravados e volta ao que está no "
                     + "config.h do firmware, inclusive desligando o pareamento.")
            }
        }
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Pronto") { dismiss() }
            }
        }
        .onAppear { fan.lastError = nil; fan.refreshConfig(); carregar() }
        .onChange(of: fan.config) { _, _ in carregar() }
    }

    // MARK: rede de casa

    private var ocupado: Bool { fan.wifiScan == .running || fan.wifiTest == .running }

    private var redeAberta: Bool {
        guard let e = escolhida, e.ssid == staSsid else { return false }
        return !e.locked
    }

    private func escolher(_ rede: WifiNet) {
        escolhida = rede
        staSsid = rede.ssid
        listaAberta = false
        if rede.locked { focoSenha = true }       // já abre o teclado na senha
        else { staPass = ""; focoSenha = false }
    }

    private func testar() {
        // O teste usa o que está GRAVADO no ventilador. Se mudou algo, salva
        // antes: a fila do firmware só começa o teste depois de gravar tudo.
        if !nadaMudou { guard salvar() else { return } }
        fan.testWifi()
    }

    @ViewBuilder private var rodapeBusca: some View {
        // Falha da busca aparece sempre; o resumo da lista, só com ela aberta.
        switch fan.wifiScan {
        case .done(let redes, let ign, let cortadas) where listaAberta:
            if redes.isEmpty {
                Text("Nenhuma rede compatível perto do ventilador. Ele só enxerga 2,4 GHz.")
                    .foregroundStyle(.orange)
            } else {
                let extras = [
                    ign > 0 ? "\(ign) ignorada\(ign == 1 ? "" : "s") (oculta ou corporativa)" : nil,
                    cortadas > 0 ? "\(cortadas) mais fraca\(cortadas == 1 ? "" : "s") não coube\(cortadas == 1 ? "" : "ram")" : nil
                ].compactMap { $0 }
                Text("Sinal medido no ventilador, não no telefone. Só 2,4 GHz."
                     + (extras.isEmpty ? "" : " " + extras.joined(separator: " · ") + "."))
            }
        case .failed(let m):
            Text(m).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var rodapeTeste: some View {
        switch fan.wifiTest {
        case .ok(let ip, let rssi):
            Text("Conectou — IP \(ip), sinal \(rssi) dBm (\(qualidade(rssi))). "
                 + "Se o Wi-Fi do ventilador estava desligado, ele desliga de novo.")
                .foregroundStyle(.green)
        case .failed(let m):
            Text(m).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private func qualidade(_ rssi: Int) -> String {
        rssi >= -60 ? "bom" : (rssi >= -70 ? "razoável" : "fraco")
    }

    private var passkeyPlaceholder: String {
        fan.config.bleSecOn ? "ligado — em branco mantém" : "desligado — 6 dígitos para ligar"
    }

    private var nadaMudou: Bool {
        bleName == fan.config.bleName && staSsid == fan.config.staSsid
        && apSsid == fan.config.apSsid && mdns == fan.config.mdns
        && staPass.isEmpty && apPass.isEmpty && token.isEmpty && passkey.isEmpty
        && !(redeAberta && fan.config.hasStaPass)
    }

    private func carregar() {
        bleName = fan.config.bleName
        staSsid = fan.config.staSsid
        apSsid  = fan.config.apSsid
        mdns    = fan.config.mdns
    }

    /// false = não salvou nada (validação falhou).
    @discardableResult
    private func salvar() -> Bool {
        aviso = nil
        if !apPass.isEmpty && apPass.count < 8 {
            aviso = "a senha do Wi-Fi do ventilador precisa de 8 caracteres ou mais"
            return false
        }
        if !bleName.isEmpty && bleName != fan.config.bleName {
            fan.setSetting(.bleName, bleName); precisaReiniciar = true
        }
        if staSsid != fan.config.staSsid { fan.setSetting(.staSsid, staSsid) }
        if !staPass.isEmpty              { fan.setSetting(.staPass, staPass) }
        // Rede aberta escolhida na lista: a senha antiga tem de SAIR, senão o
        // ventilador tenta entrar numa rede aberta oferecendo senha.
        else if redeAberta && fan.config.hasStaPass { fan.setSetting(.staPass, "") }
        if !apSsid.isEmpty && apSsid != fan.config.apSsid { fan.setSetting(.apSsid, apSsid) }
        if !apPass.isEmpty               { fan.setSetting(.apPass, apPass) }
        if !mdns.isEmpty && mdns != fan.config.mdns { fan.setSetting(.mdns, mdns) }
        if !token.isEmpty                { fan.setSetting(.token, token) }
        if !passkey.isEmpty {
            fan.setSetting(.passkey, passkey); precisaReiniciar = true
        }
        staPass = ""; apPass = ""; token = ""; passkey = ""
        return true
    }
}
