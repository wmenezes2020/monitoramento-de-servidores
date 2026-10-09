#!/usr/bin/env bash
#
# Agente de monitoramento de servidores.
# Repositorio: https://github.com/wmenezes2020/monitoramento-de-servidores
#
# Este arquivo e gerado por scripts/build.sh a partir de src/agent/*.sh.
# Nao editar direto: a proxima atualizacao sobrescreve.
#
# Sem "set -e" de proposito. Um comando auxiliar que falha (curl, du, ps) nao
# pode derrubar a rodada inteira de monitoramento: o resultado seria um servidor
# sem vigilancia nenhuma e ninguem sabendo. Cada passo trata o proprio erro e
# registra em /var/log/monitoring-agent.log.
set -uo pipefail

# A versao e o unico carimbo. Carimbar o commit tornaria o bundle diferente a
# cada commit mesmo sem mudanca em src/, o checksum do manifesto mudaria
# sozinho, e o "build --check" do CI reprovaria sempre.
AGENTE_VERSAO="__VERSAO__"
