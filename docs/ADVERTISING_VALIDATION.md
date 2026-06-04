# Checklist de validação de advertising — beacons Bearound (firmware/QA)

> **Não é tarefa de SDK.** É validação de **hardware/firmware** com sniffer. O SDK só consegue casar o filtro BLE se o advertising estiver montado corretamente. Se este checklist falhar, nenhuma mudança de código de SDK resolve.

## Por que isto importa

O olho Bluetooth (`BluetoothManager`) filtra o scan por **service UUID `0xBEAD` no pacote de advertising primário** (`scanForPeripherals(withServices: [CBUUID("BEAD")])` no iOS; `ScanFilter` por service UUID no Android).

Regra dura do iOS/Android: em **background o scan é passivo** (sem scan request). O sistema só entrega match se o `0xBEAD` estiver na **lista de Service UUIDs do ADV primário** — **não** basta estar:
- no **Service _Data_** (`0xBEAD` + payload), nem
- na **scan response** (que só chega em scan ativo / foreground).

Se o UUID estiver no lugar errado, a detecção BLE **funciona em foreground e falha silenciosamente em background** — exatamente o cenário "funciona no demo, não funciona no bolso com a tela bloqueada".

## O que o firmware precisa garantir

- [ ] **`0xBEAD` presente como _Service UUID_ no ADV primário** (AD type `0x02`/`0x03` — Incomplete/Complete List of 16-bit Service UUIDs), não só no Service Data (`0x16`).
- [ ] Frame **iBeacon** publicado em paralelo (UUID `E25B8D3C-947A-452F-A13F-589CB706D2E5`) — é o que o olho CoreLocation usa para acordar app terminado.
- [ ] Service Data `0xBEAD` mantido (carrega os metadados que o SDK lê via `didDiscover`).
- [ ] Intervalo de advertising compatível com detecção em background (recomendado ≤ ~1s; validar latência real).

## Validação com sniffer (nRF Sniffer / LightBlue / nRF Connect)

- [ ] Capturar o ADV primário e **confirmar `0xBEAD` na lista de Service UUIDs** (não apenas em Service Data).
- [ ] Confirmar o frame iBeacon (UUID/major/minor) num pacote separado.
- [ ] Medir o intervalo de advertising real.

## Matriz de detecção (rodar nos 4 estados, iOS e Android)

| Estado | iOS | Android |
|---|---|---|
| Foreground | [ ] detecta < 5s | [ ] detecta < 5s |
| Background (app aberto, tela ligada) | [ ] | [ ] |
| Background + tela bloqueada | [ ] | [ ] |
| Force-quit / app terminado | [ ] (só via olho CoreLocation — region enter) | [ ] (via foreground-service / scan registrado) |

## Notas de arquitetura (para quem interpretar os resultados)

- O **fallback iBeacon** no `didDiscover` (Prioridade 2) é **inalcançável** para pacotes que sejam *só* iBeacon — quem cobre o frame iBeacon é o **olho CoreLocation** (region monitoring), não o `CBCentralManager`. Por isso o `0xBEAD` no ADV primário é obrigatório para o olho Bluetooth funcionar.
- **iOS force-quit:** confirmado por captura de `bluetoothd` que o iOS remove o filtro BLE do kernel no swipe-up (`killed by user`). Detecção pós-force-quit depende **exclusivamente** do olho CoreLocation. Sem o frame iBeacon correto, não há recuperação.
- Se a detecção em background falhar **com o `0xBEAD` comprovadamente no ADV primário**, aí sim o problema é de SDK/SO — abrir investigação separada.
