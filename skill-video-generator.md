# SKILL: Video Generator — SOP Cinematográfico

## Definición
Procedimiento estándar reproducible para generar videos cinematográficos con
Higgsfield Cinema Studio + ElevenLabs + ffmpeg. Cada paso tiene validación.
`orchestrator.sh` **nunca invoca Higgsfield/ElevenLabs/Airtable por sí
mismo** — no tiene credenciales para eso; es director de flujo (lee/actualiza
`queue.json`, calcula el plan de lote, genera el comando del sandbox,
loguea). Las llamadas reales las dispara Claude vía MCP.

## Se invoca con
En Claude Code, cualquier sesión:

```
Necesito generar un video para [PRODUCTO].
Descripción: [DESCRIPCIÓN EXACTA]
```

Claude:
1. Valida presupuesto (balance + plan de lote o confirmación individual)
2. Genera con Higgsfield
3. Genera audio con ElevenLabs (voz femenina FORZADA)
4. Mezcla con ffmpeg (en el sandbox remoto, nunca local)
5. Trackea en `pipeline-log.jsonl` y actualiza `queue.json`

---

## PASOS (SOP) — Standard Operating Procedure

### PRE-REQUISITO: Validar Presupuesto

```bash
./orchestrator.sh queue-plan --balance N
```

`N` es el balance real que Claude consultó con `mcp__Higgsfield__balance` —
el script no puede consultarlo solo. Si no alcanza para ningún ítem, el
comando lo dice y no gasta nada; no hay "STOP" manual que hacer, el propio
plan deja los ítems en `pendiente_creditos`.

---

### PASO 1: DEFINIR VIDEO EN queue.json

```json
{
  "id": "video_YYYYMMDD_001",
  "product": "Tarimas Portables",
  "type": "video",
  "model": "cinematic_studio_video_v2",
  "prompt": "[DESCRIPCIÓN EXACTA 50-100 palabras]",
  "params": {
    "duration": 10,
    "aspect_ratio": "9:16",
    "sound": "off"
  },
  "estimated_credits": 3,
  "status": "pendiente",
  "audio": {
    "text": "[NARRACIÓN PARA ELEVENLABS]",
    "gender": "female",
    "language": "es-ES"
  }
}
```

**Campos que usa `orchestrator.sh` (tienen que llamarse así):** `id`,
`product`, `model`, `prompt`, `params`, `estimated_credits`, `status`. Si
se usan otros nombres (`description`, `credits_required`, etc.) el script
no los reconoce y `estimated_credits` queda en 0 — el ítem se aprobaría
de lote como si fuera gratis.

**`audio` es informativo**, no lo lee `orchestrator.sh`: es la referencia
que Claude usa en el Paso 3 para llamar a ElevenLabs.

**Validaciones:**
- ✅ `id` único (YYYYMMDD_001)
- ✅ `prompt` claro y cinematográfico
- ✅ `params.duration` dentro del rango real del modelo — **`cinematic_studio_video_v2` acepta 3 a 12 segundos**, no 15-20 (pedir más de 12 lo clampea en silencio, sin avisar)
- ✅ `audio.gender` = "female" (NUNCA cambiar)
- ✅ `audio.text` en español (máx 50 palabras)
- ✅ `estimated_credits` confirmado con `get_cost: true` antes de cargar el ítem — 3 créditos fue lo que costó nuestra prueba puntual (corta, sin sonido, modo std); varía con duración/modo/sonido

---

### PASO 2: VALIDAR COLA

```bash
./orchestrator.sh queue-plan --balance N
```

**Salida real (resumen):**

```
📋 PLAN DE LOTE (queue.json)
Videos/assets a generar: N
Créditos totales estimados: X
Máximo permitido: 3 créditos por generación
Balance disponible: X.X
✅ Aprobados para el lote: ...
⚠️  Exceden el tope / ⏸️ Sin créditos suficientes: ...
```

**Si un ítem no queda `aprobado_lote`:**
- `pendiente_creditos` → no alcanza el balance; recargar y volver a correr `queue-plan`
- `requiere_confirmacion_individual` → supera 3 créditos/generación (ej. cualquier Cinema Studio 3.0 real, arranca en 14); pedir confirmación aparte, uno por uno
- JSON inválido → revisar sintaxis de `queue.json`

