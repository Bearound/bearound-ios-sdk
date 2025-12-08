# Changelog

All notable changes to the BeAroundSDK for iOS.

## [1.2.0] - 2025-12-08

### Added
- **DeviceInfoService**: Novo serviço singleton para coleta abrangente de informações do dispositivo
  - Informações do SDK (versão, plataforma, app ID, build)
  - Informações completas do dispositivo do usuário:
    - Fabricante, modelo, OS, versão do OS
    - Timestamp, timezone
    - Nível de bateria, status de carregamento
    - Modo de economia de energia
    - Estado do Bluetooth
    - Permissões de localização e precisão
    - Permissões de notificações
    - Tipo de rede (WiFi, Cellular, Ethernet)
    - Geração celular (2G, 3G, 4G, 5G)
    - Status de roaming
    - Informações de memória RAM
    - Resolução da tela
    - Advertising ID (IDFA) e status de tracking
    - Estado do app (foreground/background)
    - Tempo de atividade do app
    - Detecção de cold start
  - Contexto do scan:
    - RSSI (força do sinal)
    - TX Power
    - Distância aproximada em metros
    - ID da sessão de scan
    - Timestamp da detecção

- **IngestPayload**: Novo modelo de dados estruturado para o endpoint de ingest
  - `BeaconPayload`: Representa um beacon individual
  - `SDKInfo`: Informações do SDK
  - `UserDeviceInfo`: Informações completas do dispositivo
  - `ScanContext`: Contexto do scan de beacons

- **Novos métodos públicos no Bearound SDK**:
  - `createIngestPayload(for:sdkVersion:)`: Cria um payload completo de ingest
  - `sendBeaconsWithFullInfo(_:completion:)`: Envia beacons com telemetria completa

### Changed
- **APIService**: 
  - Removido `PostData` legado (não mantemos mais compatibilidade com versões antigas)
  - Removido método `sendBeacons(_:completion:)` legado
  - Mantido apenas `sendIngestPayload(_:completion:)` para o novo formato

- **BearoundSDK**:
  - Método interno `sendBeacons(type:_:)` agora usa o novo formato `IngestPayload`
  - Todas as comunicações com a API agora incluem telemetria completa do dispositivo

### Removed
- `PostData` struct (formato legado descontinuado)
- Método `sendBeacons(_:completion:)` do APIService

### Migration Guide

Se você estava usando a API legada, atualize seu código da seguinte forma:

#### Antes (formato legado - não funciona mais):
```swift
// Este código não funciona mais
let postData = PostData(
    deviceType: "iOS",
    clientToken: token,
    sdkVersion: "1.1.0",
    idfa: idfa,
    eventType: "enter",
    appState: "foreground",
    beacons: beacons
)
```

#### Agora (novo formato):
```swift
// Opção 1: Usar o método de conveniência (recomendado)
await sdk.sendBeaconsWithFullInfo(beacons) { result in
    switch result {
    case .success(let data):
        print("Beacons enviados com sucesso")
    case .failure(let error):
        print("Erro: \(error)")
    }
}

// Opção 2: Criar o payload manualmente
let payload = await sdk.createIngestPayload(for: beacons)
// Use o payload como necessário
```

### Technical Details

#### DeviceInfoService - Novas funcionalidades:
```swift
// Singleton para acesso global
let service = DeviceInfoService.shared

// Obter informações do SDK
let sdkInfo = service.getSDKInfo(version: "1.2.0")

// Obter informações do dispositivo (async)
let deviceInfo = await service.getUserDeviceInfo()

// Criar contexto de scan
let scanContext = service.createScanContext(
    rssi: -63,
    txPower: -59,
    approxDistanceMeters: 1.8
)

// Gerar novo ID de sessão de scan
service.generateNewScanSession()

// Marcar que o cold start terminou
service.markWarmStart()
```

#### Formato do Payload JSON:
O novo formato enviado ao endpoint `/ingest`:

```json
{
  "beacons": [
    {
      "uuid": "E25B8D3C-947A-452F-A13F-589CB706D2E5",
      "name": "B:1.0_1000.2000_100_0_20"
    }
  ],
  "sdk": {
    "version": "1.2.0",
    "platform": "ios",
    "appId": "com.example.app",
    "build": 210
  },
  "userDevice": {
    "manufacturer": "Apple",
    "model": "iPhone 13",
    "os": "ios",
    "osVersion": "17.2",
    "timestamp": 1735940400000,
    "timezone": "America/Sao_Paulo",
    "batteryLevel": 0.78,
    "isCharging": false,
    "lowPowerMode": false,
    "bluetoothState": "on",
    "locationPermission": "authorized_when_in_use",
    "locationAccuracy": "full",
    "notificationsPermission": "authorized",
    "networkType": "wifi",
    "cellularGeneration": "4g",
    "ramTotalMb": 4096,
    "ramAvailableMb": 1280,
    "screenWidth": 1170,
    "screenHeight": 2532,
    "advertisingId": "...",
    "adTrackingEnabled": true,
    "appInForeground": true,
    "appUptimeMs": 12345,
    "coldStart": false
  },
  "scanContext": {
    "rssi": -63,
    "txPower": -59,
    "approxDistanceMeters": 1.8,
    "scanSessionId": "scan_98DF10",
    "detectedAt": 1735940400000
  }
}
```

### Breaking Changes
⚠️ **ATENÇÃO**: Esta versão contém breaking changes!

1. O struct `PostData` foi removido
2. O método `APIService.sendBeacons(_:completion:)` foi removido
3. Não há mais compatibilidade com o formato legado de payload

Se você precisa migrar de versões anteriores, você **DEVE** atualizar seu código para usar o novo formato `IngestPayload`.

### Requirements
- iOS 13.0+
- Swift 5.0+
- Xcode 11.0+

### Dependencies
- CoreLocation
- CoreBluetooth
- AdSupport
- AppTrackingTransparency
- Network
- CoreTelephony
- UserNotifications
