#!/bin/bash
# ORCHESTRATOR — Director del pipeline de video
# NO invoca Higgsfield/ElevenLabs (sin credenciales); maneja queue, plan, log
# Cada evento de log dispara sync-to-airtable.sh automáticamente

set -e

QUEUE_FILE="queue.json"
LOG_FILE="pipeline-log.jsonl"

# ============================================================================
# SUBCOMANDO: queue-list
# Muestra items en la cola, opcionalmente filtrados por status
# ============================================================================
cmd_queue_list() {
  local status_filter="$1"

  if [ ! -f "$QUEUE_FILE" ]; then
    echo "❌ $QUEUE_FILE no existe"
    exit 1
  fi

  if [ -z "$status_filter" ]; then
    # Mostrar todos sin filtro
    cat "$QUEUE_FILE" | python3 -m json.tool 2>/dev/null || cat "$QUEUE_FILE"
  else
    # Filtrar por status
    cat "$QUEUE_FILE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
  if item.get('status') == '$status_filter':
    print(json.dumps(item, indent=2))
" 2>/dev/null || grep "\"status\": \"$status_filter\"" "$QUEUE_FILE"
  fi
}

# ============================================================================
# SUBCOMANDO: queue-plan
# Valida ítems según balance disponible y tope de 3 cr/item
# Sin costar nada — es puramente análisis del lote
# ============================================================================
cmd_queue_plan() {
  local balance="$1"

  if [ -z "$balance" ] || ! [[ "$balance" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "❌ Uso: ./orchestrator.sh queue-plan <número>"
    echo "   <número> = balance real de Higgsfield (ej: 7.5)"
    exit 1
  fi

  if [ ! -f "$QUEUE_FILE" ]; then
    echo "❌ $QUEUE_FILE no existe"
    exit 1
  fi

  echo "═══════════════════════════════════════════════════════════"
  echo "📋 PLAN DE LOTE (validación sin gastar créditos)"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  # Procesar cada ítem
  python3 << PYEOF
import json
import sys

try:
    with open('queue.json', 'r') as f:
        queue = json.load(f)
except:
    print("❌ Error al parsear queue.json")
    sys.exit(1)

balance = float('$balance')
total_credits = 0
approved_count = 0
exceeding_count = 0
insufficient_count = 0

approved_list = []
exceeding_list = []
insufficient_list = []

for item in queue:
    status = item.get('status', 'pendiente')
    if status != 'pendiente':
        continue  # No replanificar items completados/cancelados

    est_credits = item.get('estimated_credits', 0)
    product = item.get('product', 'Sin nombre')
    item_id = item.get('id', '?')

    total_credits += est_credits

    # Lógica de clasificación
    if est_credits > 3:
        # Supera tope de lote individual
        exceeding_list.append(f"  • {product} ({item_id}): {est_credits} cr → requiere_confirmacion_individual")
        item['status'] = 'requiere_confirmacion_individual'
        exceeding_count += 1
    elif est_credits > balance:
        # No alcanza balance
        insufficient_list.append(f"  • {product} ({item_id}): {est_credits} cr (balance: {balance}) → pendiente_creditos")
        item['status'] = 'pendiente_creditos'
        insufficient_count += 1
    else:
        # Entra en lote
        approved_list.append(f"  ✓ {product} ({item_id}): {est_credits} cr")
        item['status'] = 'aprobado_lote'
        approved_count += 1

# Guardar cambios en queue.json
with open('queue.json', 'w') as f:
    json.dump(queue, f, indent=2)

# Mostrar resumen
print(f"Videos/assets a generar: {len(queue)}")
print(f"Créditos totales estimados: {total_credits}")
print(f"Máximo permitido: 3 créditos por generación")
print(f"Balance disponible: {balance}")
print("")

if approved_list:
    print(f"✅ Aprobados para el lote ({approved_count}):")
    for item in approved_list:
        print(item)
    print("")

if exceeding_list:
    print(f"⚠️  Exceden el tope de 3 créditos ({exceeding_count}):")
    for item in exceeding_list:
        print(item)
    print("")

if insufficient_list:
    print(f"⏸️  Sin créditos suficientes ({insufficient_count}):")
    for item in insufficient_list:
        print(item)
    print("")

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
if approved_count > 0:
    print(f"✅ READY: {approved_count} items listo(s) para generar")
    print("   Próximo: confirmá con '✅ Generar' en Claude")
else:
    print("❌ No hay items listos para generar")

sys.exit(0)
PYEOF

  local ret=$?
  [ $ret -ne 0 ] && echo "❌ Error en queue-plan" && exit 1
}

# ============================================================================
# SUBCOMANDO: queue-update
# Actualiza status/result-url/credits de un ítem
# Crea output/<id>.json con el manifest
# ============================================================================
cmd_queue_update() {
  local item_id="" status="" result_url="" credits=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --id) item_id="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --result-url) result_url="$2"; shift 2 ;;
      --credits) credits="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$item_id" ] || [ -z "$status" ]; then
    echo "❌ Uso: ./orchestrator.sh queue-update --id <ID> --status <STATUS> [--result-url URL] [--credits N]"
    exit 1
  fi

  if [ ! -f "$QUEUE_FILE" ]; then
    echo "❌ $QUEUE_FILE no existe"
    exit 1
  fi

  # Actualizar queue.json
  python3 << PYEOF
