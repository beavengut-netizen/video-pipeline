#!/bin/bash
# FFmpeg Professional Video + Audio Mixing Pipeline
# Bea — Video Pipeline Automation

set -e

# CONFIGURACIÓN PROFESIONAL
VIDEO_INPUT="${1:-input_video.mp4}"
AUDIO_INPUT="${2:-input_audio.mp3}"
OUTPUT="${3:-output_final.mp4}"

# VALIDACIONES
if [ ! -f "$VIDEO_INPUT" ]; then
  echo "ERROR: Video no encontrado: $VIDEO_INPUT"
  exit 1
fi

if [ ! -f "$AUDIO_INPUT" ]; then
  echo "ERROR: Audio no encontrado: $AUDIO_INPUT"
  exit 1
fi

echo "🎬 Pipeline FFmpeg Professional"
echo "Video: $VIDEO_INPUT"
echo "Audio: $AUDIO_INPUT"
echo "Output: $OUTPUT"
echo ""

# PASO 1: Analizar duración del video
VIDEO_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1:nokey=1 "$VIDEO_INPUT")
echo "✓ Duración video: ${VIDEO_DURATION}s"

# PASO 2: Normalizar audio (volumen consistente)
echo "📊 Normalizando audio..."
ffmpeg -i "$AUDIO_INPUT" -af "loudnorm=I=-16:TP=-1.5:LRA=11" -y temp_audio_normalized.mp3 2>&1 | grep -E "Duration|bitrate" || true

# PASO 3: Trimear audio a duración del video
echo "✂️  Ajustando audio a duración del video..."
ffmpeg -i temp_audio_normalized.mp3 -t "$VIDEO_DURATION" -y temp_audio_trimmed.mp3 2>&1 | grep -E "Duration" || true

# PASO 4: Mezclar video + audio (profesional)
echo "🎙️  Mezclando video + audio..."
ffmpeg -i "$VIDEO_INPUT" -i temp_audio_trimmed.mp3 \
  -c:v copy \
  -c:a aac \
  -b:a 192k \
  -shortest \
  -y "$OUTPUT" 2>&1 | grep -E "frame|Duration|bitrate" || true

# PASO 5: Verificación final
if [ -f "$OUTPUT" ]; then
  OUTPUT_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
  echo "✅ Video final creado exitosamente"
  echo "📁 Archivo: $OUTPUT"
  echo "📊 Tamaño: $OUTPUT_SIZE"
else
  echo "❌ ERROR: No se pudo crear el video final"
  exit 1
fi

# Limpiar temporales
rm -f temp_audio_normalized.mp3 temp_audio_trimmed.mp3

echo ""
echo "🎉 Pipeline completado sin errores"
