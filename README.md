# Video Pipeline — Bea Actividades que Conectan

## ¿Qué es?

Sistema de automatización para generar videos cinematográficos usando:
- **Higgsfield** (Cinema Studio, image-to-video/text-to-video)
- **ElevenLabs** (voz femenina profesional)
- **ffmpeg** (mezcla y normalización de audio, corre en sandbox remoto)
- **Airtable** (tracking — hoy manual vía `pipeline-log.jsonl`, sync automático pendiente)

**Resultado:** assets para Instagram/redes, generados con confirmación explícita de costo en cada paso — no es un sistema desatendido: cada llamada que gasta créditos la dispara Claude vía MCP, nunca un script por sí solo.

---

## Estructura del Proyecto

```
video-pipeline/
├── CLAUDE.md                    # Identidad + reglas permanentes (presupuesto, arquitectura)
├── higgsfield-config.json       # Configuración Cinema Studio
├── elevenlabs-config.json       # Parámetros de voz femenina
├── ffmpeg-config.sh             # Script de mezcla profesional (referencia; corre vía sandbox_exec)
├── orchestrator.sh              # Director de flujo: cola, plan de lote, log — no invoca APIs
├── test-pipeline-dry-run.sh     # Test de prerequisitos sin gastar créditos
├── queue.json                   # Cola de assets a generar
├── pipeline-log.jsonl           # Log de ejecuciones (gitignored, se regenera por run)
├── output/                      # Manifests JSON de assets completados (gitignored)
├── .gitignore
└── README.md                    # Este archivo
```

---

## Por qué no es "un click y listo"

Dos límites técnicos reales de este entorno, documentados en `CLAUDE.md`:

1. **`orchestrator.sh` no tiene credenciales de Higgsfield/ElevenLabs/Airtable.** Esos servicios solo son alcanzables como MCP tools desde Claude Code. El script hace la parte mecánica (leer/actualizar `queue.json`, calcular costos, generar el comando de mezcla, loguear); las llamadas reales las dispara Claude.
2. **El contenedor de Claude Code no tiene salida de red a los CDN de Higgsfield/ElevenLabs** (403 del proxy de egress). Por eso la descarga + mezcla con ffmpeg corre en el sandbox remoto de Higgsfield (`sandbox_exec`), y el asset final **nunca baja a disco local** — queda hosteado en el CDN. `output/<id>.json` guarda un manifest con esa URL, no el archivo.

---

## Cómo Generar Videos

### PASO 1 — Cargar `queue.json`

Es un array (no un objeto envolvente). Cada ítem necesita, como mínimo:

```json
[
  {
    "id": "video_001",
    "product": "Tarimas Portables",
    "type": "video",
    "model": "cinematic_studio_video_v2",
    "prompt": "Video 15s: pareja en montaña nevada, detienen camioneta blanca, bajan tarima de madera clara, bailaora flamenco en vestido rojo baila con pasión, cámara lenta, música flamenco, luz cálida, cinematográfico. Final: 'Tarimas Portables — Lleva tu escenario donde desees'",
    "params": { "duration": 15, "aspect_ratio": "9:16", "sound": "on" },
    "estimated_credits": 3,
    "status": "pendiente"
  }
]
```

`estimated_credits` es el campo que usa `queue-plan` para calcular el lote — si falta o tiene otro nombre, el ítem se trata como si costara 0 créditos. Confirmá el costo real con `get_cost:true` antes de cargarlo (ver Reglas de Presupuesto).

### PASO 2 — Calcular el plan de lote (sin gastar nada)

Claude corre, con el balance que consultó vía `mcp__Higgsfield__balance`:

```bash
./orchestrator.sh queue-plan --balance N
```

Marca cada ítem `pendiente` como uno de:
- `aprobado_lote` — entra en el tope de 3 créditos/ítem y en el balance
- `requiere_confirmacion_individual` — supera 3 créditos/ítem (ej. cualquier Cinema Studio 3.0 real, que arranca en 14)
- `pendiente_creditos` — no alcanza el balance ahora (no falla, queda para después)

Y muestra el resumen del lote (videos a generar, créditos totales, tope, balance) para que lo confirmes.

### PASO 3 — Confirmar el lote