---

### PASO 3: GENERAR VIDEO (Claude MCP)

En Claude Code:

```
Voy a usar el skill video-generator.

Video ID: video_YYYYMMDD_001
Product: [PRODUCTO]
Prompt: [COPIAR EXACTO DEL queue.json]
Audio: [COPIAR EXACTO DEL queue.json]
```

Claude:
1. ✅ `generate_video` (Higgsfield MCP) → `result_url` del video (créditos según `get_cost`)
2. ✅ `text_to_speech` (ElevenLabs MCP) → audio, voz femenina, `stability >= 0.75`, `es`
3. ✅ `media_upload` → `sandbox_exec` con el comando de `orchestrator.sh build-sandbox-cmd` → mezcla real en el sandbox remoto (nunca local) → `media_confirm`
4. ✅ `orchestrator.sh queue-update --id ... --status completado --result-url ...` (crea `output/<id>.json` con el manifest — el binario queda en el CDN, no baja a disco local)
5. ✅ `orchestrator.sh log --product ... --status completed ...` → registra en `pipeline-log.jsonl`

---

### PASO 4: VALIDAR RESULTADO

```bash
./orchestrator.sh queue-list --status completado
```

Cada ítem completado tiene su manifest en `output/<id>.json` con el
`result_url` real — ahí se abre/descarga el asset (hosteado en el CDN de
Higgsfield/ElevenLabs).

---

### PASO 5: TRACKEAR

`pipeline-log.jsonl` queda con el registro de cada corrida. El sync
automático a Airtable **todavía no está implementado** — hoy es manual:
revisar `pipeline-log.jsonl` y cargarlo a Airtable vía MCP cuando
corresponda.

---

## VALIDACIONES DE CALIDAD (GATES)

Antes de dar por "completado", verificar:

✅ **Duración dentro del rango real del modelo** (3-12s en `cinematic_studio_video_v2`; confirmar el rango de cualquier otro modelo con `models_explore`)
✅ **Resolución acorde a lo pedido** (los modelos "v2"/"legacy" de Cinema Studio no van a 4K — para eso hace falta Cinema Studio 3.0 real, más caro)
✅ **Audio sincronizado** (recortado a la duración exacta del video, lo hace el paso de mezcla)
✅ **Voz FEMENINA** (no hombre)
✅ **Volumen normalizado** (loudnorm, sin picos)
✅ **Sin errores en el sandbox** (`HTTP_STATUS:200` al final del comando de mezcla)
✅ **Registrado en `pipeline-log.jsonl` y `queue.json` con status `completado`**

---

## CUANDO FALLA

### ❌ Higgsfield no genera video
**Causa:** créditos insuficientes o error de la API.
**Solución:**
1. `./orchestrator.sh queue-plan --balance N` para confirmar balance real
2. Recargar créditos en higgsfield.ai si hace falta
3. Reintentar la llamada puntual (no todo el lote)

### ❌ ElevenLabs genera voz de hombre
**Causa:** `voice_id`/`voice_settings` no forzó género correctamente.
**Solución:**
1. No cuesta créditos extra regenerar
2. Repetir la llamada verificando `voice_id` femenino conocido y `body.voice_settings`
3. Reintentar

### ❌ ffmpeg falla al mezclar
**Causa:** la mezcla corre en el sandbox remoto, no local — revisar ahí.
**Solución:**
1. Confirmar que ambos `curl` de descarga dieron 200 en el output de `sandbox_exec`
2. Confirmar que `ffprobe` pudo leer la duración del video
3. Confirmar `HTTP_STATUS:200` en el `curl -X PUT` final
4. Si falla por archivos corruptos, regenerar el video/audio desde el paso 3, no reintentar la mezcla a ciegas

### ❌ Audio desfasado
**Causa:** duración distinta entre video y audio.
**Solución:** el comando de `build-sandbox-cmd` ya recorta el audio a la duración exacta del video (`ffprobe` + `-t`); si persiste, revisar que el video generado realmente tenga la duración pedida (ver nota del rango 3-12s arriba).

---

## FLUJO COMPLETO (Visual)

