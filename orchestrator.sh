#!/bin/bash
# ORCHESTRATOR - Video Pipeline (director de flujo, no invocador de APIs)
# Bea — Arquitectura profesional completa
#
# IMPORTANTE — arquitectura real de este pipeline:
# Este script es un HELPER LOCAL. NO invoca Higgsfield / ElevenLabs / Airtable
# directamente: no tiene credenciales para eso, y esos servicios solo son
# alcanzables como MCP tools desde Claude Code. Su trabajo es: leer/actualizar
# queue.json, calcular el plan de lote, generar el comando para el sandbox, y
# registrar resultados en pipeline-log.jsonl. Las llamadas reales (generar
# video/audio, chequear balance) las dispara Claude vía MCP.
#
# Además, el contenedor donde corre Claude Code tiene salida de red
# restringida por política de la organización: no puede hacer `curl` directo
# a los CDN de Higgsfield ni de ElevenLabs (403 del proxy de egress). Por eso
# la descarga + mezcla con ffmpeg NO corre acá: corre en el sandbox remoto de
# Higgsfield (mcp__Higgsfield__sandbox_exec), que sí tiene salida a internet
# y ffmpeg preinstalado. Por la misma razón, el asset final NO se puede bajar
# a disco local: "output/" guarda un manifest JSON con el result_url (ver
# queue-update), no el binario.
#
# ══════════════════════════════════════════════════════════════════════════
# REGLA DE PRESUPUESTO PARA LOTES (queue.json) — ver CLAUDE.md, sección
# "Reglas de Presupuesto", excepción de lote:
#   Antes de tocar nada, se muestra UN resumen del lote completo:
#     - Videos/assets a generar: N
#     - Créditos totales estimados: suma de todos los ítems aprobados
#     - Máximo permitido: 3 créditos por generación (MAX_CREDITS_PER_ITEM)
#   El usuario confirma el lote entero una sola vez ("✅ Generar" /
#   "❌ Cancelar"). Recién ahí Claude dispara, ítem por ítem: Higgsfield
#   genera video, ElevenLabs genera audio, ffmpeg mezcla (sandbox_exec),
#   Airtable/pipeline-log.jsonl trackea.
#   Todo ítem que cueste MÁS de 3 créditos por generación queda EXCLUIDO
#   del lote automático (ej: cualquier render con Cinema Studio 3.0) y
#   vuelve a requerir confirmación individual, como manda la regla general.
# ══════════════════════════════════════════════════════════════════════════
#
# Flujo completo:
#
#   FASE 1 — Planificar el lote (sin gastar nada):
#     1. Claude chequea el balance (mcp__Higgsfield__balance).
#     2. Claude corre:
#          ./orchestrator.sh queue-plan --balance N
#        Esto marca cada ítem "pendiente" de queue.json como uno de:
#          aprobado_lote              -> cabe en el tope de 3 y en el balance
#          requiere_confirmacion_individual -> supera el tope de 3 créditos
#          pendiente_creditos         -> no alcanza el balance (sin fallar)
#        e imprime el resumen del lote para mostrárselo al usuario.
#     3. Claude le muestra el resumen al usuario y espera "✅ Generar" o
#        "❌ Cancelar". Sin esa confirmación, no se ejecuta nada más.
#
#   FASE 2 — Ejecutar el lote aprobado (uno por uno, tras la confirmación):
#     Para cada ítem "aprobado_lote", por cada uno:
#       a. Claude genera el asset (Higgsfield generate_image/generate_video,
#          y ElevenLabs si aplica) vía MCP -> obtiene result_url.
#       b. Si hay que mezclar audio+video: Claude llama a media_upload,
#          después:
#            ./orchestrator.sh build-sandbox-cmd \
#              --video-url URL --audio-url URL \
#              --output archivo.mp4 --upload-url UPLOAD_URL
#          y pasa el texto tal cual como "command" de sandbox_exec. Con
#          HTTP 200, Claude llama a media_confirm(media_id, type="video").
#       c. Claude corre:
#            ./orchestrator.sh queue-update --id ID --status completado \
#              --result-url URL_FINAL --credits N
#          (crea output/<id>.json con el manifest — no el binario, ver nota
#          de arquitectura arriba).
#       d. Claude corre:
#            ./orchestrator.sh log --product "Nombre" --video-file URL_FINAL \
#              --status completed --model MODEL_ID --credits N
#          para dejar registro en pipeline-log.jsonl (pendiente de sync a
#          Airtable vía MCP; el log NO se commitea, está en .gitignore).
#
#   Ítems "pendiente_creditos" o "requiere_confirmacion_individual" quedan
#   así en queue.json — no se tocan hasta la próxima corrida de queue-plan
#   (con más balance) o hasta una confirmación individual explícita.

