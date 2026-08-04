# BeAroundScan - App de Exemplo

App de exemplo para demonstrar as funcionalidades do **BearoundSDK**.

## 🚀 Buildar e instalar num aparelho

```bash
./install_example.sh              # da raiz do repo, no primeiro aparelho disponível
./install_example.sh <UDID>       # num aparelho específico
./install_example.sh --list       # listar aparelhos
```

O script reconstrói o XCFramework quando o fonte do SDK mudou, builda, confere assinatura
e versão, e só então instala — imprimindo no fim qual SDK foi para o aparelho.

> ⚠️ **Este app NÃO compila o SDK.** Ele linka o artefato pré-construído em
> `../build/BearoundSDK.xcframework`. Alterar código do SDK e apertar Build no Xcode
> geraria um app com o SDK **antigo** dentro, em silêncio — foi assim que um teste de campo
> chegou a "validar" uma correção que nunca esteve no binário.
>
> Por isso existe a build phase **"Verificar frescor do XCFramework"**: ela roda antes de
> compilar e **falha o build** se qualquer `.swift` do SDK for mais novo que o artefato,
> dizendo qual arquivo e o que fazer. Todo build também imprime
> `note: BearoundSDK embarcado neste build: X.Y.Z`.
>
> Se precisar reinstalar a phase (projeto recriado, merge que a perdeu):
> `scripts/add-freshness-guard.sh`
>
> Para conferir o que está rodando de fato num aparelho, a fonte de verdade é o payload:
> o campo `sdk.version` lê o `CFBundleShortVersionString` do framework embarcado. A tela de
> Ajustes do app mostra o mesmo valor.

## 🎯 Funcionalidades

### ✨ Tela Principal
- ✅ Status de permissões (Localização, Bluetooth, Notificações)
- ✅ Informações do scan em tempo real
- ✅ Lista de beacons detectados com proximidade e RSSI
- ✅ Ordenação por proximidade ou ID
- ✅ Botão de iniciar/parar scan
- ✅ Acesso às configurações

### ⚙️ Tela de Configurações

Permite configurar todos os parâmetros do SDK:

#### 📡 Intervalos de Scan
- **Foreground**: 5s até 60s (incrementos de 5s)
  - Default: 15s
  - Controla frequência de sync com API quando app está ativo
  
- **Background**: 15s, 30s, 60s, 90s ou 120s
  - Default: 30s
  - Controla frequência de sync com API em background
  - Nota: Ranging (detecção) é sempre contínuo em background, o interval controla apenas quando envia para a API

#### 📦 Fila de Retry
- **Small**: 50 batches
- **Medium**: 100 batches (default)
- **Large**: 200 batches
- **XLarge**: 500 batches

Controla quantos batches de requisições falhadas são guardados. Cada batch contém múltiplos beacons de uma única sincronização.

#### 🔧 Funcionalidades
- **Bluetooth Scanning**: Coleta metadados dos beacons (bateria, firmware, temperatura)
- **Periodic Scanning**: Economiza bateria ligando/desligando o scan em ciclos

### 📊 Informações em Tempo Real

O app mostra:
- Modo de scan (Periódico ou Contínuo)
- Intervalo de sync atual
- Duração do scan
- Tempo de pausa (se periódico)
- Countdown até próxima sincronização
- Status do ranging (Ativo/Pausado)

## 🚀 Como Usar

### 1. Configurar o Token

Edite `BeaconViewModel.swift` e altere o token:

```swift
BeAroundSDK.shared.configure(
    businessToken: "SEU_TOKEN_AQUI",  // ← Altere aqui
    // ... outras configurações
)
```

### 2. Executar o App

```bash
# Abrir workspace (usa CocoaPods)
cd BeAroundScan
open BeAroundScan.xcworkspace

# Ou usar o script
./open_xcode.sh
```

### 3. Testar Configurações

1. Toque no ícone de engrenagem (⚙️) no canto superior direito
2. Ajuste os intervalos de scan
3. Configure o tamanho da fila
4. Ative/desative funcionalidades
5. Toque em "Aplicar Configurações"

O SDK será reconfigurado com os novos parâmetros!

## 📱 Requisitos

- iOS 13.0+
- Xcode 14.0+
- Swift 5.0+
- Permissões:
  - Localização (Always)
  - Bluetooth
  - Notificações (opcional)

## 🔍 Testando Diferentes Configurações

### Economia Máxima de Bateria
```
Foreground: 60s
Background: 120s
Periodic Scanning: ON
Queue: Medium
```

### Sync Rápido (Dev/Debug)
```
Foreground: 5s
Background: 15s
Periodic Scanning: OFF
Queue: Large
```

### Balanceado (Recomendado - Default)
```
Foreground: 15s
Background: 30s
Periodic Scanning: ON
Queue: Medium
```

**Nota Importante:**
- Em background, o **ranging (detecção) é sempre contínuo**
- O interval controla apenas a **frequência de sync com a API**
- Background 15s: sync muito rápido mas consome mais bateria
- Background 30s: sync balanceado (recomendado - default)
- Background 60s+: sync lento mas ótima economia de bateria

## 📝 Notas

- **Periodic Scanning** é automaticamente desativado em background (limitação do iOS)
- **Bluetooth Scanning** requer que o Bluetooth esteja ligado
- **Background scanning** requer permissão "Always" de localização
- O app mostra notificações quando detecta beacons pela primeira vez

## 🐛 Debug

O app imprime logs detalhados no console do Xcode:
- Configurações aplicadas
- Beacons detectados
- Mudanças de estado
- Erros da API

## 📚 Documentação

Para mais informações sobre o SDK, consulte:
- [README principal](../README.md)
- [CHANGELOG](../CHANGELOG.md)
- [Documentação da API](../BearoundSDK/BearoundSDK.docc/BearoundSDK.md)
