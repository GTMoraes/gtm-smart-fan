# App iOS — Ventilador

SwiftUI + CoreBluetooth. Fala BLE com o ventilador por padrão e cai para HTTP
se o Wi-Fi do ventilador estiver ligado e o Bluetooth fora de alcance.

## Estrutura

```
app-ios/
├── project.yml                      XcodeGen — gera o .xcodeproj no runner
├── Sources/
│   ├── VentiladorApp.swift          entry point
│   ├── FanController.swift          BLE (principal) + HTTP (fallback)
│   └── ContentView.swift            a interface
└── workflow-build-ipa.yml          → renomeie para .github/workflows/build-ipa.yml
```

## Como buildar (mesmo caminho do ChargeSpeed)

> **Atalho:** existe um `ventilador-app-repo.zip` com a estrutura já montada,
> incluindo o `.github/workflows/`. Descompacte e suba o conteúdo — não precisa
> renomear nada.

1. Crie um repositório e suba **o conteúdo desta pasta na raiz** — o
   `project.yml` precisa ficar na raiz, igual ao ChargeSpeed. Mova
   `workflow-build-ipa.yml` para `.github/workflows/build-ipa.yml`.
2. Actions → *Build unsigned IPA* → *Run workflow*.
3. O resumo do job traz o link do `.ipa` e o link `altstore://install?url=…`.
4. Instale pelo LiveContainer (ou numa das três vagas de sideload).

### Repositório público ou privado

Minutos de runner **macOS contam 10×** na cota gratuita. Num repositório
**privado**, os 2.000 min/mês viram ~200 min de macOS — o build leva 5 a 10 min,
então dá umas 20 a 40 compilações por mês. Num repositório **público**, o
Actions é gratuito e ilimitado. Não há segredo nenhum neste código.

## Correções aplicadas antes do primeiro build (18/09/2026)

O código nunca tinha passado por compilador. Revisão feita antes de queimar
minuto de runner:

- **`SWIFT_VERSION` era `"5.9"`** — valor inválido. O Xcode aceita só as versões
  de *linguagem* (`4.0`, `4.2`, `5.0`, `6.0`) e aborta com
  *"SWIFT_VERSION '5.9' is unsupported"*. Corrigido para **`"5.0"`**.
- **`SWIFT_STRICT_CONCURRENCY: minimal`** adicionado explicitamente. O
  `FanController` é `@MainActor` e conforma a `CBCentralManagerDelegate`, que
  não é isolado. Em modo Swift 5 isso é aviso; em Swift 6 vira erro. Fixar o
  modo evita depender do padrão da versão do Xcode do runner.
- **`UILaunchScreen: {}`** adicionado ao Info.plist. Sem uma launch screen
  declarada, o iOS roda o app em modo de compatibilidade, com letterbox.

Não há ícone de app — o build passa, o iPhone mostra o ícone em branco. Se
incomodar, é só acrescentar um `Assets.xcassets` depois.

Deployment target: iOS 17. Sem dependências externas, sem SPM, sem CocoaPods —
o build é só Xcode e CoreBluetooth.

## A ressalva do LiveContainer

No iOS, o texto de permissão de Bluetooth (`NSBluetoothAlwaysUsageDescription`)
vem do **Info.plist do app hospedeiro**. Um app rodando dentro do LiveContainer
herda as permissões declaradas pelo LiveContainer, não as do próprio app.

- Se o LiveContainer da sua versão declara Bluetooth: funciona direto.
- Se não declara: o iOS mata o app no momento em que o CoreBluetooth sobe, ou
  simplesmente nunca mostra o prompt e o scan não acha nada.

Nesse segundo caso, instale o Ventilador direto numa das três vagas de sideload
da conta gratuita. O app é pequeno e só precisa de renovação a cada 7 dias, que
a AltStore Classic no modo remoto já faz sozinha no seu arranjo atual.

Dá para checar antes: no Files, dentro do app do LiveContainer, procure
`NSBluetoothAlwaysUsageDescription` no Info.plist dele.

## Tela de ajustes e atalhos do iOS (19/09/2026)

- **`SettingsView.swift`** — tela de ajustes, aberta pela engrenagem no canto.
  Nome BLE, passkey de pareamento, rede de casa, AP próprio, mDNS, token, e
  restaurar padrão de fábrica. Tudo mora no ventilador (NVS), não no telefone:
  trocar de celular não perde nada, e a página web mostra os mesmos valores.
  Senhas nunca são lidas de volta — só se existem ou não.

- **`Intents.swift`** — App Intents para o app Atalhos: definir velocidade,
  desligar, programar desligamento e ligar/desligar o Wi-Fi. Entram em
  automações, Siri, botão de ação e widget de Controle.

  > ⚠️ **App Intents provavelmente NÃO aparecem pelo LiveContainer.** O sistema
  > registra intents a partir dos metadados do app *instalado*, e pelo
  > LiveContainer quem está instalado é o LiveContainer. É o mesmo problema da
  > permissão de Bluetooth. Para os atalhos funcionarem, o app precisa ir numa
  > vaga de sideload de verdade. O código fica pronto até lá — não atrapalha
  > nada rodando no LiveContainer.

  Enquanto isso, o caminho que funciona hoje é o app **Atalhos** com a ação
  *Obter conteúdo de URL* apontando para a API HTTP. Ver `PROTOCOLO.md`.

- `UIBackgroundModes: bluetooth-central` foi declarado no `project.yml` para o
  caso de um intent disparar com o app fechado.

## Detalhes de implementação que importam

- O scan filtra pelo UUID de serviço, então o app só enxerga o ventilador.
- Ao desconectar, volta a escanear sozinho; o firmware volta a anunciar no
  `onDisconnect`. Andar para longe e voltar reconecta sem tocar em nada.
- O polling HTTP só acontece quando o BLE **não** está conectado — em uso
  normal, o app nunca faz requisição de rede.
- O campo "Host Wi-Fi" no rodapé serve para trocar entre `ventilador.local`
  (ventilador na rede de casa) e `192.168.4.1` (iPhone no AP do ventilador).
- O toggle de Wi-Fi só aparece conectado via Bluetooth, porque é a única via
  que funciona justamente quando o Wi-Fi está desligado.
