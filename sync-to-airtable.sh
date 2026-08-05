#!/bin/bash
# Sincronización automática pipeline-log.jsonl → Airtable Videos table
# Idempotente: mantiene registro de timestamps ya sincronizados

set -e

SYNC_STATE_FILE=".airtable-sync-state"
PENDING_FILE=".airtable-sync-pending.json"
PIPELINE_LOG="pipeline-log.jsonl"

# Inicializar estado si no existe
if [ ! -f "$SYNC_STATE_FILE" ]; then
  : > "$SYNC_STATE_FILE"
fi

# Función: convertir timestamp ISO 8601 a YYYY-MM-DD
extract_date() {
  echo "$1" | cut -d'T' -f1
}

# Función: mapear status interno a Estado Airtable con formato correcto
map_status_to_airtable() {
  local status="$1"
  case "$status" in
    "completed") echo "Completado con audio" ;;
    "completed_no_audio") echo "Completado sin audio" ;;
    "exceeds_batch_cap") echo "Pendiente créditos" ;;
    "pendiente_creditos") echo "Pendiente créditos" ;;
    "failed_video_download") echo "Fallido" ;;
    *) echo "En proceso" ;;
  esac
}

echo "═══════════════════════════════════════"
echo "🔄 Analizando pipeline-log.jsonl para sincronizar con Airtable"
echo "═══════════════════════════════════════"
echo ""

# Limpiar archivo pendiente anterior
> "$PENDING_FILE"
echo "[" > "$PENDING_FILE"

FIRST=true
SYNC_COUNT=0

# Leer y procesar cada línea de pipeline-log.jsonl
while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Extraer timestamp (clave única para idempotencia)
  timestamp=$(echo "$line" | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -z "$timestamp" ] && continue

  # Si ya está sincronizado, saltar
  if grep -qxF "$timestamp" "$SYNC_STATE_FILE" 2>/dev/null; then
    continue
  fi

  # Extraer campos de la entrada
  product=$(echo "$line" | grep -o '"product":"[^"]*"' | head -1 | cut -d'"' -f4)
  status=$(echo "$line" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  video_file=$(echo "$line" | grep -o '"video_file":"[^"]*"' | head -1 | cut -d'"' -f4)
  model=$(echo "$line" | grep -o '"model":"[^"]*"' | head -1 | cut -d'"' -f4)
  credits=$(echo "$line" | grep -o '"credits_used":[0-9.]*' | cut -d':' -f2)
  estimated_credits=$(echo "$line" | grep -o '"estimated_credits":[0-9]*' | cut -d':' -f2)
  notes=$(echo "$line" | grep -o '"notes":"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\\"/"/g')

  # Construir entrada para Airtable
  FECHA=$(extract_date "$timestamp")
  ESTADO=$(map_status_to_airtable "$status")
  TITULO="${product} [${ESTADO}]"

  # Notas combinadas
  NOTA="${model}"
  if [ -n "$credits" ]; then
    NOTA="$NOTA, ${credits} cr"
  elif [ -n "$estimated_credits" ]; then
    NOTA="$NOTA, ${estimated_credits} cr est"
  fi
  [ -n "$notes" ] && NOTA="$NOTA. $notes"

  # Agregar a JSON de pendientes
  if [ "$FIRST" = false ]; then
    echo "," >> "$PENDING_FILE"
  fi
  FIRST=false

  cat >> "$PENDING_FILE" <<EOF
  {
    "fields": {
      "fldaaUc0Y0A0fpX8C": "$TITULO",
      "fldjsqmqNvjfRN8CZ": "$FECHA",
      "fldMflSu0Oc65xjnH": "$product",
      "fldWU4vCTK5QGM2fh": "$ESTADO",
      "fldtFRkga6SSWKwH0": "$video_file",
      "fldljOueE565i2uW0": "$NOTA"
    }
  }
EOF

  echo "  ✓ $product ($ESTADO)"
  ((SYNC_COUNT++))

  # Guardar timestamp para marcar como sincronizado luego
  echo "$timestamp" >> "$SYNC_STATE_FILE.new"

done < "$PIPELINE_LOG"

# Si se llamó con --mark-synced, marcar todos los entries como sincronizados
if [ "$1" == "--mark-synced" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts=$(echo "$line" | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$ts" ] && echo "$ts" >> "$SYNC_STATE_FILE"
  done < "$PIPELINE_LOG"
  echo "✅ Todos los entries marcados como sincronizados"
  exit 0
fi

echo "]" >> "$PENDING_FILE"

# Actualizar archivo de estado si hay nuevas entradas
if [ -f "$SYNC_STATE_FILE.new" ]; then
  cat "$SYNC_STATE_FILE.new" >> "$SYNC_STATE_FILE"
  rm "$SYNC_STATE_FILE.new"
fi

echo ""
if [ $SYNC_COUNT -eq 0 ]; then
  echo "✅ Nada nuevo para sincronizar"
  rm "$PENDING_FILE"
  exit 0
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 LISTO: $SYNC_COUNT registros para sincronizar con Airtable"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✨ Llamada MCP lista:"
echo "  mcp__Airtable__create_records_for_table"
echo "  - baseId: appIgj85opUfpvyhW"
echo "  - tableId: tbldwlzkhOV1hZClF"
echo "  - typecast: true"
echo "  - records: [contenido de $PENDING_FILE]"
echo ""
