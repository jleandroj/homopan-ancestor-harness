# OPERATIONS — harness de control de agentes (producción)

Capa de control que asume **mala fe del agente**: registra todo, contiene todo,
reporta todo, y nunca se cae. Componentes nuevos (no protegidos, ya versionados):

| Script | Rol |
| --- | --- |
| `scripts/harness_run.sh` | **Entrypoint único.** run_id + audit JSON append-only (cmd/input/output/dur/exit) + sandbox + ulimits + timeout + kill-switch + reintentos + anomalías. |
| `scripts/hreport.sh` | Reporte automático por corrida (md+json) + digest de sesión + notify. |
| `scripts/haudit_verify.sh` | Verifica la cadena de hash del audit (detecta manipulación). |
| `scripts/notify_hook.sh` | Hook Pre/PostToolUse → pop-up `notify-send` + `logs/activity.feed` por cada acción. |
| `scripts/hwatchdog.sh` | Kill-switch (`kill`/`unkill`/`status`) + reap. |
| `bin/harness-shell.sh` | Lanza la sesión del agente **dentro de bwrap** (sin `$HOME`/secretos). |

## Uso diario

```bash
# correr CUALQUIER comando bajo control total (audit + sandbox + límites + reporte)
scripts/harness_run.sh --label align --timeout 7200 -- minimap2 -cx asm20 a.fa b.fa

# lanzar el agente contenido (sin ~/.ssh, ~/.aws; proyecto RW; red solo para la API)
bin/harness-shell.sh            # = bwrap -> claude

# control en vivo
tail -f logs/activity.feed                 # stream de todo lo que pasa
bash scripts/hwatchdog.sh kill             # CORTAR todo ya (kill-switch)
bash scripts/hwatchdog.sh unkill           # reanudar
bash scripts/haudit_verify.sh              # ¿el audit fue manipulado?
ls .harness/runs/<run_id>/                 # reconstruir una corrida exacta
```

Límites por corrida (env): `HARNESS_CPU_SEC`, `HARNESS_MEM_MB`, `HARNESS_FSIZE_MB`,
`HARNESS_TIMEOUT`, `HARNESS_RETRIES`, `HARNESS_ALLOW_NET=1` (egress allowlist).

---

## Cambios en archivos PROTEGIDOS (los aplica el usuario, no el agente)

El agente está hardline-denegado de editar la superficie de seguridad (correcto).
Aplicá estos cambios a mano y luego `bash init.sh`.

### 1. `.claude/settings.json` — notificación de TODA acción (iter 9)

Reemplazá los bloques `hooks` por (añade el notify hook Pre+Post):

```json
"hooks": {
  "PreToolUse": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash .claude/gate_check.sh" },
      { "type": "command", "command": "bash scripts/notify_hook.sh pre" } ] } ],
  "PostToolUse": [
    { "matcher": "*", "hooks": [
      { "type": "command", "command": "bash .claude/bitacora_log.sh" },
      { "type": "command", "command": "bash scripts/notify_hook.sh post" } ] } ]
}
```

### 2. `.claude/gate_check.sh` — allowlist: exigir el runner para lo pesado (iter 5)

Insertá, dentro del bloque `if [[ "${TOOL}" == "Bash" ]]`, después de las reglas
hardline existentes:

```bash
# Heavy / network tools MUST go through the harness runner (contención total).
# Permitido si la línea invoca scripts/harness_run.sh; si no, DENY.
if grep -Eq '(^|[^a-z])(minimap2|lastz|mashmap|cactus|datasets|nucmer)([^a-z]|$)' <<<"${COMMAND}" \
   && ! grep -Eq 'harness_run\.sh' <<<"${COMMAND}"; then
  echo "DENY: '$(basename "$0")': herramientas de cómputo/red deben correr vía scripts/harness_run.sh." >&2
  echo "Ej: scripts/harness_run.sh --label X -- minimap2 ..." >&2
  exit 2
fi
```

### 3. `init.sh` — hashear los nuevos boundary scripts

Agregá a `BOUNDARY_FILES=( ... )` (en `init.sh` y en `gate_check.sh`, deben coincidir):

```bash
  "${PROJECT_ROOT}/scripts/harness_run.sh"
  "${PROJECT_ROOT}/scripts/hreport.sh"
  "${PROJECT_ROOT}/scripts/haudit_verify.sh"
  "${PROJECT_ROOT}/scripts/notify_hook.sh"
```

### 4. Audit append-only de verdad (iter 10) — tamper-evidence a nivel FS

```bash
touch ~/.harness_audit.jsonl
sudo chattr +a ~/.harness_audit.jsonl   # solo append; ni root reescribe en sitio
```

### 5. Contención real con bwrap — habilitar user namespaces (este host no los tiene)

```bash
# Debian/Ubuntu:
sudo sysctl -w kernel.unprivileged_userns_clone=1
sudo sysctl -w user.max_user_namespaces=15000
```
Sin esto, `sandbox_run.sh` **fail-closed** (rechaza correr sin aislar). Es la
opción segura: preferir que falle a correr sin jaula.

Tras 1–3: `bash init.sh` (regenera el gate pass con los nuevos boundary scripts).

---

## Garantías (orden de prioridad del usuario)

1. **Bitácora** — JSON append-only + hash-chain por línea (`~/.harness_audit.jsonl` + `.harness/runs/<id>/`), verificable con `haudit_verify.sh`.
2. **Reporte** — `hreport.sh` por corrida + `notify-send` + `logs/session_digest.tsv`.
3. **Contención** — `harness_run.sh` (sandbox+ulimits+timeout+kill-switch) + gate allowlist + `harness-shell.sh`.
4. **Trazabilidad** — `run_id` UUID; `.harness/runs/<id>/{audit.jsonl,stdout.log,stderr.log,report.md}`.
5. **Robustez** — reintentos+backoff, `set -uo` (sin `-e`), trap; un fallo del comando nunca tumba el runner.
