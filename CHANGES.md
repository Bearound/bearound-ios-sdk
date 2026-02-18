# CHANGES — Migração para Service Data (UUID 0xBEAD)

## BluetoothManager.swift

### Novo método: `parseBeadServiceData(from:rssi:isConnectable:)`
Parseia o payload binário de 11 bytes (Little-Endian) do Service Data com UUID `0xBEAD` recebido via `CBAdvertisementDataServiceDataKey`:

| Offset | Bytes | Campo       | Tipo      |
|--------|-------|-------------|-----------|
| 0-1    | 2     | Firmware    | uint16 LE |
| 2-3    | 2     | Major       | uint16 LE |
| 4-5    | 2     | Minor       | uint16 LE |
| 6-7    | 2     | Motion      | uint16 LE |
| 8      | 1     | Temperature | int8      |
| 9-10   | 2     | Battery mV  | uint16 LE |

Retorna `(major, minor, BeaconMetadata)` ou `nil` se não presente/inválido.

### Reescrito: `centralManager(_:didDiscover:advertisementData:rssi:)`
Nova lógica de prioridade:
1. **Service Data BEAD** → extrai major, minor E metadata completa
2. **iBeacon manufacturer data (0x004C)** → extrai major, minor sem metadata (fallback se scan response não chegou)

Toda lógica baseada em Name (`"B:..."`) foi removida.

### Simplificado: `beginScan()`
Foreground e background agora usam o mesmo filtro `[beadServiceUUID]`. A única diferença é `allowDuplicates` (true em foreground, false em background). iOS entrega todos os dados do peripheral (incluindo manufacturer data) para peripherals que casam com o filtro de Service UUID.

### Removidos
- `parseBeaconNameWithMetadata(from:rssi:)` — parsing do nome `"B:firmware_major.minor_battery_movements_temperature"`
- `parseBeaconMetadata(from:)` — parsing de metadata a partir do nome
- `shouldProcessBeaconName(major:minor:)` — deduplicação separada para nome
- `lastSeenBeaconNames` — dicionário de deduplicação por nome
- `peripheralNameCache` — cache de nomes por peripheral UUID
- `serviceUUIDPeripherals` — set de peripherals conhecidos por Service UUID (não mais necessário pois o filtro de scan já garante)

### Deduplicação unificada
`shouldProcessBeacon(major:minor:)` agora usa chave `"major.minor"` para ambos os caminhos (Service Data e iBeacon).

### Mudanças nos campos
- **battery**: agora recebe millivolts (ex: 3269) em vez de porcentagem (0-100)
- **firmware**: agora recebe integer como string (ex: "1") em vez de versão semântica (ex: "2.1.0")

### Backward compatibility
Beacons com firmware antigo (Name-based) **não serão mais detectados** — intencional.