set -e

QUEUE_FILE="queue.json"
LOG_FILE="pipeline-log.jsonl"
OUTPUT_DIR="output"
MAX_CREDITS_PER_ITEM=3

# FUNCIÓN: Validar prerequisitos locales
validate_prerequisites() {
  echo "🔍 Validando prerequisitos..."

  for file in CLAUDE.md higgsfield-config.json elevenlabs-config.json ffmpeg-config.sh; do
    if [ ! -f "$file" ]; then
      echo "❌ ERROR: $file no encontrado"
      exit 1
    fi
  done

  if ! command -v python3 &> /dev/null; then
    echo "❌ ERROR: python3 no instalado (se usa para queue.json y el log)"
    exit 1
  fi

  echo "  ✅ Todos los prerequisitos validados"
  echo "  ℹ️  ffmpeg/ffprobe/curl se validan dentro del sandbox remoto, no acá"
  echo ""
}

require_queue_file() {
  if [ ! -f "$QUEUE_FILE" ]; then
    echo "❌ ERROR: $QUEUE_FILE no encontrado" >&2
    return 1
  fi
}

# FUNCIÓN: Generar el comando a ejecutar en mcp__Higgsfield__sandbox_exec
# Descarga video+audio, normaliza y recorta el audio, mezcla con ffmpeg
# (misma lógica que ffmpeg-config.sh) y sube el resultado al upload_url.
build_sandbox_command() {
  local VIDEO_URL="$1"
  local AUDIO_URL="$2"
  local OUTPUT_FILE="$3"
  local UPLOAD_URL="$4"

  if [ -z "$VIDEO_URL" ] || [ -z "$AUDIO_URL" ] || [ -z "$OUTPUT_FILE" ] || [ -z "$UPLOAD_URL" ]; then
    echo "❌ ERROR: build-sandbox-cmd requiere --video-url, --audio-url, --output y --upload-url" >&2
    return 1
  fi

  local TEMPLATE
  TEMPLATE=$(cat <<'EOF'
cd /home/user && \
curl -fsSL '__VIDEO_URL__' -o input_video.mp4 && \
curl -fsSL '__AUDIO_URL__' -o input_audio.mp3 && \
ls -la input_video.mp4 input_audio.mp3 && \
ffmpeg -i input_audio.mp3 -af "loudnorm=I=-16:TP=-1.5:LRA=11" -y temp_audio_normalized.mp3 -loglevel error && \
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 input_video.mp4) && \
echo "Video duration: $DURATION" && \
ffmpeg -i temp_audio_normalized.mp3 -t "$DURATION" -y temp_audio_trimmed.mp3 -loglevel error && \
ffmpeg -i input_video.mp4 -i temp_audio_trimmed.mp3 -c:v copy -c:a aac -b:a 192k -shortest -y __OUTPUT_FILE__ -loglevel error && \
ls -la __OUTPUT_FILE__ && \
curl -f -X PUT -H "Content-Type: video/mp4" --data-binary @__OUTPUT_FILE__ '__UPLOAD_URL__' -w '\nHTTP_STATUS:%{http_code}\n'
EOF
)

  TEMPLATE="${TEMPLATE//__VIDEO_URL__/$VIDEO_URL}"
  TEMPLATE="${TEMPLATE//__AUDIO_URL__/$AUDIO_URL}"
  TEMPLATE="${TEMPLATE//__OUTPUT_FILE__/$OUTPUT_FILE}"
  TEMPLATE="${TEMPLATE//__UPLOAD_URL__/$UPLOAD_URL}"

  echo "$TEMPLATE"
}