Con "✅ Generar" (o "❌ Cancelar"), y **solo entonces**, Claude ejecuta, ítem por ítem: Higgsfield genera el asset, ElevenLabs genera audio si aplica, `sandbox_exec` mezcla con ffmpeg, y se registra el resultado.

No hay un slash command tipo `/video-generator "id"` — el flujo lo maneja Claude directamente en la conversación, llamando a las MCP tools y a `orchestrator.sh queue-update` / `orchestrator.sh log` en cada paso.

### PASO 4 — Verificar

```bash
./orchestrator.sh queue-list --status completado
```

Cada ítem completado tiene su manifest en `output/<id>.json` con el `result_url` real (CDN de Higgsfield/ElevenLabs) — ahí se abre/descarga el asset.

---

## Reglas de Presupuesto (importantes)

- ✅ Confirmación explícita antes de CUALQUIER llamada que gaste créditos — modelo, parámetros y costo estimado incluidos
- ✅ Excepción de lote: una sola confirmación para todo `queue.json`, siempre que cada ítem cueste ≤3 créditos (ver `CLAUDE.md`)
- ✅ Cualquier ítem que supere 3 créditos/generación (incluido Cinema Studio 3.0 real) sale del lote automático y pide confirmación individual
- ✅ Balance reportado antes y después de cada generación

---

## Troubleshooting

**"No tengo créditos"**
→ Recargá en higgsfield.ai (no tengo el precio actual verificado, consultalo ahí) o esperá a que `queue-plan` marque el ítem como `pendiente_creditos` y volvé a correrlo cuando recargues.

**"ElevenLabs generó voz de hombre"**
→ Regenerá — no debería pasar, `elevenlabs-config.json` fuerza `gender: female`, `stability >= 0.75`. Si vuelve a pasar, revisá el `voice_id` usado.

**"ffmpeg falla al mezclar"**
→ Eso corre en el sandbox remoto, no localmente. Revisá el output de `sandbox_exec`: que el `curl` de descarga haya dado 200, que `ffprobe` haya leído la duración del video, y que el `curl -X PUT` final haya devuelto `HTTP_STATUS:200`.

**"¿Cómo cancelo un ítem?"**
→ `./orchestrator.sh queue-update --id ID --status cancelado`

---

## Ejemplos de prompts (borrador, sin costo real confirmado todavía)

**Tarimas Portables** — `cinematic_studio_video_v2`, ~3 créditos, 15s:
> Video 15s: pareja joven en carretera de alta montaña nevada. Detienen camioneta blanca. Bajan tarima portátil de madera natural, la abren delicadamente. Aparece bailaora de flamenco con vestido rojo intenso, comienza a bailar con pasión sobre la tarima. Cámara lenta, música flamenco étnica, luz cálida cinematográfica. Final: "Tarimas Portables — Lleva tu escenario donde desees"

**Tu peque habla poquito** — `cinematic_studio_video_v2`, ~3 créditos, 15s:
> Video 15s: niño pequeño (2-3 años) en sala luminosa con juguetes. Madre sentada a su lado hablando con él, motivándolo con gestos cálidos. El niño responde con palabras simples, ambos sonríen. Luz natural, tono documental, muy íntimo.

Estos costos son estimaciones basadas en pruebas previas con `cinematic_studio_video_v2` — confirmalos con `get_cost:true` antes de cargar el ítem a `queue.json`, los precios pueden cambiar.

---

## Archivos Clave

- **`CLAUDE.md`** — identidad, reglas de presupuesto, arquitectura de ejecución, memoria del proyecto y registro de decisiones/excepciones tomadas.
- **`higgsfield-config.json`** — parámetros de referencia para Cinema Studio (modelo, resolución, género, Soul ID).
- **`elevenlabs-config.json`** — parámetros de voz (género, idioma, estabilidad).
- **`orchestrator.sh`** — comandos: `queue-list`, `queue-plan`, `queue-update`, `build-sandbox-cmd`, `log`. Ver la cabecera del archivo para el flujo completo paso a paso.

---

## Estado actual

Pipeline validado end-to-end (imagen y video de prueba generados con éxito). Sin `skill`/slash command dedicado todavía — el flujo se conduce conversacionalmente en Claude Code. Listo para cargar más ítems a `queue.json` y procesar en lote cuando haya balance suficiente.

---

Construido con: Higgsfield MCP + ElevenLabs MCP + ffmpeg (sandbox) + Claude Code
