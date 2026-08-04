#!/bin/bash
# ORCHESTRATOR - Video Pipeline (helper + logger)
# Bea — Arquitectura profesional completa
#
# IMPORTANTE — arquitectura real de este pipeline:
# Este script es un HELPER LOCAL, no un orquestador que llama a Higgsfield /
# ElevenLabs / Airtable directamente: no tiene credenciales para eso, y esos
# servicios solo son alcanzables como MCP tools desde Claude Code.
#
# Además, el contenedor donde corre Claude Code tiene salida de red
# restringida por política de la organización: no puede hacer `curl` directo
# a los CDN de Higgsfield ni de ElevenLabs (403 del proxy de egress). Por eso
# la descarga + mezcla con ffmpeg NO corre acá: corre en el sandbox remoto de
# Higgsfield (mcp__Higgsfield__sandbox_exec), que sí tiene salida a internet
# y ffmpeg preinstalado.
#
# Flujo real (lo ejecuta Claude; este script solo genera piezas del camino):
#   1. Claude genera el video (Higgsfield generate_video, Cinema Studio 3.0)
#      y el audio (ElevenLabs) vía MCP -> obtiene el result_url de cada uno.
#   2. Claude llama a media_upload -> obtiene upload_url + media_id para el
#      archivo final.
#   3. Claude corre:
#        ./orchestrator.sh build-sandbox-cmd \
#          --video-url URL --audio-url URL \
#          --output archivo.mp4 --upload-url UPLOAD_URL
#      y usa el texto que imprime tal cual como el "command" de sandbox_exec.
#   4. sandbox_exec descarga ambos assets, normaliza el audio (loudnorm),
#      lo recorta a la duración del video, mezcla con ffmpeg (igual que
#      ffmpeg-config.sh) y sube el resultado con curl -X PUT.
#   5. Con HTTP 200 en la respuesta, Claude llama a media_confirm(media_id,
#      type="video").
#   6. Claude corre:
#        ./orchestrator.sh log --product "Nombre" \
#          --video-file URL_FINAL --status completed \
#          [--model MODEL_ID] [--credits N] [--notes "texto"]
#      para dejar registro en pipeline-log.jsonl (pendiente de sync a
#      Airtable vía MCP; el log NO se commitea, está en .gitignore).

set -e

LOG_FILE="pipeline-log.jsonl"

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
    echo "❌ ERROR: python3 no instalado (se usa para el log)"
    exit 1
  fi

  echo "  ✅ Todos los prerequisitos validados"
  echo "  ℹ️  ffmpeg/ffprobe/curl se validan dentro del sandbox remoto, no acá"
  echo ""
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
  echo "  ./orchestrator.sh build-sandbox-cmd \\"
  echo "    --video-url URL --audio-url URL --output archivo.mp4 --upload-url URL"
  echo ""
  echo "    Imprime el comando para pasar tal cual a mcp__Higgsfield__sandbox_exec."
  echo ""
  echo "  ./orchestrator.sh log \\"
  echo "    --product \"Nombre\" --video-file URL --status completed \\"
  echo "    [--model MODEL_ID] [--credits N] [--notes \"texto\"]"
  echo ""
  echo "    Registra un resultado en $LOG_FILE."
  echo ""
  echo "Ver la cabecera de este archivo para el flujo completo paso a paso."
}

# MAIN
main() {
  validate_prerequisites

  local MODE="$1"
  shift || true

  local PRODUCT="" VIDEO_URL="" AUDIO_URL="" VIDEO_FILE="" OUTPUT="" UPLOAD_URL="" STATUS="" MODEL="" CREDITS="" NOTES=""

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
      -h|--help) usage; exit 0 ;;
      *) echo "❌ Argumento desconocido: $1"; usage; exit 1 ;;
    esac
  done

  case "$MODE" in
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
