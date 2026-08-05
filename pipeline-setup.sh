#!/bin/bash
# PIPELINE SETUP & TRACKING
# Inicializa pipeline-log.jsonl y la estructura de tracking

set -e

echo "═══════════════════════════════════════"
echo "📋 Pipeline Setup — Inicializando tracking"
echo "═══════════════════════════════════════"
echo ""

# CREAR pipeline-log.jsonl (JSON Lines: cada línea DEBE ser un JSON
# válido — nunca comentarios, un futuro sync a Airtable lo lee línea por
# línea). Si ya existe, NO se toca: puede tener registros reales.
if [ ! -f "pipeline-log.jsonl" ]; then
  echo "✓ Creando pipeline-log.jsonl..."
  : > pipeline-log.jsonl
  echo "  ✅ pipeline-log.jsonl creado (vacío)"
else
  LINES=$(wc -l < pipeline-log.jsonl | tr -d ' ')
  echo "  ℹ️  pipeline-log.jsonl ya existe ($LINES líneas) — no se modifica"
fi
echo ""

# CREAR videos/ — SOLO para uso manual (si en algún momento bajás una
# copia local desde tu navegador). El pipeline nunca escribe acá: este
# contenedor no tiene salida de red a los CDN de Higgsfield/ElevenLabs
# (ver Nota de Arquitectura en CLAUDE.md).
if [ ! -d "videos" ]; then
  echo "✓ Creando directorio videos/ (uso manual, el pipeline no escribe acá)..."
  mkdir -p videos
  echo "  ✅ videos/ creado"
else
  echo "  ℹ️  videos/ ya existe"
fi
echo ""

# output/ ya lo crea automáticamente orchestrator.sh queue-update al
# completar un ítem (ahí van los manifests JSON con result_url). Lo
# garantizamos acá por si este script corre primero.
mkdir -p output

# VALIDAR .gitignore (idempotente, no duplica líneas)
echo "✓ Validando .gitignore..."
for entry in "pipeline-log.jsonl" "output/" "videos/"; do
  if grep -qxF "$entry" .gitignore 2>/dev/null; then
    echo "  ✅ $entry ya ignorado"
  else
    echo "  ⚠️  Agregando $entry a .gitignore"
    echo "$entry" >> .gitignore
  fi
done
echo ""

echo "═══════════════════════════════════════"
echo "✅ PIPELINE SETUP COMPLETADO"
echo "═══════════════════════════════════════"
echo ""
echo "Estructura:"
echo "  ├── pipeline-log.jsonl   (tracking — cada línea un JSON, nunca comentarios)"
echo "  ├── videos/              (uso manual: copias locales que vos bajes a mano)"
echo "  ├── output/              (manifests JSON, los escribe orchestrator.sh queue-update)"
echo "  └── queue.json           (cola)"
echo ""
echo "Formato real de cada línea de pipeline-log.jsonl (lo escribe orchestrator.sh log):"
echo '  {"timestamp":"...","product":"...","video_file":"...","status":"...","model":"...","credits_used":N,"notes":"..."}'
echo ""
echo "Próximo paso:"
echo "  1. Editá queue.json"
echo "  2. Pedile a Claude el balance real (mcp__Higgsfield__balance) y corré:"
echo "       ./orchestrator.sh queue-plan --balance <balance real>"
echo "  3. Seguí el SOP de skill-video-generator.md para el ítem elegido"
