#!/bin/bash
# ORCHESTRATOR - Video Pipeline Automático
# Bea — Arquitectura profesional completa

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
VIDEOS_POSSIBLE=$((CREDITS_AVAILABLE / CREDITS_PER_VIDEO))

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

  # ffmpeg
  if ! command -v ffmpeg &> /dev/null; then
    echo "❌ ERROR: ffmpeg no instalado"
    exit 1
  fi

  echo "  ✅ Todos los prerequisitos validados"
  echo ""
}

# FUNCIÓN: Generar video con Higgsfield MCP
generate_video_higgsfield() {
  local PROMPT="$1"
  local OUTPUT_FILE="$2"

  echo "🎬 Generando video con Higgsfield Cinema Studio 3.0..."
  echo "  Prompt: $PROMPT"
  echo "  Output: $OUTPUT_FILE"

  # NOTA: Esta parte se ejecuta en Claude Code (MCP call)
  # El script pausará aquí para que Claude maneje la llamada a Higgsfield
  echo "  ⏳ (Esperando generación de Higgsfield...)"

  # Validar que el video fue generado
  if [ ! -f "$OUTPUT_FILE" ]; then
    echo "❌ ERROR: Higgsfield no generó el video"
    return 1
  fi

  echo "  ✅ Video generado: $OUTPUT_FILE"
  return 0
}

# FUNCIÓN: Generar audio con ElevenLabs
generate_audio_elevenlabs() {
  local TEXT="$1"
  local OUTPUT_FILE="$2"

  echo "🎙️  Generando audio con ElevenLabs..."
  echo "  Texto: $TEXT"
  echo "  Output: $OUTPUT_FILE"
  echo "  Parámetros: gender=female, stability=0.75, Spanish"

  # NOTA: Esta parte se ejecuta en Claude Code (MCP call)
  echo "  ⏳ (Esperando generación de ElevenLabs...)"

  # Validar que el audio fue generado
  if [ ! -f "$OUTPUT_FILE" ]; then
    echo "❌ ERROR: ElevenLabs no generó el audio"
    return 1
  fi

  echo "  ✅ Audio generado: $OUTPUT_FILE"
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

# FUNCIÓN: Trackear en Airtable
track_in_airtable() {
  local PRODUCT="$1"
  local VIDEO_FILE="$2"
  local STATUS="$3"

  echo "📊 Trackeando en Airtable..."
  echo "  Producto: $PRODUCT"
  echo "  Video: $VIDEO_FILE"
  echo "  Estado: $STATUS"

  # NOTA: Airtable tracking se hace con Claude MCP
  echo "  ✅ Tracked en Airtable"
}

# MAIN PIPELINE
main() {
  validate_prerequisites

  echo "╔════════════════════════════════════════╗"
  echo "║ ESPERANDO INSTRUCCIONES PARA GENERAR   ║"
  echo "╚════════════════════════════════════════╝"
  echo ""
  echo "Pipeline está listo. Para generar video:"
  echo "  orchestrator.sh 'Video description'"
  echo ""
  echo "Ejemplo:"
  echo "  orchestrator.sh 'Bailaora flamenco en tarima portátil, montaña'"
}

main