import json
import datetime
with open('$QUEUE_FILE', 'r') as f:
    queue = json.load(f)

updated = False
for item in queue:
    if item.get('id') == '$item_id':
        item['status'] = '$status'
        if '$result_url':
            item['result_url'] = '$result_url'
        if '$credits':
            item['credits_used'] = float('$credits')
        item['updated_at'] = datetime.datetime.utcnow().isoformat() + 'Z'
        updated = True
        break

if not updated:
    print(f"⚠️  Item {item_id} no encontrado en queue.json")

with open('$QUEUE_FILE', 'w') as f:
    json.dump(queue, f, indent=2)

# Crear manifest en output/<id>.json si hay result_url
if '$result_url':
    manifest = {
        'id': '$item_id',
        'status': '$status',
        'result_url': '$result_url',
        'created_at': datetime.datetime.utcnow().isoformat() + 'Z'
    }
    import os
    os.makedirs('output', exist_ok=True)
    with open(f'output/{item_id}.json', 'w') as f:
        json.dump(manifest, f, indent=2)

print(f"✓ Item {item_id} actualizado: {status}")
PYEOF
}

# ============================================================================
# SUBCOMANDO: build-sandbox-cmd
# Genera comando para que ffmpeg corra en Higgsfield sandbox
# Descarga video+audio, mezcla, sube resultado
# ============================================================================
cmd_build_sandbox_cmd() {
  local video_url="" audio_url="" output="" upload_url=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --video-url) video_url="$2"; shift 2 ;;
      --audio-url) audio_url="$2"; shift 2 ;;
      --output) output="$2"; shift 2 ;;
      --upload-url) upload_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$video_url" ] || [ -z "$upload_url" ]; then
    echo "❌ Uso: ./orchestrator.sh build-sandbox-cmd --video-url <URL> --audio-url <URL> --output <FILE> --upload-url <PRESIGNED_URL>"
    exit 1
  fi

  # Comando que ejecutará Higgsfield sandbox_exec
  cat << 'BASHEOF'
#!/bin/bash
set -e

VIDEO_URL="VIDEO_URL_PLACEHOLDER"
AUDIO_URL="AUDIO_URL_PLACEHOLDER"
OUTPUT_FILE="OUTPUT_PLACEHOLDER"
UPLOAD_URL="UPLOAD_URL_PLACEHOLDER"

echo "Descargando video..."
curl -sS "$VIDEO_URL" -o video.mp4 || exit 1

DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 video.mp4)
echo "Duración del video: ${DURATION}s"

