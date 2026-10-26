#!/bin/bash
# CP3 - Linux / Operating Systems
# Script de monitoramento e administração de servidor Linux

EXEC_LOG="./exec.log"
AUDIT_LOG="./audit.log"
MEM_LIMIT=75      # % de uso de RAM que dispara a trava de segurança
ALERT_LIMIT=20    # % de CPU/memória por processo considerada alta

# Informações da execução
DATA_HORA=$(date '+%d/%m/%Y %H:%M:%S')
SERVIDOR=$(hostname)
USUARIO=$(whoami)

# ---------- Logs e saída na tela ----------

agora() { date '+%d/%m/%Y %H:%M:%S'; }

log_exec()  { echo "[$(agora)] $1" >> "$EXEC_LOG"; }
log_audit() { echo "[$(agora)] Usuário $USUARIO $1" >> "$AUDIT_LOG"; }
show()      { echo -e "$1"; }

# ---------- Coleta de dados ----------

uso_memoria() {
    awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {printf "%d", (t-a)*100/t}' /proc/meminfo
}

uso_disco() {
    df --output=pcent / | tail -1 | tr -dc '0-9'
}

# ---------- Trava de segurança da memória ----------
# Se a RAM passar de MEM_LIMIT%, finaliza os processos de USUÁRIOS (UID >= 1000)
# que mais consomem memória, até o uso voltar abaixo do limite.
trava_memoria() {
    local uso pid nome
    uso=$(uso_memoria)
    while [ "$uso" -ge "$MEM_LIMIT" ]; do
        # ignora o próprio script e o shell que o chamou; 65534 = nobody (sistema)
        pid=$(ps -eo pid=,uid= --sort=-%mem |
              awk -v s=$$ -v p=$PPID '$2 >= 1000 && $2 != 65534 && $1 != s && $1 != p {print $1; exit}')
        if [ -z "$pid" ]; then
            log_exec "ALERTA: memória em ${uso}%, nenhum processo de usuário para finalizar"
            show "ALERTA: memória em ${uso}%, nenhum processo de usuário para finalizar"
            return
        fi
        nome=$(ps -p "$pid" -o comm=)
        if ! kill -9 "$pid" 2>/dev/null; then
            log_exec "ALERTA: memória em ${uso}%, sem permissão para finalizar o processo $pid ($nome)"
            show "ALERTA: sem permissão para finalizar o processo $pid ($nome)"
            return
        fi
        log_exec "TRAVA DE MEMÓRIA: uso em ${uso}%, processo $pid ($nome) finalizado"
        show "TRAVA DE MEMÓRIA: uso em ${uso}%, processo $pid ($nome) finalizado"
        sleep 1
        uso=$(uso_memoria)
    done
}

# ---------- Opções do menu ----------

info_sistema() {
    show "\n===== Informações do sistema ====="
    show "Hostname.......: $SERVIDOR"
    show "Usuário........: $USUARIO"
    show "Sistema........: $(grep -m1 PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
    show "Kernel.........: $(uname -r)"
    show "Arquitetura....: $(uname -m)"
    show "Ligado há......: $(uptime -p)"
    show "CPUs...........: $(nproc)"
    log_exec "Informações do sistema exibidas (host $SERVIDOR, kernel $(uname -r))"
}

monitorar_memoria() {
    local uso
    uso=$(uso_memoria)
    show "\n===== Memória RAM ====="
    free -h
    show "\nUso de memória: ${uso}%"
    log_exec "Consumo de memória registrado em ${uso}%"
    if [ "$uso" -ge "$MEM_LIMIT" ]; then
        trava_memoria
    fi
}

monitorar_disco() {
    local uso
    uso=$(uso_disco)
    show "\n===== Espaço em disco ====="
    df -h
    show "\nUso do disco /: ${uso}%"
    log_exec "Consumo de disco registrado em ${uso}%"
}