# FUNCIÓN: Listar ítems de la cola (opcionalmente filtrados por status)
queue_list() {
  local STATUS_FILTER="$1"
  require_queue_file || return 1

  python3 - "$QUEUE_FILE" "$STATUS_FILTER" <<'PYEOF'
import json, sys

queue_file, status_filter = sys.argv[1:3]
with open(queue_file) as f:
    queue = json.load(f)

items = [i for i in queue if not status_filter or i.get("status") == status_filter]

if not items:
    print("  (sin ítems)" + (f" con status='{status_filter}'" if status_filter else ""))
else:
    for item in items:
        print(f"  - [{item.get('id')}] {item.get('product')} — {item.get('model')} — "
              f"{item.get('estimated_credits')} créditos — status: {item.get('status')}")
PYEOF
}

# FUNCIÓN: Calcular el plan de lote (tope de 3 créditos/ítem + balance
# disponible) SIN llamar a ninguna API. Marca cada ítem "pendiente" como
# aprobado_lote / requiere_confirmacion_individual / pendiente_creditos.
queue_plan() {
  local BALANCE="$1"
  require_queue_file || return 1

  if [ -z "$BALANCE" ]; then
    echo "❌ ERROR: queue-plan requiere --balance N (balance actual, vía mcp__Higgsfield__balance)" >&2
    return 1
  fi

  python3 - "$BALANCE" "$QUEUE_FILE" "$LOG_FILE" "$MAX_CREDITS_PER_ITEM" <<'PYEOF'
import json, sys, datetime

balance, queue_file, log_file, max_per_item = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
balance = float(balance)
max_per_item = float(max_per_item)

with open(queue_file) as f:
    queue = json.load(f)

now = datetime.datetime.utcnow().isoformat() + "Z"
running_total = 0.0
approved, excluded_cap, excluded_credits = [], [], []

for item in queue:
    if item.get("status") != "pendiente":
        continue
    cost = float(item.get("estimated_credits", 0))
    if cost > max_per_item:
        item["status"] = "requiere_confirmacion_individual"
        item["updated_at"] = now
        excluded_cap.append(item)
    elif running_total + cost <= balance:
        item["status"] = "aprobado_lote"
        item["updated_at"] = now
        running_total += cost
        approved.append(item)
    else:
        item["status"] = "pendiente_creditos"
        item["updated_at"] = now
        excluded_credits.append(item)

with open(queue_file, "w") as f:
    json.dump(queue, f, ensure_ascii=False, indent=2)
    f.write("\n")

log_entries = []
for item in excluded_credits:
    log_entries.append({
        "timestamp": now, "id": item.get("id"), "product": item.get("product"),
        "model": item.get("model"), "status": "insufficient_credits",
        "estimated_credits": item.get("estimated_credits"), "balance_at_check": balance,
    })
for item in excluded_cap:
    log_entries.append({
        "timestamp": now, "id": item.get("id"), "product": item.get("product"),
        "model": item.get("model"), "status": "exceeds_batch_cap",
        "estimated_credits": item.get("estimated_credits"), "max_per_item": max_per_item,
    })
if log_entries:
    with open(log_file, "a") as f:
        for e in log_entries:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")

print("═══════════════════════════════════════")
print("📋 PLAN DE LOTE (queue.json)")
print("═══════════════════════════════════════")
print(f"Videos/assets a generar: {len(approved)}")
print(f"Créditos totales estimados: {running_total}")
print(f"Máximo permitido: {max_per_item} créditos por generación")
print(f"Balance disponible: {balance}")
print("")

if approved:
    print("✅ Aprobados para el lote:")
    for item in approved:
        print(f"  - [{item.get('id')}] {item.get('product')} — {item.get('model')} — {item.get('estimated_credits')} créditos")

if excluded_cap:
    print("")
    print("⚠️  Exceden el tope de 3 créditos/generación (requieren confirmación individual aparte):")
    for item in excluded_cap:
        print(f"  - [{item.get('id')}] {item.get('product')} — {item.get('model')} — {item.get('estimated_credits')} créditos")

if excluded_credits:
    print("")
    print("⏸️  Sin créditos suficientes ahora (quedan 'pendiente_creditos', sin fallar):")
    for item in excluded_credits:
        print(f"  - [{item.get('id')}] {item.get('product')} — {item.get('model')} — {item.get('estimated_credits')} créditos")

print("")
if approved:
    print("Esperando confirmación del usuario del LOTE completo: '✅ Generar' o '❌ Cancelar'")
else:
    print("Nada para aprobar en este lote (todo excede el tope o el balance).")
PYEOF
}