if [ -n "$AUDIO_URL" ]; then
  echo "Descargando audio..."
  curl -sS "$AUDIO_URL" -o audio.mp3 || exit 1

  echo "Normalizando audio y mezclando..."
  ffmpeg -i audio.mp3 -af "loudnorm=I=-16:TP=-1.5:LRA=11" -t "$DURATION" -q:a 9 -acodec libmp3lame audio_norm.mp3 -y >/dev/null 2>&1 || exit 1

  ffmpeg -i video.mp4 -i audio_norm.mp3 -c:v copy -c:a aac -b:a 192k -shortest "$OUTPUT_FILE" -y >/dev/null 2>&1 || exit 1
else
  echo "Sin audio, copiando video directamente..."
  cp video.mp4 "$OUTPUT_FILE"
fi

echo "Subiendo resultado..."
curl -X PUT --data-binary @"$OUTPUT_FILE" "$UPLOAD_URL" || exit 1

echo "✅ Mezcla completada y subida"
BASHEOF

  echo "Comando listo. Reemplazar en tu llamada sandbox_exec:"
  echo "  VIDEO_URL_PLACEHOLDER → $video_url"
  echo "  AUDIO_URL_PLACEHOLDER → $audio_url"
  echo "  OUTPUT_PLACEHOLDER → $output"
  echo "  UPLOAD_URL_PLACEHOLDER → $upload_url"
}

# ============================================================================
# SUBCOMANDO: log
# Registra cada evento en pipeline-log.jsonl (JSON Lines)
# DISPARA sync-to-airtable.sh automáticamente para sincronizar con Airtable
# ============================================================================
cmd_log() {
  local product="" video_file="" status="" model="" credits="" notes=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --product) product="$2"; shift 2 ;;
      --video-file) video_file="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --credits) credits="$2"; shift 2 ;;
      --notes) notes="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$product" ] || [ -z "$status" ]; then
    echo "❌ Uso: ./orchestrator.sh log --product <P> --status <S> [--video-file URL] [--model M] [--credits N] [--notes TEXT]"
    exit 1
  fi

  # Construir línea JSON
  python3 << PYEOF
import json
import datetime

entry = {
    "timestamp": datetime.datetime.utcnow().isoformat() + 'Z',
    "product": '$product',
    "status": '$status',
}

if '$video_file':
    entry["video_file"] = '$video_file'
if '$model':
    entry["model"] = '$model'
if '$credits':
    entry["credits_used"] = float('$credits')
if '$notes':
    entry["notes"] = '$notes'

# Append a pipeline-log.jsonl (JSON Lines: una línea por entry)
with open('$LOG_FILE', 'a') as f:
    f.write(json.dumps(entry) + '\n')

print(f"✓ Registrado: {entry['product']} ({entry['status']})")
PYEOF

  # Automáticamente sincronizar con Airtable después de cada log
  echo "  → Sincronizando con Airtable..."
  if [ -f "sync-to-airtable.sh" ]; then
    ./sync-to-airtable.sh 2>&1 | grep -E "^(  |✅|📋|✨)" || true
  else
    echo "     ⚠️  sync-to-airtable.sh no encontrado (saltando)"
  fi
}

# ============================================================================
# DISPATCH
# ============================================================================
SUBCOMMAND="${1:-}"

case "$SUBCOMMAND" in
  queue-list)
    shift
    cmd_queue_list "$@"
    ;;
  queue-plan)
    shift
    cmd_queue_plan "$@"
    ;;
  queue-update)
    shift
    cmd_queue_update "$@"
    ;;
  build-sandbox-cmd)
    shift
    cmd_build_sandbox_cmd "$@"
    ;;
  log)
    shift
    cmd_log "$@"
    ;;
  *)
    echo "ORCHESTRATOR — Director del Pipeline de Video"
    echo ""
    echo "Subcomandos:"
    echo "  queue-list [--status STATUS]"
    echo "  queue-plan --balance N"
    echo "  queue-update --id ID --status STATUS [--result-url URL] [--credits N]"
    echo "  build-sandbox-cmd --video-url URL --audio-url URL --output FILE --upload-url URL"
    echo "  log --product P --status S [--video-file URL] [--model M] [--credits N] [--notes TEXT]"
    echo ""
    echo "Nota: 'log' automáticamente sincroniza con Airtable vía sync-to-airtable.sh"
    exit 0
    ;;
esac
