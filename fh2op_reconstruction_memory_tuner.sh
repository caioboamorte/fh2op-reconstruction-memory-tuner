#!/usr/bin/env bash

# Ajusta com seguranca a memoria das tarefas de reconstrucao 2D e 3D
# do DJI FlightHub 2 On-Premises.
#
# Uso:
#   sudo ./fh2op_reconstruction_memory_tuner.sh
#
# Opcoes:
#   --file CAMINHO
#   --no-restart
#   -h | --help

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly CONTAINERS=(ts-admin ts-scheduler)
readonly TASK_PATTERN='^fh2-pri-aec-reconstruction-(2d|3d)'

TASKS_FILE=""
SKIP_RESTART=false
TEMP_FILE=""
NEW_MEMORY=""

info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2
}

error() {
  printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_FILE" && -e "$TEMP_FILE" ]]; then
    rm -f -- "$TEMP_FILE"
  fi
  return 0
}

trap cleanup EXIT

usage() {
  cat <<EOF
Uso:
  sudo ./$SCRIPT_NAME [opcoes]

Opcoes:
  --file CAMINHO    Informa manualmente o task-scheduler-tasks.json
  --no-restart      Nao reinicia ts-admin e ts-scheduler
  -h, --help        Mostra esta ajuda

O script:

  1. Localiza o task-scheduler-tasks.json
  2. Identifica tarefas fh2-pri-aec-reconstruction-2d*
     e fh2-pri-aec-reconstruction-3d*
  3. Solicita a nova quantidade de RAM
  4. Mostra as alteracoes antes de aplicar
  5. Cria backup automatico
  6. Valida o JSON antes e depois da alteracao
  7. Reinicia ts-admin e ts-scheduler, quando disponiveis
  8. Confirma se os containers carregaram a nova configuracao
EOF
}

while (($#)); do
  case "$1" in
    --file)
      (($# >= 2)) || die "Faltou o caminho depois de --file."
      TASKS_FILE="$2"
      shift 2
      ;;

    --no-restart)
      SKIP_RESTART=true
      shift
      ;;

    -h|--help)
      usage
      exit 0
      ;;

    *)
      die "Opcao desconhecida: $1. Use --help."
      ;;
  esac
done

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 \
    || die "Execute como root ou instale o sudo."

  SUDO=(sudo)
fi

run_root() {
  "${SUDO[@]}" "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || die "Comando obrigatorio nao encontrado: $1"
}

require_command jq
require_command awk
require_command diff
require_command mktemp
require_command stat
require_command find
require_command readlink
require_command tee

