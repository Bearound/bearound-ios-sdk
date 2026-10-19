# Visita por GPS: chegada e partida pela cerca

Vale a partir da 3.17.0. Descreve quando o SDK envia a chegada e a partida de uma visita
detectada por cerca de GPS (geofence), o que o app integrador precisa conceder e o bloco
`visit` que acompanha esses envios. A detecção por Wi-Fi está em
[Wi-Fi visit matching](../README.md#wi-fi-visit-matching).

## Requisitos

- Localização **Sempre** e **Precisa**. Com "Durante o uso" ou com a localização aproximada,
  a detecção de visita fica desligada e as regiões dela são removidas.
- `collectLocation` ligado (é o padrão).
- Detecção de visita habilitada para a conta e `startScanning()` chamado.

Nenhuma permissão nova e nenhum background mode novo em relação à 3.16.0.

`stopScanning()`, `collectLocation: false` ou a revogação de "Sempre" ou de "Precisa"
desligam a detecção e removem só as regiões do SDK. As regiões do app integrador nunca são
tocadas; identificadores e limite de regiões estão em
[Monitored regions and the 20-region limit](../README.md#monitored-regions-and-the-20-region-limit).

## Chegada

O SDK arma uma região circular por ambiente próximo (`bearound.visit.env.<environmentId>`,
raio mínimo de 100 m), com aviso de entrada e de saída.

- **Entrada na cerca.** O SDK pede um fix de localização e envia a chegada com a posição e a
  hora desse fix.
- **Cerca armada com o aparelho já dentro.** Nesse caso o iOS não entrega uma entrada, só o
  estado `.inside` da região. O SDK pede esse estado logo depois de armar cada cerca e trata
  `.inside` como uma entrada.
- **Uma chegada por estadia.** O iOS entrega o estado de novo a cada abertura do app. A
  estadia já reportada fica registrada no aparelho, então reabrir o app não gera outra
  chegada. O registro é limpo na saída da cerca, no estado `.outside`, quando a cerca deixa
  de ser monitorada e quando a detecção é desligada.
- **Passagem sem parada.** Se o aparelho sai da cerca antes de o fix chegar, nenhuma chegada
  é enviada. Se o fix falha, a estadia não é marcada e o próximo `.inside` tenta de novo.

## Partida

- **Saída da cerca.** A saída da cerca do ambiente da parada aberta envia a partida na hora
  da saída, com a posição e a precisão do fix da chegada (onde a estadia aconteceu, não um
  ponto na borda da cerca), e fecha a parada.
- A saída da cerca de outro ambiente não fecha a parada aberta.
- **CLVisit de reserva.** Sem saída da cerca, a partida do CLVisit fecha a parada. Uma saída
  que chega depois disso, ou um CLVisit que descreve uma parada já fechada, não envia nada:
  cada parada tem uma partida só.
- Uma parada aberta pela cerca que o CLVisit não confirma e que nenhuma saída fecha até o
  tempo mínimo de permanência do local mais 30 minutos é descartada no aparelho, sem
  partida.

## Visitas do iOS (CLVisit)

O SDK também usa as visitas que o iOS reporta. A chegada e a partida do CLVisit levam a
posição do CLVisit e `environmentId: null`, porque o CLVisit não nomeia um ambiente. A
partida do CLVisit de uma parada que a cerca abriu leva o ambiente dessa parada.

## Atualização a partir de versão anterior

Regiões monitoradas sobrevivem à atualização do app. Versões anteriores à 3.17.0 armavam as
cercas de ambiente só com aviso de entrada; a 3.17.0 encontra essas cercas e as arma de novo,
uma vez, com aviso de saída. Não há nada a fazer no app integrador.

## O que vai no payload

Cada chegada e cada partida é um envio próprio, com `beacons` vazio, `syncTrigger: "visit"`,
`location` com a posição e a hora real do evento (`source: "gnss"`; ausente numa parada só de
Wi-Fi) e o bloco `visit` no topo do payload, ao lado de `location`:

```json
"visit": {
  "kind": "arrival",
  "environmentId": "00000000-0000-0000-0000-000000000000",
  "source": "fence",
  "at": 1792000000000
}
```

| Campo | Valores |
|---|---|
| `kind` | `arrival` ou `departure` |
| `environmentId` | o ambiente que a cerca ou o Wi-Fi reconheceu; sempre presente, `null` numa parada de CLVisit |
| `source` | `fence` (entrada, estado `.inside` ou saída), `clvisit` ou `wifi` |
| `at` | epoch em milissegundos do fix ou da hora da parada; igual a `location.timestamp` quando há localização |

- O bloco é gravado com o evento na fila offline e reenviado como foi capturado, nunca com a
  hora do envio.
- Com `collectLocation` desligado na hora do envio, `location` e `visit` saem do payload. Com
  `collectWifi` desligado, sai também o bloco de um evento com `source: "wifi"`.
- O bloco é aditivo: nenhum campo existente do payload mudou.

## Como conferir no aparelho

No Console.app, com o aparelho conectado e filtrando pelo processo do app, as linhas do SDK
para uma visita por cerca são:

- `[BeAroundSDK] Visit fence <environmentId> reports inside: handled as an entry` (cerca
  armada com o aparelho dentro);
- `[BeAroundSDK] Visit arrival queued as <id> (fix at <hora>)`;
- `[BeAroundSDK] Visit fence <environmentId> exit: departure sent`;
- `[BeAroundSDK] Visit departure queued as <id> (fix at <hora>)`.

No `locationd`, o identificador da região é `bearound.visit.env.<environmentId>`. O iOS pode
levar alguns minutos para entregar a saída depois que o aparelho deixa a cerca.
