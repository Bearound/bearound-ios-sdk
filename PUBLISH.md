# Publicando uma Nova Versao do BearoundSDK (iOS)

## Pre-requisitos

- Acesso ao repositorio [Bearound/bearound-ios-sdk](https://github.com/Bearound/bearound-ios-sdk)
- CocoaPods trunk configurado no Mac (`pod trunk register`)
- Token do CocoaPods configurado no GitHub Secrets (`COCOAPODS_TRUNK_TOKEN`)

---

## Passo a Passo

### 1. Atualizar a versao nos 3 arquivos

A versao precisa ser identica nos 3 locais:

| Arquivo | Local | Exemplo |
|---------|-------|---------|
| `BearoundSDK/BearoundSDK.swift` | Linha 21: `return "X.Y.Z"` | `return "2.4.0"` |
| `BearoundSDK.podspec` | `spec.version = "X.Y.Z"` | `spec.version = "2.4.0"` |
| `CHANGELOG.md` | `## [X.Y.Z] - YYYY-MM-DD` | `## [2.4.0] - 2026-02-20` |

### 2. Atualizar o CHANGELOG.md

Adicionar uma nova secao no topo do arquivo (abaixo do cabecalho), seguindo o formato:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- Descricao das features adicionadas

### Changed
- Descricao das alteracoes

### Fixed
- Descricao dos bugs corrigidos

---
```

> O workflow valida que `## [X.Y.Z]` existe no CHANGELOG.md. Se nao existir, o release falha.

### 3. Commit e push

```bash
git add BearoundSDK/BearoundSDK.swift BearoundSDK.podspec CHANGELOG.md
git commit -m "bump: version X.Y.Z"
git push origin main
```

### 4. Criar e publicar a tag

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

> O push da tag (`v*`) dispara automaticamente o workflow **iOS SDK Release** no GitHub Actions.

### 5. Acompanhar o workflow

O workflow executa 4 jobs em sequencia:

```
1. Pre-Release Validation
   - Verifica se a versao da tag == podspec == changelog
   - Roda pod lib lint
   - Builda o XCFramework

2. Publish to CocoaPods
   - Verifica se a versao ja esta publicada (skip se ja estiver)
   - Executa pod trunk push

3. Create GitHub Release
   - Cria a release no GitHub com as notas do CHANGELOG
   - Anexa o XCFramework.zip como asset

4. Release Success
   - Confirma que tudo passou
```

Acompanhe em: https://github.com/Bearound/bearound-ios-sdk/actions

### 6. (Fallback) Publicar manualmente no CocoaPods

Caso o workflow falhe no step do CocoaPods, publique manualmente no Mac:

```bash
pod trunk push BearoundSDK.podspec --allow-warnings --skip-import-validation --synchronous
```

> Requer `COCOAPODS_TRUNK_TOKEN` configurado ou sessao ativa via `pod trunk register`.

---

## Checklist Rapido

```
[ ] Versao atualizada em BearoundSDK.swift
[ ] Versao atualizada em BearoundSDK.podspec
[ ] CHANGELOG.md atualizado com secao da nova versao
[ ] Commit e push para main
[ ] Tag criada: git tag vX.Y.Z
[ ] Tag publicada: git push origin vX.Y.Z
[ ] Workflow passou no GitHub Actions
[ ] Versao aparece no CocoaPods (pod search BearoundSDK)
```

---

## Erros Comuns

### "Version mismatch between tag and podspec"
A versao na tag (`vX.Y.Z`) nao bate com `spec.version` no podspec. Corrija o podspec, commit, delete e recrie a tag:
```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
# corrija o podspec, commit, push
git tag vX.Y.Z
git push origin vX.Y.Z
```

### "Version X.Y.Z not documented in CHANGELOG.md"
Falta a secao `## [X.Y.Z]` no CHANGELOG.md. Adicione, commit, delete e recrie a tag.

### "Authentication token is invalid or unverified"
O `COCOAPODS_TRUNK_TOKEN` no GitHub Secrets expirou. Gere um novo:
```bash
pod trunk register email@example.com 'Nome' --description='GitHub Actions'
# Confirme no email
# Copie o token de ~/.netrc
```
Atualize o secret em: Settings > Secrets and variables > Actions > `COCOAPODS_TRUNK_TOKEN`

### "Version already published on CocoaPods"
O workflow detecta automaticamente e pula o `pod trunk push`. Nao e um erro.

### Tag conflita com branch de mesmo nome
Use refspec completo:
```bash
git push origin refs/tags/vX.Y.Z
```

---

## Versionamento

Seguimos [Semantic Versioning](https://semver.org/):

- **MAJOR** (X.0.0): Breaking changes na API publica
- **MINOR** (0.X.0): Novas features sem quebrar compatibilidade
- **PATCH** (0.0.X): Bug fixes e melhorias internas