# FUNCIÓN: Actualizar un ítem de la cola tras ejecutarlo (o al fallar)
queue_update() {
  local ID="$1"
  local STATUS="$2"
  local RESULT_URL="$3"
  local CREDITS="$4"
  local OUTPUT_FILE="$5"
  local NOTES="$6"

  require_queue_file || return 1

  if [ -z "$ID" ] || [ -z "$STATUS" ]; then
    echo "❌ ERROR: queue-update requiere --id y --status" >&2
    return 1
  fi

  python3 - "$ID" "$STATUS" "$RESULT_URL" "$CREDITS" "$OUTPUT_FILE" "$NOTES" "$QUEUE_FILE" "$OUTPUT_DIR" <<'PYEOF'
import json, sys, datetime, os

item_id, status, result_url, credits, output_file, notes, queue_file, output_dir = sys.argv[1:9]

with open(queue_file) as f:
    queue = json.load(f)

now = datetime.datetime.utcnow().isoformat() + "Z"
found = None
for item in queue:
    if item.get("id") == item_id:
        item["status"] = status
        item["updated_at"] = now
        if result_url:
            item["result_url"] = result_url
        if credits:
            try:
                item["actual_credits"] = float(credits)
            except ValueError:
                pass
        if notes:
            item["notes"] = notes
        found = item
        break

if found is None:
    print(f"❌ ERROR: id '{item_id}' no encontrado en {queue_file}", file=sys.stderr)
    sys.exit(1)

with open(queue_file, "w") as f:
    json.dump(queue, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(f"  ✅ queue.json actualizado: [{item_id}] -> {status}")

if status == "completado" and result_url:
    os.makedirs(output_dir, exist_ok=True)
    manifest_path = os.path.join(output_dir, f"{item_id}.json")
    manifest = {
        "id": item_id,
        "product": found.get("product"),
        "model": found.get("model"),
        "result_url": result_url,
        "credits_used": found.get("actual_credits"),
        "completed_at": now,
        "note": ("El archivo real queda hosteado en el CDN de Higgsfield/ElevenLabs; "
                 "este contenedor no puede descargarlo por la politica de egress "
                 "(ver Nota de Arquitectura en CLAUDE.md). Abrir result_url directamente."),
    }
    if output_file:
        manifest["output_file_requested"] = output_file
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"  📁 Manifest guardado: {manifest_path}")
PYEOF
}

# FUNCIÓN: Registrar un resultado en el log local (pendiente de sync a Airtable)
log_result() {
  local PRODUCT="$1"
  local VIDEO_FILE="$2"
  local STATUS="$3"
  local MODEL="$4"
  local CREDITS="$5"
  local NOTES="$6"

  echo "📊 Registrando resultado..."
  echo "  Producto: $PRODUCT"
  echo "  Video: $VIDEO_FILE"
  echo "  Estado: $STATUS"

  python3 - "$PRODUCT" "$VIDEO_FILE" "$STATUS" "$MODEL" "$CREDITS" "$NOTES" "$LOG_FILE" <<'PYEOF'
import json, sys, datetime

product, video_file, status, model, credits, notes, log_file = sys.argv[1:8]
entry = {
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "product": product,
    "video_file": video_file,
    "status": status,
}
if model:
    entry["model"] = model
if credits:
    try:
        entry["credits_used"] = float(credits)
    except ValueError:
        entry["credits_used"] = credits
if notes:
    entry["notes"] = notes

with open(log_file, "a") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
PYEOF

  echo "  ✅ Registrado en $LOG_FILE (pendiente de sync a Airtable vía MCP)"
  echo ""
}

