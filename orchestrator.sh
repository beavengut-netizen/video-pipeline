#!/bin/bash
# ORCHESTRATOR - Video Pipeline Automático
# Bea — Arquitectura profesional completa
#
# IMPORTANTE: Higgsfield, ElevenLabs y Airtable solo son alcanzables como
# MCP tools desde Claude Code — este script NO tiene credenciales y no
# puede invocarlos directamente. El flujo real es:
#   1. Claude genera el video (Higgsfield generate_video, Cinema Studio 3.0)
#      y el audio (ElevenLabs) vía MCP, y obtiene sus result_url.
#   2. Claude llama a este script pasando esas URLs; el script descarga,
#      valida y mezcla con ffmpeg-config.sh.
#   3. Claude sincroniza pipeline-log.jsonl a Airtable vía MCP.

set -e

echo "╔════════════════════════════════════════╗"
echo "║ VIDEO PIPELINE ORCHESTRATOR v1.0       ║"
echo "║ Higgsfield → ElevenLabs → ffmpeg      ║"
echo "╚════════════════════════════════════════╝"
echo ""

# CONFIGURACIÓN
PROJECT_NAME="Video Pipeline - Bea"
CREDITS_AVAILABLE=7.7
CREDITS_PER_VIDEO=2.5
VIDEOS_POSSIBLE=$(python3 -c "print(int($CREDITS_AVAILABLE / $CREDITS_PER_VIDEO))")
LOG_FILE="pipeline-log.jsonl"

echo "📊 ESTADO DEL PROYECTO"
echo "  Créditos disponibles: $CREDITS_AVAILABLE"
echo "  Créditos por video: $CREDITS_PER_VIDEO"
echo "  Videos posibles: $VIDEOS_POSSIBLE"
echo ""

# FUNCIÓN: Validar prerequisitos
validate_prerequisites() {
  echo "🔍 Validando prerequisitos..."

  # Archivos config
  for file in CLAUDE.md higgsfield-config.json elevenlabs-config.json ffmpeg-config.sh; do
    if [ ! -f "$file" ]; then
      echo "❌ ERROR: $file no encontrado"
      exit 1
    fi
  done

  # Comandos requeridos
  for cmd in ffmpeg ffprobe curl python3; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "❌ ERROR: $cmd no instalado"
      exit 1
    fi
  done

  echo "  ✅ Todos los prerequisitos validados"
  echo ""
}

# FUNCIÓN: Descargar el video ya generado por Higgsfield (result_url del MCP call)
generate_video_higgsfield() {
  local VIDEO_URL="$1"
  local OUTPUT_FILE="$2"

  echo "🎬 Descargando video de Higgsfield Cinema Studio 3.0..."
  echo "  URL: $VIDEO_URL"
  echo "  Output: $OUTPUT_FILE"

  if [ -z "$VIDEO_URL" ]; then
    echo "❌ ERROR: falta la URL del video generado por Higgsfield MCP"
    return 1
  fi

  if ! curl -fsSL "$VIDEO_URL" -o "$OUTPUT_FILE"; then
    echo "❌ ERROR: no se pudo descargar el video desde $VIDEO_URL"
    return 1
  fi

  if [ ! -s "$OUTPUT_FILE" ]; then
    echo "❌ ERROR: el video descargado está vacío"
    return 1
  fi

  echo "  ✅ Video descargado: $OUTPUT_FILE ($(du -h "$OUTPUT_FILE" | cut -f1))"
  return 0
}

# FUNCIÓN: Descargar el audio ya generado por ElevenLabs (result_url del MCP call)
generate_audio_elevenlabs() {
  local AUDIO_URL="$1"
  local OUTPUT_FILE="$2"

  echo "🎙️  Descargando audio de ElevenLabs..."
  echo "  URL: $AUDIO_URL"
  echo "  Output: $OUTPUT_FILE"
  echo "  Parámetros esperados: gender=female, stability>=0.75, es-ES"

  if [ -z "$AUDIO_URL" ]; then
    echo "❌ ERROR: falta la URL del audio generado por ElevenLabs MCP"
    return 1
  fi

  if ! curl -fsSL "$AUDIO_URL" -o "$OUTPUT_FILE"; then
    echo "❌ ERROR: no se pudo descargar el audio desde $AUDIO_URL"
    return 1
  fi

  if [ ! -s "$OUTPUT_FILE" ]; then
    echo "❌ ERROR: el audio descargado está vacío"
    return 1
  fi

  echo "  ✅ Audio descargado: $OUTPUT_FILE ($(du -h "$OUTPUT_FILE" | cut -f1))"
  return 0
}

