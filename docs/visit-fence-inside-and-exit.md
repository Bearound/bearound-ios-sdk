# Visita por GPS: cerca armada com o aparelho dentro, e saída da cerca

Origem: teste de campo de 17/10/2026, iPhone 17 Pro Max com iOS 27.2, zona
"Teste geofence 6 - Via Rovai" (env `4450416f`, conta BeAround). O `locationd` confirmou a
cerca armada (2 cercas, `RegionMonitoringSetupCompleted`), mas ela foi armada com o dono já
dentro: nenhuma chegada saiu. Isso expôs as duas lacunas abaixo.

## O que mudou no iOS

**Lacuna 1, armada com o aparelho dentro.** Ao armar uma região com o aparelho já dentro, o
iOS entrega o estado `.inside` (`kCLConnectionMessageRegionState` no log do `locationd`) e
nunca uma entrada. O `VisitMonitor` só reagia a `didEnterRegion`. Agora:

- o adaptador pede o estado de toda cerca de ambiente que acaba de armar
  (`requestState(for:)` em `didStartMonitoringFor`), porque a Apple só documenta o estado
  para uma transição ou para esse pedido;
- `.inside` de uma cerca de ambiente segue o mesmo caminho da entrada: respeita
  `isFenceArrivalCovered` e `canReportVisits`, guarda `pendingArrivalEnvironmentId` e chama
  `requestLocation`; a chegada sai com a hora do fix;
- o iOS reentrega o estado de toda região a cada abertura do app. Para não abrir a mesma
  estadia de novo, a estadia já reportada fica persistida (`reportedFenceStays`, por
  ambiente). Ela só é marcada quando a chegada saiu (ou já estava coberta pela parada
  aberta): um fix que falhou não consome o estado, e o próximo `.inside` tenta de novo.
  A marca cai na saída, no estado `.outside`, quando a cerca é desarmada (troca de lista)
  e no teardown;
- entrada e `.inside` da mesma travessia chegam juntos: pedem um fix só.

**Lacuna 2, saída só por CLVisit.** `didExitRegion` ignorava as cercas de ambiente, e elas
nem eram armadas com `notifyOnExit`. Uma parada aberta pela cerca esperava o CLVisit para
fechar; um drive-by era descartado localmente após minDwell + 30 min sem partida, e o
servidor via uma chegada que nunca fechava. Agora:

- as cercas de ambiente são armadas com `notifyOnExit = true`. Regiões sobrevivem à
  atualização do app: uma cerca armada por versão anterior (só entrada) é rearmada uma vez
  pelo `RegionBudget`;
- a saída da cerca do ambiente da parada aberta envia a partida na hora da saída e na
  posição e precisão do fix da chegada (onde a estadia foi, como faz a partida do CLVisit e a
  do Android), com os access points que a parada acumulou, e fecha a parada
  (`lastDepartureAt` = hora da saída). Não é um fix na borda da cerca;
- saída de outro ambiente não fecha a parada; parada só de Wi-Fi continua com o matcher;
- saída antes do fix da chegada cancela a chegada (passou sem parar);
- o CLVisit continua de reserva: sem saída, a partida dele fecha a parada, e uma saída
  tardia não manda nada. Um CLVisit de partida que chega depois da saída e descreve a
  parada já fechada (chegada dele <= `lastDepartureAt`) é descartado, antes ou depois da
  hora da saída.

Resíduo conhecido, sem mudança: uma parada aberta pela cerca que passa de minDwell + 30 min
sem nenhum CLVisit confirmar ainda é descartada localmente, e a saída posterior não tem o
que fechar. O servidor fecha essa sessão pelo timeout.

## O que chega ao ingest (contrato atual)

Medido no payload que chegou à produção em 17/10 12:27:08 e no `beacon-ingest` origin/main
`d5f1e0d`:

- o payload de visita é um `/ingest` comum: `beacons` vazio, `device`, `location`, `sdk`,
  `syncTrigger: "visit"`, `wifis`. **Não leva `kind` (chegada/partida) nem
  `environmentId`**: `sendVisitEvent` grava só o `UserDevice` com a localização do evento.
  Para o servidor, chegada e partida são o mesmo tipo de fato: "o aparelho estava neste
  ponto nesta hora";
- o ambiente sai só da geometria (`classifyEnvironmentByGnss`, log `[GnssAnchor]`). Um fix
  sem `accuracy` vale 100 m (`GNSS_MISSING_ACCURACY_METERS`); numa área desenhada, o círculo
  inteiro tem de caber dentro (`GNSS_AREA_EDGE_FACTOR` 1.0). Por isso a partida repete a
  precisão da chegada. **O build f77791b, instalado no iPhone do dono em 17/10 12:25:33,
  manda a partida sem `accuracy`**: nesse build ela só ancora num ambiente de ponto (150 m)
  ou numa área com o fix a 100 m ou mais da borda. O commit seguinte corrige isso;
