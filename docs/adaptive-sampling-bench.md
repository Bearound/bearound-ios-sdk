# Bancada iOS local

O build padrão do SDK continua Release. A bancada exige um XCFramework Debug, opt-in explícito no host e um endpoint HTTPS local com certificado já confiável. O transporte conserva Authorization e a validação TLS normal. Não há exceção ATS, instalação de certificado ou chave nova de Motion.

Preparar somente o build, sem consultar aparelhos, instalar ou alterar provisionamento:

```bash
./install_example.sh --bench --build-only \
  --endpoint https://localhost:18080 \
  --fixture-token fixture-token-adaptive-sampling \
  --fixture-user fixture-person --adaptive true
```

`localhost` atende build/simulador. Um iPhone físico precisa de um endereço HTTPS privado da LAN coberto pelo certificado confiável. Os parâmetros de fixture exigem o prefixo sintético `fixture-`; URL pública, HTTP, credenciais na URL e flags inválidas são rejeitados. O app usa `io.bearound.BeAround-Scan.adaptivebench`, isolando seu container, configurações e fila do exemplo habitual. O plist gerado fica em `build/bench-host/Info.plist`, antes do primeiro acesso a `SDK.shared`, inclusive no cold restore. Metadata inválida impede inicialização.

O modo de bancada desliga error reporting pelo API existente e não registra APNs nem pede autorização para notificações. Não solicita Motion. Preparar permissões do host antes de iniciar uma execução física; um host sem autorização/description existentes de Motion usa o fallback. Background URLSession e callbacks de relaunch continuam encaminhados.

Controle de compatibilidade/rollback: usar `--adaptive false` no candidato. Esse controle e `AdaptiveSamplingBench.injectBeacon` servem a regressões determinísticas, não à prova física de precisão, rádio ou bateria.

O baseline físico parte de `62109cfdfea9a3dc47fcdf522ec17e03939d8ad0`. A instrumentação mínima está em [bench/ios-prechange-transport.patch](bench/ios-prechange-transport.patch), aplicável com `git apply --unidiff-zero`; a reversão usa `git apply -R --unidiff-zero`. O audit registra que o SDK anterior preserva os arquivos de visita, rádio, filtros e persistência. O worktree preparado é `/tmp/wt-ios-sdk-adaptive-bench-baseline-20261014`, commit `562254a025aee18fae73f683e0e1b3a690657b79`. Copiar apenas o harness comum deste diretório para esse worktree; manter seu SDK anterior. Compilar com `--bench --baseline --adaptive false`. `BEAROUND_ADAPTIVE_BASELINE` seleciona a assinatura anterior de configure, sem engine, injection ou policy novos.

`build/framework-build-manifest.json` registra SHA do fonte, configuração, flags Swift, toolchain, SHA do binário e UUID Mach-O por slice. O fingerprint canônico cobre todos os arquivos do SDK mais seu projeto, com paths relativos e hashes ordenados. Cada framework guarda o mesmo fingerprint em seu Info.plist; versão igual não é prova de origem.

`build/example-build-proof.json` verifica o framework realmente embarcado: fingerprint, UUID Mach-O, configuração e flag. Inclui o hash do executable, framework, plist e fonte do host; o token de fixture aparece somente como hash. `installation.status=not_run` identifica o build sem instalação. Preservar esses arquivos e os logs antes de alternar arms ou configurações.

```bash
./build_framework.sh                  # Release padrão
./build_framework.sh --bench          # Debug explícito
./install_example.sh --build-only     # exemplo habitual, sem instalar
```

A instalação física só entra na etapa final, após os gates de código e os inputs de aparelho e confiança. `--build-only` rejeita UDID e `--allow-provisioning-updates`. O script não pede atualização de provisionamento por padrão; o flag é explícito para uma futura execução física autorizada. Antes de instalar, verifica novamente a identidade embarcada e a assinatura do app.

A aceitação física fica com o runner e o protocolo da spec. Builds locais, fixtures injetadas e artefatos `not_run` não aprovam os gates de recall, dwell, fragmentação, tempo, rádio ou energia.