# $1 = coluna de ordenação (%cpu ou %mem)
listar_processos() {
    local campo=$1 total altos
    show "\n===== Processos por consumo de ${campo#%} ====="
    ps -eo pid,user,%cpu,%mem,comm --sort=-"$campo" | head -11
    total=$(ps -e --no-headers | wc -l)
    altos=$(ps -eo "$campo" --no-headers | awk -v l=$ALERT_LIMIT '$1 > l' | wc -l)
    log_exec "Atualmente $total processos em execução na máquina"
    if [ "$altos" -eq 0 ]; then
        log_exec "Nenhum processo acima de ${ALERT_LIMIT}% de consumo de ${campo#%}"
    else
        log_exec "$altos processo(s) acima de ${ALERT_LIMIT}% de consumo de ${campo#%}"
    fi
}

ler_pid() {
    read -rp "Informe o PID: " PID
    if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
        show "PID inválido."
        log_audit "informou um PID inválido ($PID)"
        return 1
    fi
    if ! ps -p "$PID" > /dev/null; then
        show "Processo $PID não encontrado."
        log_audit "consultou o processo $PID, que não existe"
        return 1
    fi
}

detalhes_processo() {
    ler_pid || return
    log_audit "consultou detalhes do processo $PID"
    show "\n===== Detalhes do processo $PID ====="
    ps -p "$PID" -o pid,ppid,user,stat,%cpu,%mem,rss,etime,cmd
    log_exec "Detalhes do processo $PID ($(ps -p "$PID" -o comm=)) exibidos"
}

matar_processo() {
    local resp nome
    ler_pid || return
    nome=$(ps -p "$PID" -o comm=)
    read -rp "Confirma finalizar o processo $PID ($nome)? [s/N] " resp
    if [ "$resp" != "s" ] && [ "$resp" != "S" ]; then
        show "Operação cancelada."
        log_audit "cancelou a interrupção do processo $PID"
        return
    fi
    if kill "$PID" 2>/dev/null; then
        show "Processo $PID ($nome) finalizado."
        log_audit "interrompeu o processo $PID ($nome)"
        log_exec "Processo $PID ($nome) finalizado a pedido do usuário"
    else
        show "Falha ao finalizar o processo $PID (sem permissão?)."
        log_audit "tentou interromper o processo $PID ($nome), sem sucesso"
        log_exec "Falha ao finalizar o processo $PID ($nome)"
    fi
}

ver_logs() {
    show "\n===== exec.log (últimas 10 linhas) ====="
    tail -n 10 "$EXEC_LOG"
    show "\n===== audit.log (últimas 10 linhas) ====="
    tail -n 10 "$AUDIT_LOG"
}

encerrar() {
    log_audit "encerrou o script"
    log_exec "Script encerrado"
    show "\nAté logo, $USUARIO!"
    exit 0
}

# ---------- Início ----------

trap encerrar INT

log_audit "iniciou o script"
log_exec "Script iniciado no servidor $SERVIDOR por $USUARIO"

show "=========================================="
show "  Bem-vindo ao monitor do servidor Linux!"
show "=========================================="
show "Data/hora da execução: $DATA_HORA"
show "Servidor (hostname)..: $SERVIDOR"
show "Usuário..............: $USUARIO"

trava_memoria

while true; do
    show "\n----------- MENU -----------"
    show "1) Informações do sistema"
    show "2) Monitorar memória RAM"
    show "3) Monitorar espaço em disco"
    show "4) Processos por consumo de CPU"
    show "5) Processos por consumo de memória"
    show "6) Detalhes de um processo (PID)"
    show "7) Finalizar um processo (PID)"
    show "8) Ver logs"
    show "0) Sair"
    read -rp "Escolha uma opção: " OPCAO

    case $OPCAO in
        1) log_audit "consultou as informações do sistema"; info_sistema ;;
        2) log_audit "consultou o uso de memória"; monitorar_memoria ;;
        3) log_audit "consultou o uso de disco"; monitorar_disco ;;
        4) log_audit "listou os processos por CPU"; listar_processos %cpu ;;
        5) log_audit "listou os processos por memória"; listar_processos %mem ;;
        6) detalhes_processo ;;
        7) matar_processo ;;
        8) log_audit "visualizou os logs"; ver_logs ;;
        0) encerrar ;;
        *) show "Opção inválida."; log_audit "escolheu uma opção inválida ($OPCAO)" ;;
    esac

    trava_memoria
done