- a sessão usa a hora de captura: `startedAt` no primeiro fix, `lastActivityAt` sobe com a
  hora do fix (nunca volta). Quem fecha é o worker de inatividade, pela hora de
  **recebimento**, com `sessionTimeoutMinutes` do business (padrão 30 min);
- consequência: uma partida que chega dentro do timeout estende a sessão até a hora da
  saída (duração certa). Numa estadia mais longa que o timeout sem nenhum payload no meio,
  a sessão da chegada fecha com permanência perto de zero, e a partida abre uma segunda
  sessão de um ponto só. Isso já valia para a partida do CLVisit; a saída da cerca só torna
  a partida mais frequente. Não verifiquei se outro payload com fix (heartbeat) mantém a
  sessão viva durante a estadia.

## Paridade com o Android (registro, sem mudança)

`bearound-android-sdk`, `NativeGeofenceVisitDetector` (origin/main `b19b880`):

| | iOS (este branch) | Android (cerca nativa) |
|---|---|---|
| Chegada | na entrada ou no `.inside` ao armar, após um fix | só no `GEOFENCE_TRANSITION_DWELL`, loitering delay = `minDwellMinutes` (padrão 5) |
| Hora da chegada | fix logo após a entrada | fix do DWELL: entrada + minDwell |
| Já dentro ao registrar | `.inside` via `requestState` | `INITIAL_TRIGGER_DWELL`: o dwell conta |
| ENTER | é a chegada | só dispara rodada de Wi-Fi, nunca chegada |
| Drive-by | chegada + partida (fechada pela saída) | nada |
| Partida | saída da cerca, ou CLVisit de reserva | `GEOFENCE_TRANSITION_EXIT` do mesmo ambiente |
| Posição/hora da partida | posição da parada, hora da entrega da saída | posição da parada, hora do fix da saída |

Consequência: para a mesma passagem rápida em frente a uma loja com cerca, o iOS produz uma
sessão GNSS curta (chegada e partida a poucos minutos) e o Android não produz nada.

## Decisão aberta para o dono

**O iOS deve continuar mandando a chegada na entrada da cerca, ou esperar minDwell como o
Android?**

- **A. Manter na entrada (estado atual deste branch).** Chegada imediata, útil para presença
  ao vivo. Todo drive-by vira uma sessão GNSS curta só no iOS; o filtro de permanência
  teria de existir no servidor, e hoje não sei se existe.
- **B. Confirmar a permanência no aparelho antes de enviar.** O iOS não tem timer confiável
  em background, então a confirmação viria de três fontes: CLVisit de chegada, um despertar
  qualquer depois de minDwell com o aparelho ainda dentro, ou a saída depois de minDwell
  (manda chegada datada na entrada + partida). Drive-by não produz nada, igual ao Android,
  e a chegada fica datada na entrada (mais fiel que o Android). Custo: sem CLVisit, a
  chegada pode só chegar ao servidor junto com a partida.

Recomendação: B. Por quê: os dois SDKs passam a emitir a mesma coisa para a mesma estadia,
e o dado sai limpo da origem em vez de depender de um filtro no servidor que teria de saber
a plataforma. Alternativa considerada: A, descartada porque distorce a comparação entre
plataformas a cada drive-by. A decisão é do dono; este branch não muda o momento da chegada.

