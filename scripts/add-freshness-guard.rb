#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Installs the "XCFramework freshness" Run Script build phase into BeAroundScan.
#
# Idempotent: running it twice leaves a single phase. Kept as a script (rather than a
# hand-edited pbxproj) so the change is reviewable and reproducible.
#
# Usage:
#   GEM_HOME="$(dirname "$(readlink -f "$(which pod)")")/.." ruby scripts/add-freshness-guard.rb
# or simply:
#   scripts/add-freshness-guard.sh

require 'xcodeproj'

PROJECT = File.expand_path('../BeAroundScan/BeAroundScan.xcodeproj', __dir__)
TARGET  = 'BeAroundScan'
NAME    = 'Verificar frescor do XCFramework'
SCRIPT  = '"$SRCROOT/../scripts/verify-xcframework-fresh.sh"' + "\n"

project = Xcodeproj::Project.open(PROJECT)
target  = project.targets.find { |t| t.name == TARGET }
abort("target #{TARGET} não encontrado em #{PROJECT}") if target.nil?

existing = target.build_phases.select do |phase|
  phase.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && phase.name == NAME
end

if existing.any?
  puts "phase '#{NAME}' já existe (#{existing.size}x) — normalizando"
  existing.drop(1).each { |p| target.build_phases.delete(p) }
  phase = existing.first
else
  phase = target.new_shell_script_build_phase(NAME)
end

phase.shell_path   = '/bin/bash'
phase.shell_script = SCRIPT
# Sem outputs declarados o Xcode roda a cada build — que é exatamente o que queremos:
# a checagem é barata (um `find`) e precisa valer para TODO build, inclusive incremental.
phase.always_out_of_date = '1'

# Tem de rodar ANTES de compilar: falhar depois de meio build só desperdiça tempo.
target.build_phases.delete(phase)
target.build_phases.unshift(phase)

project.save
puts "OK — '#{NAME}' instalada como primeira build phase de #{TARGET}"
