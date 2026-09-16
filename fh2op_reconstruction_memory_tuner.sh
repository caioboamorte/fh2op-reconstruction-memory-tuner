
choose_memory

CHANGE_COUNT="$(run_root jq --arg pattern "$TASK_PATTERN" --arg memory "$NEW_MEMORY" '
  [.[]
   | select((.task_name? // "") | test($pattern; "i"))
   | select((.memory // "") != $memory)]
  | length
' "$TASKS_FILE")"

if ((CHANGE_COUNT == 0)); then
  ok "Todas as $MATCH_COUNT tarefas ja estao configuradas com $NEW_MEMORY."
  exit 0
fi

TEMP_FILE="$(run_root mktemp "${TASKS_FILE}.new.XXXXXX")"
run_root jq --arg pattern "$TASK_PATTERN" --arg memory "$NEW_MEMORY" '
  map(
    if ((.task_name? // "") | test($pattern; "i"))
    then .memory = $memory
    else .
    end
  )
' "$TASKS_FILE" | run_root tee "$TEMP_FILE" >/dev/null

run_root jq -e --arg pattern "$TASK_PATTERN" --arg memory "$NEW_MEMORY" --argjson expected "$MATCH_COUNT" '
  type == "array"
  and ([.[] | select((.task_name? // "") | test($pattern; "i"))] | length == $expected)
  and ([.[]
        | select((.task_name? // "") | test($pattern; "i"))
        | select(.memory == $memory)] | length == $expected)
' "$TEMP_FILE" >/dev/null || die "A copia alterada nao passou na validacao. O original permanece intacto."

printf '\nAlteracao proposta:\n'
run_root diff -u --label 'configuracao atual' --label 'nova configuracao' \
  <(run_root jq --arg pattern "$TASK_PATTERN" \
    '[.[] | select((.task_name? // "") | test($pattern; "i")) | {task_name,cpu,memory,disk,executor_name}]' \
    "$TASKS_FILE") \
  <(run_root jq --arg pattern "$TASK_PATTERN" \
    '[.[] | select((.task_name? // "") | test($pattern; "i")) | {task_name,cpu,memory,disk,executor_name}]' \
    "$TEMP_FILE") || true

printf '\n%s de %s tarefa(s) serao ajustadas para %s.\n' "$CHANGE_COUNT" "$MATCH_COUNT" "$NEW_MEMORY"
if [[ "$SKIP_RESTART" == true ]]; then
  printf 'Os containers nao serao reiniciados (--no-restart).\n'
else
  printf 'Os containers ts-admin e ts-scheduler serao reiniciados, se existirem.\n'
fi
read -r -p "Para aplicar, digite APLICAR: " CONFIRMATION
[[ "$CONFIRMATION" == "APLICAR" ]] || die "Operacao cancelada; nenhum arquivo foi alterado."

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="${TASKS_FILE}.backup-${TIMESTAMP}"
run_root cp -a -- "$TASKS_FILE" "$BACKUP_FILE"
ok "Backup criado: $BACKUP_FILE"

run_root chmod --reference="$TASKS_FILE" "$TEMP_FILE"
run_root chown --reference="$TASKS_FILE" "$TEMP_FILE"
run_root mv -- "$TEMP_FILE" "$TASKS_FILE"
TEMP_FILE=""

POST_INVALID_COUNT="$(run_root jq --arg pattern "$TASK_PATTERN" --arg memory "$NEW_MEMORY" '
  [.[]
   | select((.task_name? // "") | test($pattern; "i"))
   | select(.memory != $memory)]
  | length
' "$TASKS_FILE" 2>/dev/null || printf '%s' -1)"

if ! validate_tasks_file "$TASKS_FILE" || [[ "$POST_INVALID_COUNT" != "0" ]]; then
  restore_backup "$BACKUP_FILE"
  die "A validacao apos a gravacao falhou. O arquivo original foi restaurado."
fi
ok "$MATCH_COUNT tarefa(s) de mapeamento validadas com memory=$NEW_MEMORY"

declare -a RESTARTED=()
if [[ "$SKIP_RESTART" == false ]]; then
  if command -v docker >/dev/null 2>&1; then
    for container in "${CONTAINERS[@]}"; do
      if run_root docker inspect "$container" >/dev/null 2>&1; then
        info "Reiniciando $container..."
        if run_root docker restart "$container" >/dev/null; then
          RESTARTED+=("$container")
        else
          warn "Falha ao reiniciar $container. A configuracao no arquivo foi mantida."
        fi
      else
        warn "Container nao encontrado: $container"
      fi
    done
  else
    warn "Docker nao encontrado; os servicos nao foram reiniciados."
  fi
fi

for container in "${RESTARTED[@]:-}"; do
  if run_root docker exec "$container" test -f /tmp/tasks.json >/dev/null 2>&1; then
    MOUNTED_INVALID_COUNT="$(run_root docker exec "$container" cat /tmp/tasks.json | \
      jq --arg pattern "$TASK_PATTERN" --arg memory "$NEW_MEMORY" '
        [.[]
         | select((.task_name? // "") | test($pattern; "i"))
         | select(.memory != $memory)]
        | length
      ')"
    MOUNTED_MATCH_COUNT="$(run_root docker exec "$container" cat /tmp/tasks.json | \
      jq --arg pattern "$TASK_PATTERN" '
        [.[] | select((.task_name? // "") | test($pattern; "i"))] | length
      ')"
    if [[ "$MOUNTED_INVALID_COUNT" == "0" && "$MOUNTED_MATCH_COUNT" == "$MATCH_COUNT" ]]; then
      ok "$container leu $MATCH_COUNT tarefa(s) com memory=$NEW_MEMORY"
    else
      warn "$container nao apresentou todos os valores esperados em /tmp/tasks.json."
    fi
  fi
done

printf '\nResultado final:\n'
run_root jq --arg pattern "$TASK_PATTERN" '
  [.[]
   | select((.task_name? // "") | test($pattern; "i"))
   | {task_name, cpu, memory, disk, executor_name}]
' "$TASKS_FILE"

printf '\nBackup para rollback:\n  %s\n' "$BACKUP_FILE"
printf '\nA alteracao vale para todos os novos mapeamentos 2D e 3D que usarem essas definicoes.\n'
printf 'Um Job/Pod ja criado mantem a configuracao anterior.\n'

if command -v k3s >/dev/null 2>&1; then
  printf '\nPods de reconstrucao encontrados no k3s:\n'
  run_root k3s kubectl get pods -A -o wide 2>/dev/null | \
    awk 'NR == 1 || tolower($0) ~ /reconstruction|terra|aec/' || true
fi

ok "Procedimento concluido."