if ((${#SUDO[@]})); then
  info "Validando permissao administrativa..."
  run_root -v \
    || die "Nao foi possivel obter permissao com sudo."
fi

declare -a CANDIDATES=()

add_candidate() {
  local candidate="$1"
  local existing

  [[ -n "$candidate" && -f "$candidate" ]] || return 0

  candidate="$(
    readlink -f -- "$candidate" 2>/dev/null \
      || printf '%s' "$candidate"
  )"

  for existing in "${CANDIDATES[@]:-}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done

  CANDIDATES+=("$candidate")
}

discover_from_container() {
  local container="$1"

  command -v docker >/dev/null 2>&1 || return 0

  run_root docker inspect "$container" \
    --format '{{range .Mounts}}{{if eq .Destination "/tmp/tasks.json"}}{{println .Source}}{{end}}{{end}}' \
    2>/dev/null || true
}

validate_tasks_file() {
  local file="$1"

  [[ -f "$file" ]] || return 1

  run_root jq -e 'type == "array"' "$file" >/dev/null 2>&1
}

choose_tasks_file() {
  local source
  local found
  local answer
  local selection

  if [[ -n "$TASKS_FILE" ]]; then
    [[ -f "$TASKS_FILE" ]] \
      || die "Arquivo informado nao existe: $TASKS_FILE"

    TASKS_FILE="$(readlink -f -- "$TASKS_FILE")"
    return 0
  fi

  #
  # 1. Tenta descobrir pelo bind mount dos containers
  #
  for source in "${CONTAINERS[@]}"; do
    found="$(discover_from_container "$source")"

    while IFS= read -r answer; do
      add_candidate "$answer"
    done <<< "$found"
  done

  #
  # 2. Caminhos conhecidos do FH2 OP
  #
  add_candidate \
    "/fhop-install/install/conf/self-service/task-scheduler/task-scheduler-tasks.json"

  add_candidate \
    "/fhop-install/install/conf/middleware-service/task-scheduler/task-scheduler-tasks.json"

  #
  # 3. Procura dentro de /fhop-install
  #
  if [[ -d /fhop-install ]]; then
    while IFS= read -r found; do
      add_candidate "$found"
    done < <(
      run_root find /fhop-install \
        -maxdepth 10 \
        -type f \
        -name 'task-scheduler-tasks.json' \
        -print 2>/dev/null || true
    )
  fi

  #
  # 4. Procura em alguns caminhos comuns adicionais
  #
  for source in \
    /data \
    /dados \
    /opt \
    /terra-install \
    /fh2-install
  do
    [[ -d "$source" ]] || continue

    while IFS= read -r found; do
      add_candidate "$found"
    done < <(
      run_root find "$source" \
        -maxdepth 10 \
        -type f \
        -name 'task-scheduler-tasks.json' \
        -print 2>/dev/null || true
    )
  done

  #
  # Nenhum arquivo encontrado
  #
  if ((${#CANDIDATES[@]} == 0)); then
    warn "O arquivo nao foi localizado automaticamente."

    read -r -p \
      "Digite o caminho completo do task-scheduler-tasks.json: " \
      TASKS_FILE

    [[ -n "$TASKS_FILE" ]] \
      || die "Nenhum caminho informado."

    [[ -f "$TASKS_FILE" ]] \
      || die "Arquivo nao encontrado: $TASKS_FILE"

    TASKS_FILE="$(readlink -f -- "$TASKS_FILE")"

    return 0
  fi

  #
  # Um ou mais arquivos encontrados
  #
  printf '\nArquivos encontrados:\n'

  for selection in "${!CANDIDATES[@]}"; do
    printf '  %d) %s\n' \
      "$((selection + 1))" \
      "${CANDIDATES[$selection]}"
  done

  printf '  0) Informar outro caminho\n'

  while true; do
    read -r -p "Selecione o arquivo [1]: " answer
    answer="${answer:-1}"

    if [[ "$answer" == "0" ]]; then
      read -r -p \
        "Digite o caminho completo: " \
        TASKS_FILE

      if [[ ! -f "$TASKS_FILE" ]]; then
        warn "Arquivo nao encontrado."
        continue
      fi

      TASKS_FILE="$(readlink -f -- "$TASKS_FILE")"
      break

    elif [[ "$answer" =~ ^[0-9]+$ ]] \
      && ((answer >= 1 && answer <= ${#CANDIDATES[@]}))
    then
      TASKS_FILE="${CANDIDATES[$((answer - 1))]}"
      break

    else
      warn "Selecao invalida."
    fi
  done
}

choose_memory() {
  local input
  local value

  while true; do
    read -r -p \
      "Informe a nova memoria em GiB (ex.: 20, 24 ou 28): " \
      input

    input="${input//[[:space:]]/}"

    input="${input%Gi}"
    input="${input%GI}"
    input="${input%G}"
    input="${input%g}"

    if [[ "$input" =~ ^[1-9][0-9]*$ ]] \
      && ((input <= 512))
    then
      value="$input"
      break
    fi

    warn "Valor invalido. Informe um numero inteiro entre 1 e 512."
  done

  if ((value < 20)); then
    warn "Valores abaixo de 20Gi aumentam bastante o risco de OOMKilled."

    read -r -p \
      "Deseja continuar mesmo assim? Digite SIM: " \
      input

    [[ "$input" == "SIM" ]] \
      || die "Operacao cancelada."
  fi

  NEW_MEMORY="${value}Gi"
}

restore_backup() {
  local backup="$1"

  warn "Restaurando o backup devido a uma falha de validacao..."

  run_root cp -a -- \
    "$backup" \
    "$TASKS_FILE"
}

#
# ============================================================
# Inicio da execucao
# ============================================================
#

choose_tasks_file

validate_tasks_file "$TASKS_FILE" \
  || die "O arquivo nao contem um array JSON valido: $TASKS_FILE"

ok "Arquivo validado: $TASKS_FILE"

MATCH_COUNT="$(
  run_root jq \
    --arg pattern "$TASK_PATTERN" '
      [
        .[]
        | select(
            (.task_name? // "")
            | test($pattern; "i")
          )
      ]
      | length
    ' "$TASKS_FILE"
)"

((MATCH_COUNT > 0)) \
  || die "Nenhuma tarefa de mapeamento 2D ou 3D foi encontrada."

printf '\nArquivo selecionado:\n'
printf '  %s\n' "$TASKS_FILE"

printf '\nTarefas que receberao o mesmo parametro de RAM:\n'

run_root jq -r \
  --arg pattern "$TASK_PATTERN" '
    .[]
    | select(
        (.task_name? // "")
        | test($pattern; "i")
      )
    | "  - \(.task_name) | RAM atual: \(.memory // "NA")"
  ' "$TASKS_FILE"

printf '\nTotal encontrado: %s tarefa(s).\n' "$MATCH_COUNT"

choose_memory

CHANGE_COUNT="$(
  run_root jq \
    --arg pattern "$TASK_PATTERN" \
    --arg memory "$NEW_MEMORY" '
      [
        .[]
        | select(
            (.task_name? // "")
            | test($pattern; "i")
          )
        | select(
            (.memory // "") != $memory
          )
      ]
      | length
    ' "$TASKS_FILE"
)"

if ((CHANGE_COUNT == 0)); then
  ok "Todas as $MATCH_COUNT tarefas ja estao configuradas com $NEW_MEMORY."
  exit 0
fi

TEMP_FILE="$(
  run_root mktemp \
    "${TASKS_FILE}.new.XXXXXX"
)"

run_root jq \
  --arg pattern "$TASK_PATTERN" \
  --arg memory "$NEW_MEMORY" '
    map(
      if (
        (.task_name? // "")
        | test($pattern; "i")
      )
      then
        .memory = $memory
      else
        .
      end
    )
  ' "$TASKS_FILE" \
  | run_root tee "$TEMP_FILE" >/dev/null

#
# Valida o arquivo temporario
#
run_root jq -e \
  --arg pattern "$TASK_PATTERN" \
  --arg memory "$NEW_MEMORY" \
  --argjson expected "$MATCH_COUNT" '
    type == "array"
    and (
      [
        .[]
        | select(
            (.task_name? // "")
            | test($pattern; "i")
          )
      ]
      | length == $expected
    )
    and (
      [
        .[]
        | select(
            (.task_name? // "")
            | test($pattern; "i")
          )
        | select(
            .memory == $memory
          )
      ]
      | length == $expected
    )
  ' "$TEMP_FILE" >/dev/null \
  || die "A copia alterada nao passou na validacao. O original permanece intacto."

printf '\nAlteracao proposta:\n'

run_root diff -u \
  --label 'configuracao atual' \
  --label 'nova configuracao' \
  <(
    run_root jq \
      --arg pattern "$TASK_PATTERN" '
        [
          .[]
          | select(
              (.task_name? // "")
              | test($pattern; "i")
            )
          | {
              task_name,
              cpu,
              memory,
              disk,
              executor_name
            }
        ]
      ' "$TASKS_FILE"
  ) \
  <(
    run_root jq \
      --arg pattern "$TASK_PATTERN" '
        [
          .[]
          | select(
              (.task_name? // "")
              | test($pattern; "i")
            )
          | {
              task_name,
              cpu,
              memory,
              disk,
              executor_name
            }
        ]
      ' "$TEMP_FILE"
  ) || true

printf '\n%s de %s tarefa(s) serao ajustadas para %s.\n' \
  "$CHANGE_COUNT" \
  "$MATCH_COUNT" \
  "$NEW_MEMORY"

if [[ "$SKIP_RESTART" == true ]]; then
  printf 'Os containers nao serao reiniciados (--no-restart).\n'
else
  printf 'Os containers ts-admin e ts-scheduler serao reiniciados, se existirem.\n'
fi

read -r -p \
  "Para aplicar, digite APLICAR: " \
  CONFIRMATION

[[ "$CONFIRMATION" == "APLICAR" ]] \
  || die "Operacao cancelada; nenhum arquivo foi alterado."

#
# Backup
#
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

BACKUP_FILE="${TASKS_FILE}.backup-${TIMESTAMP}"

run_root cp -a -- \
  "$TASKS_FILE" \
  "$BACKUP_FILE"

ok "Backup criado: $BACKUP_FILE"

#
# Mantem permissoes e ownership do original
#
run_root chmod \
  --reference="$TASKS_FILE" \
  "$TEMP_FILE"

run_root chown \
  --reference="$TASKS_FILE" \
  "$TEMP_FILE"

#
# Substitui atomically
#
run_root mv -- \
  "$TEMP_FILE" \
  "$TASKS_FILE"

TEMP_FILE=""

#
# Validacao apos gravacao
#
POST_INVALID_COUNT="$(
  run_root jq \
    --arg pattern "$TASK_PATTERN" \
    --arg memory "$NEW_MEMORY" '
      [
        .[]
        | select(
            (.task_name? // "")
            | test($pattern; "i")
          )
        | select(
            .memory != $memory
          )
      ]
      | length
    ' "$TASKS_FILE" \
    2>/dev/null \
  || printf '%s' -1
)"

if ! validate_tasks_file "$TASKS_FILE" \
  || [[ "$POST_INVALID_COUNT" != "0" ]]
then
  restore_backup "$BACKUP_FILE"

  die \
    "A validacao apos a gravacao falhou. O arquivo original foi restaurado."
fi

ok "$MATCH_COUNT tarefa(s) de mapeamento validadas com memory=$NEW_MEMORY"

#
# Reinicia containers
#
declare -a RESTARTED=()

if [[ "$SKIP_RESTART" == false ]]; then

  if command -v docker >/dev/null 2>&1; then

    for container in "${CONTAINERS[@]}"; do

      if run_root docker inspect \
        "$container" >/dev/null 2>&1
      then

        info "Reiniciando $container..."

        if run_root docker restart \
          "$container" >/dev/null
        then
          RESTARTED+=("$container")
          ok "$container reiniciado."
        else
          warn \
            "Falha ao reiniciar $container. A configuracao no arquivo foi mantida."
        fi

      else
        warn "Container nao encontrado: $container"
      fi

    done

  else
    warn "Docker nao encontrado; os servicos nao foram reiniciados."
  fi
fi

#
# Confirma configuracao lida pelos containers
#
for container in "${RESTARTED[@]:-}"; do

  if run_root docker exec \
    "$container" \
    test -f /tmp/tasks.json \
    >/dev/null 2>&1
  then

    MOUNTED_INVALID_COUNT="$(
      run_root docker exec \
        "$container" \
        cat /tmp/tasks.json \
      | jq \
        --arg pattern "$TASK_PATTERN" \
        --arg memory "$NEW_MEMORY" '
          [
            .[]
            | select(
                (.task_name? // "")
                | test($pattern; "i")
              )
            | select(
                .memory != $memory
              )
          ]
          | length
        '
    )"

    MOUNTED_MATCH_COUNT="$(
      run_root docker exec \
        "$container" \
        cat /tmp/tasks.json \
      | jq \
        --arg pattern "$TASK_PATTERN" '
          [
            .[]
            | select(
                (.task_name? // "")
                | test($pattern; "i")
              )
          ]
          | length
        '
    )"

    if [[ "$MOUNTED_INVALID_COUNT" == "0" \
      && "$MOUNTED_MATCH_COUNT" == "$MATCH_COUNT" ]]
    then
      ok "$container leu $MATCH_COUNT tarefa(s) com memory=$NEW_MEMORY"
    else
      warn \
        "$container nao apresentou todos os valores esperados em /tmp/tasks.json."
    fi

  else
    warn \
      "$container nao possui /tmp/tasks.json para validacao."
  fi

done

#
# Resultado final
#
printf '\nResultado final:\n'

run_root jq \
  --arg pattern "$TASK_PATTERN" '
    [
      .[]
      | select(
          (.task_name? // "")
          | test($pattern; "i")
        )
      | {
          task_name,
          cpu,
          memory,
          disk,
          executor_name
        }
    ]
  ' "$TASKS_FILE"

printf '\nBackup para rollback:\n'
printf '  %s\n' "$BACKUP_FILE"

printf '\nA alteracao vale para todos os novos mapeamentos 2D e 3D que usarem essas definicoes.\n'
printf 'Um Job/Pod ja criado mantem a configuracao anterior.\n'

#
# Mostra pods relacionados a reconstrucao
#
if command -v k3s >/dev/null 2>&1; then

  printf '\nPods de reconstrucao encontrados no k3s:\n'

  run_root k3s kubectl get pods \
    -A \
    -o wide \
    2>/dev/null \
  | awk '
      NR == 1 ||
      tolower($0) ~ /reconstruction|terra|aec/
    ' \
  || true

fi

ok "Procedimento concluido."