```
START
  ↓
Editar queue.json (agregar ítem: prompt, params, estimated_credits)
  ↓
Claude: mcp__Higgsfield__balance
  ↓
./orchestrator.sh queue-plan --balance N (sin gastar nada)
  ↓
Usuario confirma el lote (✅ Generar / ❌ Cancelar)
  ↓
Claude MCP: Higgsfield genera video
  ↓
Claude MCP: ElevenLabs genera audio (voz femenina)
  ↓
Claude MCP: sandbox_exec mezcla + normaliza (ffmpeg, remoto)
  ↓
orchestrator.sh queue-update + log (pipeline-log.jsonl, output/<id>.json)
  ↓
✅ ASSET LISTO (URL en el CDN, manifest en output/)
END
```

---

## EJEMPLOS LISTOS

### TARIMAS PORTABLES

```json
{
  "id": "video_20260805_001",
  "product": "Tarimas Portables",
  "type": "video",
  "model": "cinematic_studio_video_v2",
  "prompt": "Pareja joven en carretera de alta montaña nevada. Detienen camioneta blanca, bajan tarima portátil de madera natural clara. Bailaora de flamenco en vestido rojo intenso aparece, baila con pasión sobre la tarima. Cámara lenta, música flamenco étnica, luz cálida, cinematográfico. Final: 'Tarimas Portables — Lleva tu escenario donde desees'",
  "params": { "duration": 10, "aspect_ratio": "9:16", "sound": "off" },
  "estimated_credits": 3,
  "status": "pendiente",
  "audio": {
    "text": "Las tarimas portables te permiten llevar tu escenario a cualquier lugar. Perfectas para eventos, fiestas y celebraciones en la montaña, la playa o donde quieras.",
    "gender": "female",
    "language": "es-ES"
  }
}
```

### TU PEQUE HABLA POQUITO

```json
{
  "id": "video_20260805_002",
  "product": "Tu peque habla poquito",
  "type": "video",
  "model": "cinematic_studio_video_v2",
  "prompt": "Niño pequeño (2-3 años) en sala luminosa con juguetes. Madre sentada con él, hablando y motivándolo con gestos cálidos. Niño responde con palabras simples, ambos sonríen. Luz natural, tono documental, muy íntimo y profesional.",
  "params": { "duration": 10, "aspect_ratio": "9:16", "sound": "off" },
  "estimated_credits": 3,
  "status": "pendiente",
  "audio": {
    "text": "Tu peque habla poquito ofrece actividades simples y efectivas para estimular el lenguaje en niños. Juega con tu hijo, motívalo y celebra cada palabra.",
    "gender": "female",
    "language": "es-ES"
  }
}
```

`estimated_credits: 3` en ambos es una estimación basada en la prueba
previa con este modelo — confirmar con `get_cost: true` antes de cargar
a `queue.json`, porque varía con duración/modo/sonido.

---

## REGLA DE ORO

**NUNCA:**
- ❌ Cambiar `gender` de "female" a "auto" o "male"
- ❌ Usar un modelo distinto al pedido sin confirmación
- ❌ Generar sin correr `queue-plan --balance N` primero
- ❌ Ignorar un error del sandbox (validar `HTTP_STATUS:200`, no asumir que salió bien)
- ❌ Pedir una duración fuera del rango real del modelo esperando que la API avise — la clampea en silencio

**SIEMPRE:**
- ✅ Confirmar balance y plan antes de generar (lote o individual según el tope de 3 créditos)
- ✅ Confirmar cada ítem que supere el tope de lote, uno por uno
- ✅ Trackear en `pipeline-log.jsonl` y `queue.json`
- ✅ Verificar que la voz es FEMENINA
- ✅ Esperar a que el sandbox termine sin errores antes de marcar `completado`

---

## RESUMEN

Este SOP convierte "generar video" en procedimiento reproducible:
- Cada paso tiene validación
- Cada error tiene solución documentada
- Cada asset tiene tracking
- Reproducible en lote, respetando el tope de 3 créditos/generación y el
  balance real disponible

Construido sobre `orchestrator.sh` + `ffmpeg-config.sh` (sandbox) +
Higgsfield MCP + ElevenLabs MCP. Ver `CLAUDE.md` para las reglas
permanentes y `README.md` para la guía de usuario.
