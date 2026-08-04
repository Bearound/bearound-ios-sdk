#!/bin/bash
#
# Reinstala a build phase "Verificar frescor do XCFramework" no projeto do example.
# Só é necessário se a phase se perder (projeto recriado, merge que a removeu).
#
# O gem `xcodeproj` não é instalado avulso nesta máquina — ele vem dentro do CocoaPods,
# então localizamos o GEM_HOME dele em vez de exigir uma instalação separada.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pod >/dev/null 2>&1; then
    echo "erro: CocoaPods não encontrado — é dele que vem o gem xcodeproj." >&2
    echo "      brew install cocoapods" >&2
    exit 1
fi

# O wrapper do homebrew exporta o GEM_HOME correto; extraímos de lá.
GEM_HOME_PATH=$(sed -n 's/^GEM_HOME="\([^"]*\)".*/\1/p' "$(command -v xcodeproj)" 2>/dev/null | head -1)

if [ -z "${GEM_HOME_PATH}" ] || [ ! -d "${GEM_HOME_PATH}" ]; then
    echo "erro: não foi possível localizar o GEM_HOME do xcodeproj." >&2
    echo "      Rode manualmente: GEM_HOME=<caminho> ruby ${SCRIPT_DIR}/add-freshness-guard.rb" >&2
    exit 1
fi

GEM_HOME="${GEM_HOME_PATH}" ruby "${SCRIPT_DIR}/add-freshness-guard.rb"
