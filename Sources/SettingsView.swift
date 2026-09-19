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
                SecureField(fan.config.hasStaPass ? "definida — em branco mantém" : "sem senha",
                            text: $staPass)
            } header: {
                Text("Rede de casa")
            } footer: {
                Text("Com a rede de casa configurada, o ventilador atende em "
                     + "**\(mdns.isEmpty ? "ventilador" : mdns).local** de qualquer cômodo.")
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
                Button("Salvar") { salvar() }
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

    private var passkeyPlaceholder: String {
        fan.config.bleSecOn ? "ligado — em branco mantém" : "desligado — 6 dígitos para ligar"
    }

    private var nadaMudou: Bool {
        bleName == fan.config.bleName && staSsid == fan.config.staSsid
        && apSsid == fan.config.apSsid && mdns == fan.config.mdns
        && staPass.isEmpty && apPass.isEmpty && token.isEmpty && passkey.isEmpty
    }

    private func carregar() {
        bleName = fan.config.bleName
        staSsid = fan.config.staSsid
        apSsid  = fan.config.apSsid
        mdns    = fan.config.mdns
    }

    private func salvar() {
        aviso = nil
        if !apPass.isEmpty && apPass.count < 8 {
            aviso = "a senha do Wi-Fi do ventilador precisa de 8 caracteres ou mais"
            return
        }
        if !bleName.isEmpty && bleName != fan.config.bleName {
            fan.setSetting(.bleName, bleName); precisaReiniciar = true
        }
        if staSsid != fan.config.staSsid { fan.setSetting(.staSsid, staSsid) }
        if !staPass.isEmpty              { fan.setSetting(.staPass, staPass) }
        if !apSsid.isEmpty && apSsid != fan.config.apSsid { fan.setSetting(.apSsid, apSsid) }
        if !apPass.isEmpty               { fan.setSetting(.apPass, apPass) }
        if !mdns.isEmpty && mdns != fan.config.mdns { fan.setSetting(.mdns, mdns) }
        if !token.isEmpty                { fan.setSetting(.token, token) }
        if !passkey.isEmpty {
            fan.setSetting(.passkey, passkey); precisaReiniciar = true
        }
        staPass = ""; apPass = ""; token = ""; passkey = ""
    }
}