usage() {
  echo "Uso:"
  echo ""
  echo "  ./orchestrator.sh queue-list [--status STATUS]"
  echo "      Lista ítems de queue.json (todos, o filtrados por status)."
  echo ""
  echo "  ./orchestrator.sh queue-plan --balance N"
  echo "      Calcula el plan de lote (tope $MAX_CREDITS_PER_ITEM créditos/ítem"
  echo "      + balance N) y actualiza queue.json. No gasta nada. Imprime el"
  echo "      resumen a confirmar con el usuario ANTES de generar cualquier cosa."
  echo ""
  echo "  ./orchestrator.sh queue-update --id ID --status STATUS \\"
  echo "      [--result-url URL] [--credits N] [--output FILE] [--notes \"texto\"]"
  echo "      Actualiza un ítem tras ejecutarlo (o al fallar). Con"
  echo "      status=completado y --result-url, guarda un manifest en"
  echo "      $OUTPUT_DIR/<id>.json."
  echo ""
  echo "  ./orchestrator.sh build-sandbox-cmd \\"
  echo "    --video-url URL --audio-url URL --output archivo.mp4 --upload-url URL"
  echo "      Imprime el comando para pasar tal cual a mcp__Higgsfield__sandbox_exec."
  echo ""
  echo "  ./orchestrator.sh log \\"
  echo "    --product \"Nombre\" --video-file URL --status completed \\"
  echo "    [--model MODEL_ID] [--credits N] [--notes \"texto\"]"
  echo "      Registra un resultado en $LOG_FILE."
  echo ""
  echo "Ver la cabecera de este archivo para el flujo completo (fase 1: plan de"
  echo "lote + confirmación única; fase 2: ejecución ítem por ítem)."
}

# MAIN
main() {
  validate_prerequisites

  local MODE="$1"
  shift || true

  local PRODUCT="" VIDEO_URL="" AUDIO_URL="" VIDEO_FILE="" OUTPUT="" UPLOAD_URL="" STATUS="" MODEL="" CREDITS="" NOTES="" ID="" BALANCE="" RESULT_URL=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --product) PRODUCT="$2"; shift 2 ;;
      --video-url) VIDEO_URL="$2"; shift 2 ;;
      --audio-url) AUDIO_URL="$2"; shift 2 ;;
      --video-file) VIDEO_FILE="$2"; shift 2 ;;
      --output) OUTPUT="$2"; shift 2 ;;
      --upload-url) UPLOAD_URL="$2"; shift 2 ;;
      --status) STATUS="$2"; shift 2 ;;
      --model) MODEL="$2"; shift 2 ;;
      --credits) CREDITS="$2"; shift 2 ;;
      --notes) NOTES="$2"; shift 2 ;;
      --id) ID="$2"; shift 2 ;;
      --balance) BALANCE="$2"; shift 2 ;;
      --result-url) RESULT_URL="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "❌ Argumento desconocido: $1"; usage; exit 1 ;;
    esac
  done

  case "$MODE" in
    queue-list)
      queue_list "$STATUS"
      ;;
    queue-plan)
      queue_plan "$BALANCE"
      ;;
    queue-update)
      queue_update "$ID" "$STATUS" "$RESULT_URL" "$CREDITS" "$OUTPUT" "$NOTES"
      ;;
    build-sandbox-cmd)
      build_sandbox_command "$VIDEO_URL" "$AUDIO_URL" "$OUTPUT" "$UPLOAD_URL"
      ;;
    log)
      log_result "$PRODUCT" "$VIDEO_FILE" "$STATUS" "$MODEL" "$CREDITS" "$NOTES"
      ;;
    *)
      echo "╔════════════════════════════════════════╗"
      echo "║ ESPERANDO INSTRUCCIONES                ║"
      echo "╚════════════════════════════════════════╝"
      echo ""
      usage
      ;;
  esac
}

main "$@"
