# SOP — Generación de Video/Imagen (skill-video-generator)

Procedimiento estándar para llevar un ítem de `queue.json` hasta un asset
final, usando `orchestrator.sh` como director de flujo. `orchestrator.sh`
**nunca invoca Higgsfield, ElevenLabs ni Airtable por sí mismo** — no tiene
credenciales para eso. Cada llamada real la dispara Claude vía MCP; el
script se limita a leer/actualizar `queue.json`, calcular el plan de lote,
generar el comando de mezcla para el sandbox, y loguear resultados.

Este SOP aplica la Regla de Presupuesto y la Nota de Arquitectura de
`CLAUDE.md`. Si algo acá contradice `CLAUDE.md`, gana `CLAUDE.md`.

---

## Prerrequisitos

- `CLAUDE.md`, `higgsfield-config.json`, `elevenlabs-config.json`,
  `ffmpeg-config.sh`, `orchestrator.sh`, `queue.json` presentes en la raíz
  (`orchestrator.sh` lo valida solo en cada comando).
- MCP conectados: Higgsfield siempre; ElevenLabs si el ítem lleva voz.
- Si hace tiempo que no se corre el pipeline, correr primero
  `bash test-pipeline-dry-run.sh` para confirmar que ffmpeg y los archivos
  de config siguen íntegros.

---

## FASE 1 — Planificar el lote (no gasta créditos)

1. Consultar el balance real: `mcp__Higgsfield__balance`.
2. Correr:
   ```bash
   ./orchestrator.sh queue-plan --balance N
   ```
   Marca cada ítem `pendiente` de `queue.json` como uno de:
   - `aprobado_lote` — cabe en el tope de 3 créditos/ítem y en el balance
   - `requiere_confirmacion_individual` — supera 3 créditos/ítem (ej.
     cualquier render real con Cinema Studio 3.0, que arranca en 14)
   - `pendiente_creditos` — no alcanza el balance ahora; no falla, el
     script deja el ítem así y sigue con el resto
   Las exclusiones quedan logueadas automáticamente en `pipeline-log.jsonl`
   (`insufficient_credits` / `exceeds_batch_cap`).
3. Mostrarle al usuario el resumen tal cual lo imprime el comando (ítems a
   generar, créditos totales, tope, balance disponible).
4. Esperar confirmación explícita:
   - Para los `aprobado_lote`: una sola confirmación de lote alcanza
     ("✅ Generar" / "❌ Cancelar").
   - Para los `requiere_confirmacion_individual`: tratarlos aparte, uno
     por uno, con modelo/parámetros/costo exacto — la excepción de lote
     no aplica.
   Sin esa confirmación no se pasa a la Fase 2 bajo ninguna circunstancia.

---

## FASE 2 — Ejecutar cada ítem aprobado (uno por uno)

Por cada ítem `aprobado_lote` (o confirmado individualmente):

1. **Preflight de costo** (recomendado): llamar a `generate_image` /
   `generate_video` con `get_cost: true` y los `params` exactos del ítem.
   Si el costo real difiere del `estimated_credits` de `queue.json`,
   avisar al usuario antes de gastar nada.
2. **Generar el asset**: `mcp__Higgsfield__generate_image` o
   `generate_video` con `model`/`prompt`/`params` del ítem. Poll con
   `jobs_wait` hasta `status: completed`. Guardar el `result_url`.
3. **Si el ítem lleva voz**: `mcp__ElevenLabs__text_to_speech` siguiendo
   `elevenlabs-config.json` (voz femenina conocida, `model_id:
   eleven_multilingual_v2`, `language_code: es`, `body.voice_settings`
   con `stability >= 0.75`). Guardar la URL del audio (ojo: los links de
   ElevenLabs son temporales, ~15 min — seguir con el paso 4 sin demora).
4. **Si hay que mezclar video + audio**:
   1. `mcp__Higgsfield__media_upload` (filename, `content_type:
      video/mp4`) → `upload_url` + `media_id`.
   2. ```bash
      ./orchestrator.sh build-sandbox-cmd \
        --video-url URL --audio-url URL \
        --output archivo.mp4 --upload-url UPLOAD_URL
      ```
      Copiar el texto impreso tal cual como `command` de
      `mcp__Higgsfield__sandbox_exec`.
   3. Verificar `HTTP_STATUS:200` en la salida del sandbox.
   4. `mcp__Higgsfield__media_confirm(media_id, type="video")`.
   5. El `result_url` final es el de ese `media_id` (CDN de Higgsfield).
5. **Si el ítem es solo imagen** (sin audio/mezcla), el `result_url` final
   es directamente el de `generate_image` — se salta el paso 4.
6. **Actualizar la cola**:
   ```bash
   ./orchestrator.sh queue-update --id ID --status completado \
     --result-url URL_FINAL --credits N [--notes "texto"]
   ```
   Esto también escribe el manifest en `output/<id>.json` (el binario
   real queda hosteado en el CDN — este contenedor no puede bajarlo, ver
   Nota de Arquitectura en `CLAUDE.md`).
7. **Registrar en el histórico**:
   ```bash
   ./orchestrator.sh log --product "Nombre" --video-file URL_FINAL \
     --status completed --model MODEL_ID --credits N [--notes "texto"]
   ```
8. **Reportar**: balance actualizado (`mcp__Higgsfield__balance`) y el
   link del resultado.

---

## Manejo de errores (por ítem — no aborta el lote entero)

- **Falla la generación** (job `status: failed`):
  ```bash
  ./orchestrator.sh queue-update --id ID --status fallido --notes "motivo"
  ./orchestrator.sh log --product "Nombre" --video-file "-" \
    --status failed_generation --notes "motivo"
  ```
  Seguir con el siguiente ítem del lote — no frenar todo por uno.
- **Falla la descarga/mezcla en el sandbox** (`curl` sin 200, `ffmpeg`
  con error): mismo tratamiento, `status fallido` / `failed_mix`, seguir
  con el siguiente ítem.
- **Nunca reintentar automáticamente sin avisar** — evita gasto
  duplicado de créditos por un reintento silencioso.

---

## Reglas que este SOP no puede saltarse

- Nunca ejecutar la Fase 2 sin la confirmación explícita de la Fase 1
  (de lote, o individual para lo que la requiera).
- Nunca aprobar de lote un ítem que cueste más de 3 créditos/generación.
- Reportar el balance antes y después de cada generación real.
- Todo procesamiento de archivos (descarga + mezcla) va **siempre** por
  `sandbox_exec` — nunca `curl`/ffmpeg local, el contenedor no tiene
  salida a esos CDN.

---

## Referencias

- `CLAUDE.md` — identidad, reglas permanentes, registro de excepciones.
- `orchestrator.sh` — implementación real de `queue-plan` / `queue-update`
  / `build-sandbox-cmd` / `log` (ver su cabecera para el detalle técnico).
- `ffmpeg-config.sh` — lógica de mezcla de referencia (la ejecuta el
  sandbox, no corre localmente).
- `README.md` — guía de usuario.