**Contrato SDK + ingest: o payload de visita deve dizer o que é?** Hoje o servidor não
distingue chegada de partida e não recebe o ambiente que o aparelho reconheceu (seção "O que
chega ao ingest").

- **C. Manter o contrato.** Nada muda nos SDKs nem no ingest. Estadias mais longas que o
  timeout continuam virando duas sessões de permanência quase zero.
- **D. Bloco opcional `visit` no payload**: `kind` (`arrival`/`departure`), `environmentId`
  e a fonte (`fence`, `clvisit`, `wifi`). O ingest antigo ignora o campo. O ingest novo
  usa a partida para fechar a sessão daquele ambiente com `ended` = hora da partida, mesmo
  depois do timeout, em vez de abrir outra; e usa `environmentId` como pista quando a
  geometria fica ambígua.

Recomendação: D. Por quê: a partida existe justamente para fechar a sessão, e sem `kind` o
servidor não tem como usá-la para isso; o campo é aditivo e não quebra nenhum consumidor.
Alternativa considerada: o SDK mandar fixes periódicos durante a estadia para manter a
sessão viva, descartada porque o iOS não acorda o app de forma confiável em background
sem um evento de localização. Mexe no contrato de dois repos (SDKs e `beacon-ingest`):
pede decisão do dono antes de qualquer código.

**Área desenhada: o círculo que o aparelho arma não é a área que o ingest ancora.** Medido
na viagem de 17/10 com f77791b: a chegada na entrada da zona 7 (env `2a83de24`, quadrado de
300 x 300 m) saiu às 12:53:39 com fix a 199 m do centro e precisão de 8 m, e o ingest gravou
`env=unknown`. Para um polígono a API manda `rings` mais o círculo circunscrito
(`center`, `radiusMeters`); o SDK arma só o círculo (212 m), o ingest ancora pelo polígono
(meia aresta de 150 m). Num quadrado a diferença chega a 41% do raio no meio das arestas.
A partida herda a posição da chegada, então também não ancora.

O ponto que decide: o fix da chegada é tirado no instante da entrada, ou seja, na borda da
cerca. Com `GNSS_AREA_EDGE_FACTOR` 1.0 o ingest exige o círculo de precisão inteiro dentro
da área, e um fix na borda nunca passa. Trocar o círculo do aparelho não resolve sozinho.

- **E1. Armar o círculo inscrito no aparelho.** O fix da entrada cai na aresta do polígono
  e ainda falha a guarda de borda; os cantos da área deixam de disparar. Só funcionaria
  encolhendo mais o círculo pela precisão esperada, perdendo mais detecção.
- **E2. O ingest aceita a pista do SDK para payload `visit`.** Com o bloco `visit` da opção
  D, o ingest atribui ao `environmentId` que o aparelho reconheceu quando o fix está dentro
  do círculo armado mais a precisão, gravando a origem como `fence` (separada de `gnss`),
  para que a regra de faturamento continue decidindo o que conta.
- **E3. Posição da chegada vinda de dentro.** Com a opção B, a chegada confirmada pelo
  CLVisit usa a coordenada do CLVisit (o centro da estadia), que cai dentro da área. Sem
  CLVisit, continua o fix da borda.

Recomendação: E2, junto com D. Por quê: o aparelho já sabe qual cerca disparou e o fix da
entrada está na borda por construção; nenhuma escolha de raio no aparelho faz a guarda de
borda do polígono passar. Alternativa considerada: E1, descartada porque perde os cantos e
mesmo assim falha a guarda. E3 vale como complemento se o dono escolher B.

## Protocolo de teste de campo

Aparelho: o mesmo iPhone 17 Pro Max (iOS 27.2), localização **Sempre** e **Precisa**,
zona "Teste geofence 6 - Via Rovai". Identificador da região: `bearound.visit.env.<environmentId>`.

Preparação:

1. Instalar com `./install_example.sh <UDID>` a partir deste worktree (o exemplo não compila
   o SDK; ver CLAUDE.md). A versão continua 3.16.0: conferir o fingerprint em
   `build/example-build-proof.json`, não a versão.
2. Console.app com o iPhone conectado, filtros: processo `BeAround Scan` e `locationd`.
   Linhas que importam: `[BeAroundSDK] Visit fence`, `Visit arrival queued`,
   `Visit departure queued`, `RegionMonitoringSetupCompleted`, `kCLConnectionMessageRegionState`.

Roteiro:

1. **Armada com o aparelho dentro (lacuna 1).** Dentro da zona, apagar o app (remove as
   regiões), instalar e abrir, conceder as permissões. Esperado: região armada, estado
   `.inside`, `Visit fence ... reports inside: handled as an entry`, e **uma**
   `Visit arrival queued`.
2. **Reabertura não duplica.** Ainda dentro: fechar o app pelo app switcher e abrir de novo,
   duas vezes. Esperado: nenhuma nova `Visit arrival queued`.
3. **Saída manda a partida (lacuna 2).** Sair andando ou de carro até uns 300 m além da borda
   e esperar até a saída chegar (o iOS pode levar alguns minutos). Esperado:
   `Visit fence ... exit: departure sent` e `Visit departure queued`, com a posição da
   chegada e a hora da saída. No ingest a partida chega como mais um payload `visit`, sem
   marca de partida: confira `location.timestamp` (hora da saída) e se houve
   `[GnssAnchor] ... env=` para ela. No build f77791b ela vai sem `accuracy` (log
   `acc=?m`) e pode não ancorar; isso é o defeito descrito acima, não falha do iOS.
4. **Volta é nova chegada.** Voltar à zona depois de 10 min ou mais. Esperado: entrada e uma
   chegada nova.
5. **CLVisit não duplica.** Ficar 20 min dentro (o CLVisit costuma confirmar), sair como no
   passo 3. Esperado: exatamente uma partida no total, e nenhuma chegada extra quando o
   CLVisit de partida chegar depois.
6. **Atualização sobre build anterior.** Num aparelho com o build anterior e cercas já
   armadas, instalar este build sem apagar o app. Esperado: `RegionMonitoringSetupCompleted`
   de novo para as cercas de ambiente (rearmadas com saída), e o passo 3 funcionando.

No servidor, para cada passo: payload `syncTrigger: "visit"` do aparelho, ancorado ao env
`4450416f`, com `device.location.timestamp` igual à hora do fix (chegada) ou da saída
(partida).