# FUNCIÓN: Mezclar video + audio
mix_video_audio() {
  local VIDEO="$1"
  local AUDIO="$2"
  local OUTPUT="$3"

  echo "🎞️  Mezclando video + audio..."

  bash ffmpeg-config.sh "$VIDEO" "$AUDIO" "$OUTPUT"

  if [ -f "$OUTPUT" ]; then
    echo "  ✅ Video final creado: $OUTPUT"
    return 0
  else
    echo "  ❌ ERROR: No se pudo mezclar"
    return 1
  fi
}

# FUNCIÓN: Registrar el resultado para su posterior sync a Airtable
# (este script no tiene credenciales de Airtable; Claude sincroniza
# LOG_FILE vía Airtable MCP después de correr el pipeline)
track_in_airtable() {
  local PRODUCT="$1"
  local VIDEO_FILE="$2"
  local STATUS="$3"

  echo "📊 Registrando resultado para sync a Airtable..."
  echo "  Producto: $PRODUCT"
  echo "  Video: $VIDEO_FILE"
  echo "  Estado: $STATUS"

  python3 - "$PRODUCT" "$VIDEO_FILE" "$STATUS" "$LOG_FILE" <<'PYEOF'
import json, sys, datetime, pathlib

product, video_file, status, log_file = sys.argv[1:5]
entry = {
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "product": product,
    "video_file": video_file,
    "status": status,
    "credits_used": 2.5,
}
with open(log_file, "a") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
PYEOF

  echo "  ✅ Registrado en $LOG_FILE (pendiente de sync a Airtable vía MCP)"
  echo ""
}

usage() {
  echo "Uso:"
  echo "  ./orchestrator.sh --product \"Nombre\" --video-url URL --audio-url URL [--output archivo.mp4]"
  echo ""
  echo "Ejemplo:"
  echo "  ./orchestrator.sh \\"
  echo "    --product 'Tu peque habla poquito' \\"
  echo "    --video-url 'https://cdn.higgsfield.ai/.../video.mp4' \\"
  echo "    --audio-url 'https://cdn.elevenlabs.io/.../audio.mp3' \\"
  echo "    --output output_final.mp4"
  echo ""
  echo "Las URLs de video/audio deben venir de una generación previa vía"
  echo "Higgsfield MCP (Cinema Studio 3.0) y ElevenLabs MCP hecha por Claude."
}

# MAIN PIPELINE
main() {
  validate_prerequisites

  local PRODUCT=""
  local VIDEO_URL=""
  local AUDIO_URL=""
  local OUTPUT="output_final.mp4"

  while [ $# -gt 0 ]; do
    case "$1" in
      --product) PRODUCT="$2"; shift 2 ;;
      --video-url) VIDEO_URL="$2"; shift 2 ;;
      --audio-url) AUDIO_URL="$2"; shift 2 ;;
      --output) OUTPUT="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "❌ Argumento desconocido: $1"; usage; exit 1 ;;
    esac
  done

  if [ -z "$VIDEO_URL" ] || [ -z "$AUDIO_URL" ]; then
    echo "╔════════════════════════════════════════╗"
    echo "║ ESPERANDO INSTRUCCIONES PARA GENERAR   ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    usage
    exit 0
  fi

  local RAW_VIDEO="raw_video_$$.mp4"
  local RAW_AUDIO="raw_audio_$$.mp3"

  if ! generate_video_higgsfield "$VIDEO_URL" "$RAW_VIDEO"; then
    track_in_airtable "$PRODUCT" "-" "failed_video_download"
    exit 1
  fi

  if ! generate_audio_elevenlabs "$AUDIO_URL" "$RAW_AUDIO"; then
    track_in_airtable "$PRODUCT" "-" "failed_audio_download"
    rm -f "$RAW_VIDEO"
    exit 1
  fi

  if ! mix_video_audio "$RAW_VIDEO" "$RAW_AUDIO" "$OUTPUT"; then
    track_in_airtable "$PRODUCT" "-" "failed_mix"
    rm -f "$RAW_VIDEO" "$RAW_AUDIO"
    exit 1
  fi

  track_in_airtable "$PRODUCT" "$OUTPUT" "completed"

  rm -f "$RAW_VIDEO" "$RAW_AUDIO"

  echo "🎉 Pipeline completado: $OUTPUT"
}

main "$@"
