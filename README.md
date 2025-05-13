# 🐻 Bearound SDKs Documentation

Official SDKs for integrating Bearound's secure BLE beacon detection and indoor location technology.

---

## 📘 Documentação do Projeto de Beacon BLE

### Visão Geral

Este projeto implementa um sistema completo de beacon BLE usando o Adafruit nRF52840 Feather Express como transmissor (beacon) e um aplicativo iOS para detecção e sincronização com uma API.

### Componentes do Sistema

#### 1. Beacon Arduino (Adafruit nRF52840 Feather Express)

O beacon é configurado para transmitir um sinal iBeacon compatível com dispositivos iOS, contendo:

- UUID: `E25B8D3C-947A-452F-A13F-589CB706D2E5`
- Major: `0x0001`
- Minor: `0x0002`
- RSSI calibrado a 1m: `-59 dBm`
- Manufacturer ID: `0x004C` (Apple, para compatibilidade com iOS)

#### 2. Aplicativo iOS

O aplicativo iOS detecta o beacon configurado, notifica o usuário quando entra ou sai da região do beacon, e sincroniza o UUID do beacon e o IDFA do dispositivo com uma API.

**Funcionalidades:**

- Detecção de beacons usando `CoreLocation`
- Monitoramento de entrada/saída da região do beacon
- Notificações locais para eventos de entrada/saída
- Obtenção do IDFA (Identifier for Advertisers) do dispositivo
- Sincronização automática com API ao entrar na região
- Sincronização manual com API através de botão na interface

### Estrutura do Código

#### Código Arduino

O arquivo `adafruit_beacon.ino` contém o código para configurar o Adafruit nRF52840 como um beacon iBeacon. O código:

- Configura o UUID, Major e Minor do beacon
- Define a potência de transmissão e intervalo de advertising
- Configura o pacote de advertising no formato iBeacon
- Otimiza o consumo de energia desligando o LED e suspendendo o loop

#### Código iOS

O aplicativo iOS é composto por:

1. **BeaconDetector.swift**: Classe principal que gerencia a detecção de beacons

   - Implementa `CLLocationManagerDelegate` para monitorar beacons
   - Gerencia o ciclo de vida do monitoramento de beacons
   - Obtém o IDFA do dispositivo
   - Implementa a sincronização com API

2. **AppDelegate.swift**: Configura o aplicativo e gerencia notificações

   - Inicializa o detector de beacons
   - Configura as permissões de notificação
   - Gerencia os callbacks de eventos de beacon
   - Envia notificações locais

3. **ViewController.swift**: Implementa a interface do usuário

   - Exibe o status de monitoramento
   - Mostra a proximidade do beacon
   - Exibe informações do beacon (UUID) e do dispositivo (IDFA)
   - Permite sincronização manual com a API

4. **Main.storyboard**: Define o layout da interface do usuário

### Requisitos

#### Hardware

- Adafruit nRF52840 Feather Express

#### Software

- Arduino IDE com suporte para Adafruit nRF52
- Biblioteca Bluefruit para Arduino
- Xcode para compilar o aplicativo iOS
- iOS 13.0 ou superior no dispositivo de teste

### Configuração e Uso

#### Configuração do Beacon Arduino

1. Instale o suporte para Adafruit nRF52 no Arduino IDE
2. Abra o arquivo `adafruit_beacon.ino`
3. Carregue o código no Adafruit nRF52840 Feather Express
4. O beacon começará a transmitir automaticamente

#### Configuração do Aplicativo iOS

1. Abra o projeto no Xcode
2. Configure o `Info.plist` com as permissões necessárias:
   - `Privacy - Location Always and When In Use Usage Description`
   - `Privacy - Location When In Use Usage Description`
3. Compile e instale o aplicativo no dispositivo iOS
4. Conceda as permissões solicitadas
5. O aplicativo começará a monitorar o beacon automaticamente

### Personalização

#### Modificando o Beacon

Para alterar as propriedades do beacon, edite as seguintes constantes no arquivo `adafruit_beacon.ino`:

- `beaconUuid`: UUID do beacon
- `BEACON_MAJOR`: Valor Major do beacon
- `BEACON_MINOR`: Valor Minor do beacon
- `BEACON_RSSI`: RSSI calibrado a 1m
- `Bluefruit.setTxPower()`: Potência de transmissão

#### Configurando a API

Para configurar a sincronização com sua API, edite o método `syncWithAPI` na classe `BeaconDetector.swift`:

- Substitua a URL placeholder por sua URL real
- Ajuste o formato dos dados conforme necessário
- Implemente autenticação se necessário

### Notas Adicionais

- O beacon é configurado para transmitir continuamente para maximizar a detecção
- O aplicativo iOS está otimizado para economizar bateria monitorando regiões
- A sincronização com API ocorre automaticamente ao entrar na região do beacon
- O IDFA requer que o usuário não tenha limitado o rastreamento de anúncios nas configurações do iOS

---

## 🍏 bearound-ios-sdk

**Swift SDK for iOS — secure beacon proximity events and indoor location.**

### 📦 Installation

**Via Swift Package Manager:**

```swift
.package(url: "https://github.com/bearound/bearound-ios-sdk.git", from: "1.0.0")
```

**Or via CocoaPods:**

```ruby
pod 'BearoundSDK'
```

### ⚙️ Required Permissions

Add the following keys to `Info.plist`:

- `NSBluetoothAlwaysUsageDescription`
- `NSLocationWhenInUseUsageDescription`

### 🚀 Features

- Beacon scanning using CoreBluetooth + CoreLocation
- Geofence-based proximity detection
- AES-GCM encryption
- iOS 12+ support, macOS Catalyst compatible

### 🛠️ Usage

```swift
BeaconDetector.shared.startScanning { beacon in
    print("Detected \(beacon.identifier) at \(beacon.distance)m")
}
```

### 🔐 Security

- End-to-end encrypted payloads
- Minimal local processing
- No analytics or tracking

### 🧪 Testing

- Test with real BLE beacons or simulators
- Enable Location & Bluetooth in Settings
- Ensure `Info.plist` is configured properly

### 📄 License

MIT © Bearound
