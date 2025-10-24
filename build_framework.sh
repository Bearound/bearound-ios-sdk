#!/bin/bash

# Script para limpeza e build do BearoundSDK Framework
# Este script limpa a pasta build e cria um novo XCFramework

set -e  # Para o script se houver erro

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para imprimir mensagens coloridas
print_message() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configurações do projeto
PROJECT_NAME="BearoundSDK"
SCHEME_NAME="BearoundSDK"
BUILD_DIR="build"
XCFRAMEWORK_NAME="${PROJECT_NAME}.xcframework"

# Verificar se estamos no diretório correto
if [ ! -f "${PROJECT_NAME}.xcodeproj/project.pbxproj" ]; then
    print_error "Arquivo de projeto não encontrado. Execute este script no diretório raiz do projeto."
    exit 1
fi

print_message "Iniciando processo de build do ${PROJECT_NAME} Framework..."

# 1. Limpeza da pasta build
print_message "Limpando pasta build..."
if [ -d "${BUILD_DIR}" ]; then
    rm -rf "${BUILD_DIR}"
    print_success "Pasta build removida com sucesso"
else
    print_warning "Pasta build não encontrada, criando nova..."
fi

mkdir -p "${BUILD_DIR}"
print_success "Pasta build criada"

# 2. Build para dispositivos iOS (arm64)
print_message "Fazendo build para dispositivos iOS (arm64)..."
xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -destination "generic/platform=iOS" \
    -archivePath "${BUILD_DIR}/ios_devices.xcarchive" \
    -configuration Release \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES

if [ $? -eq 0 ]; then
    print_success "Build para dispositivos iOS concluído"
else
    print_error "Falha no build para dispositivos iOS"
    exit 1
fi

# 3. Build para simuladores (arm64 + x86_64)
print_message "Fazendo build para simuladores (arm64 + x86_64)..."
xcodebuild archive \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -destination "generic/platform=iOS Simulator" \
    -archivePath "${BUILD_DIR}/ios_simulators.xcarchive" \
    -configuration Release \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES

if [ $? -eq 0 ]; then
    print_success "Build para simuladores concluído"
else
    print_error "Falha no build para simuladores"
    exit 1
fi

# 4. Criar XCFramework
print_message "Criando XCFramework..."
xcodebuild -create-xcframework \
    -framework "${BUILD_DIR}/ios_devices.xcarchive/Products/Library/Frameworks/${PROJECT_NAME}.framework" \
    -framework "${BUILD_DIR}/ios_simulators.xcarchive/Products/Library/Frameworks/${PROJECT_NAME}.framework" \
    -output "${BUILD_DIR}/${XCFRAMEWORK_NAME}"

if [ $? -eq 0 ]; then
    print_success "XCFramework criado com sucesso!"
else
    print_error "Falha na criação do XCFramework"
    exit 1
fi

# 5. Verificar o resultado
print_message "Verificando resultado..."
if [ -d "${BUILD_DIR}/${XCFRAMEWORK_NAME}" ]; then
    print_success "XCFramework encontrado em: ${BUILD_DIR}/${XCFRAMEWORK_NAME}"
    
    # Mostrar informações do framework
    print_message "Informações do XCFramework:"
    ls -la "${BUILD_DIR}/${XCFRAMEWORK_NAME}/"
    
    # Mostrar tamanho do framework
    FRAMEWORK_SIZE=$(du -sh "${BUILD_DIR}/${XCFRAMEWORK_NAME}" | cut -f1)
    print_message "Tamanho do XCFramework: ${FRAMEWORK_SIZE}"
    
else
    print_error "XCFramework não foi criado corretamente"
    exit 1
fi

print_success "Processo de build concluído com sucesso!"
print_message "O XCFramework está disponível em: ${BUILD_DIR}/${XCFRAMEWORK_NAME}"
print_message "Você pode usar este framework em seus projetos iOS."

