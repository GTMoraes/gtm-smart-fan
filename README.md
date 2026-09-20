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

## Ícone (20/09/2026)

`Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` — desenho original,
ventilador de pedestal branco sobre gradiente azul, 1024 × 1024 sem
transparência (o iOS aplica a máscara arredondada sozinho). O `project.yml`
aponta para ele com `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.

> **Por que não um SF Symbol:** a licença do SF Symbols permite usar os símbolos
> na interface do app, mas **proíbe expressamente usá-los como ícone do app**.
> E, na prática, símbolo é glifo fino — fica ralo num ícone de 60 px. Por isso o
> desenho é próprio.

O gerador está em `ferramentas/icone.py` — rode e substitua o PNG se quiser
mexer nas cores ou no formato das pás.

### O formato do Contents.json importa (corrigido em 20/09/2026)

A primeira versão usava `"scale": "1x"` **sem** `"size"`. O `actool` não
reconhece isso como ícone de app, compila o catálogo sem reclamar, e o
`Info.plist` sai **sem `CFBundleIcons`** — que é exatamente o que o iOS lê. O
app instala com o ícone genérico de blueprint e nada no build avisa.

O formato correto, que é o que o próprio Xcode gera para um ícone único:

```json
{
  "images" : [
    { "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

`size` é obrigatório; `scale` não entra na forma de tamanho único.

Requisitos do PNG: **1024 × 1024, sem canal alfa, sem cantos arredondados** — o
iOS aplica a máscara sozinho.

### Cache de ícone do iOS

Reinstalar por cima costuma manter o ícone antigo na tela de início. **Apague o
app antes de reinstalar** quando estiver testando mudança de ícone.

## Por que os intents não têm parâmetro (20/09/2026)

A primeira versão usava um `@Parameter` de `AppEnum` customizado (`FanSpeed`):
uma ação "Definir velocidade" com uma lista. **O build passava, o app
instalava, e nenhuma ação aparecia no Atalhos.**

Causa: o `appintentsmetadataprocessor` falha em silêncio com tipos customizados
de parâmetro e não gera o diretório `Metadata.appintents` dentro do `.app`. Sem
ele, o iOS não tem o que registrar — e nada no build avisa.

A comparação que resolveu: o **ChargeSpeed**, mesmo autor, mesmo XcodeGen, mesmo
workflow, e até o mesmo `CODE_SIGNING_ALLOWED=NO` — funciona. E os intents dele
não têm parâmetro nenhum. Copiamos essa forma.

Resultado: oito intents sem parâmetro (velocidades 0–3, dois timers, cancelar
timer, ligar Wi-Fi), cada um retornando `ProvidesDialog` para a Siri ter o que
falar.

> Para reintroduzir um parâmetro no futuro: use **tipo primitivo** (`Int`,
> `String`, `Bool`), um de cada vez, e confira o passo
> *"Conferir ícone e App Intents no bundle"* no workflow **antes** de instalar.

## Se os atalhos não aparecerem no app Atalhos

O workflow agora tem um passo **"Conferir ícone e App Intents no bundle"** que
diz, em texto claro, se `Metadata.appintents` foi para dentro do `.app`. Esse
diretório é o que o iOS lê para registrar os intents — sem ele, nenhum atalho
aparece, por mais correto que o Swift esteja.

Se o passo disser **AUSENTE**, o problema é a extração de metadados no build, e
o log do `xcodebuild` aparece filtrado logo abaixo.

Se disser **presente** e mesmo assim não aparecer:

1. **Abra o app pelo menos uma vez** depois de instalar. O iOS só registra os
   App Shortcuts na primeira execução.
2. No app Atalhos, aba **Galeria**, role até o fim — os App Shortcuts aparecem
   agrupados por app. Ou, criando um atalho, toque em **Apps** e procure
   *Ventilador*.
3. Reinicie o iPhone. O índice de atalhos é um cache, e sideload não o invalida
   do mesmo jeito que uma instalação pela App Store.

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
