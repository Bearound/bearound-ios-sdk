# Scripts de Build do BearoundSDK Framework

Este diretório contém scripts para automatizar o processo de build do framework iOS BearoundSDK.

## Scripts Disponíveis

### 1. `build_framework.sh` - Build Completo
Script principal que executa todo o processo de build:
- Limpa a pasta `build`
- Faz build para dispositivos iOS (arm64)
- Faz build para simuladores (arm64 + x86_64)
- Cria o XCFramework final

**Uso:**
```bash
./build_framework.sh
```

### 2. `clean_build.sh` - Limpeza Rápida
Script para limpeza apenas da pasta build:
- Remove completamente a pasta `build`
- Útil quando você quer apenas limpar sem fazer rebuild

**Uso:**
```bash
./clean_build.sh
```

## Estrutura do Build

Após executar o `build_framework.sh`, você terá:

```
build/
├── BearoundSDK.xcframework/          # Framework final para distribuição
│   ├── Info.plist
│   ├── ios-arm64/                   # Build para dispositivos iOS
│   └── ios-arm64_x86_64-simulator/  # Build para simuladores
├── ios_devices.xcarchive/            # Archive para dispositivos
└── ios_simulators.xcarchive/         # Archive para simuladores
```

## Requisitos

- Xcode instalado
- Command Line Tools do Xcode
- Permissões de execução nos scripts (`chmod +x`)

## Como Usar o Framework

O `BearoundSDK.xcframework` gerado pode ser usado em projetos iOS:

1. Arraste o arquivo `.xcframework` para o seu projeto Xcode
2. Adicione ao target do seu app
3. Importe no código Swift: `import BearoundSDK`

## Troubleshooting

- **Erro de permissão**: Execute `chmod +x *.sh` para dar permissões de execução
- **Erro de projeto não encontrado**: Certifique-se de executar os scripts no diretório raiz do projeto
- **Erro de build**: Verifique se o Xcode está instalado e atualizado

## Informações Técnicas

- **Deployment Target**: iOS 18.5+
- **Arquiteturas**: arm64 (dispositivos), arm64 + x86_64 (simuladores)
- **Configuração**: Release
- **Tamanho aproximado**: ~580KB


