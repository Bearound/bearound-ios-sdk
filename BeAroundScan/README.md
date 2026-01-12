# BeAroundScan - App de Exemplo

App de exemplo para demonstrar todas as funcionalidades do **BearoundSDK v2.1.0**.

## 🎯 Funcionalidades

### ✨ Tela Principal
- ✅ Status de permissões (Localização, Bluetooth, Notificações)
- ✅ Informações do scan em tempo real
- ✅ Lista de beacons detectados com proximidade e RSSI
- ✅ Ordenação por proximidade ou ID
- ✅ Botão de iniciar/parar scan
- ✅ Acesso às configurações

### ⚙️ Tela de Configurações (NOVO v2.1.0)

Permite configurar todos os parâmetros do SDK:

#### 📡 Intervalos de Scan
- **Foreground**: 5s até 60s (incrementos de 5s)
  - Default: 15s
  - Controla frequência de scan quando app está ativo
  
- **Background**: 60s, 90s ou 120s
  - Default: 60s
  - Controla frequência de scan em background

#### 📦 Fila de Retry
- **Small**: 50 payloads
- **Medium**: 100 payloads (default)
- **Large**: 200 payloads
- **XLarge**: 500 payloads

Controla quantos payloads são guardados quando a API falha.

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
```

### Detecção Rápida
```
Foreground: 5s
Background: 60s
Periodic Scanning: OFF
```

### Balanceado (Recomendado)
```
Foreground: 15s
Background: 60s
Periodic Scanning: ON
Queue: Medium
```

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
