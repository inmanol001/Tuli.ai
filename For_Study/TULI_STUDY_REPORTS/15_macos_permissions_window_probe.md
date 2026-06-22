# macOS Permissions + Window Probe

Fecha: 2026-06-21

## Objetivo

Validar una fase mínima y segura antes del sistema de layouts:

- revisar permisos de macOS,
- detectar ventanas visibles,
- leer bounds de ventanas,
- y reportar si falta Accessibility o Screen Recording.

En esta fase no se movieron ni redimensionaron ventanas.

## Archivos creados

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/macos_control/permissions_check.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/macos_control/mac_window_probe.py`

## Archivos tocados

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/macos_control/__init__.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/__init__.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/commands/command_registry.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/commands/permission_guard.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/brain.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tests/test_core_smoke.py`

## Comportamiento implementado

### `/permissions`

El comando ahora devuelve:

- `Accessibility: missing/granted/unknown`
- `Screen Recording: missing/granted/unknown`
- `Automation/System Events: available/missing/unknown`

Además agrega notas claras cuando falta alguno de los permisos.

### `/windows`

El comando intenta listar ventanas visibles sin mover nada.

La salida incluye:

- `app_name`
- `window_title`
- `bounds`
- `is_frontmost`
- `source`

Si no se pueden enumerar ventanas, devuelve un error claro y seguro.

## Permisos detectados en esta máquina

Resultado actual:

- Accessibility: `missing`
- Screen Recording: `missing`
- Automation/System Events: `missing`

## Qué método funcionó

### Permisos

La detección de permisos sí funcionó, y ya no depende de Swift.

Se usa:

- `ctypes` contra `ApplicationServices.framework` para Accessibility,
- `ctypes` contra `CoreGraphics.framework` para Screen Recording,
- y AppleScript/`System Events` como verificación auxiliar para Automation.

### Windows

El probe de ventanas también funciona de forma segura, pero en esta máquina no pudo enumerar ventanas visibles porque faltan permisos.

## Qué método falló

### Quartz / CGWindow

Con Screen Recording en `missing`, Quartz puede devolver vacío o `nil`.

En esta ejecución el resultado fue:

- `source=fallback`
- sin ventanas visibles devueltas

### AX / System Events

Con Accessibility en `missing`, AX no puede inspeccionar ni controlar ventanas.

La ruta de fallback con `System Events` tampoco quedó disponible en esta máquina.

## Comandos probados

- `python3 -m unittest discover -s tests -p 'test_*.py'`
- `python3 -m tuli_brain ask "/permissions"`
- `python3 -m tuli_brain ask "/windows"`

## Resultados de prueba

### Tests

La suite de pruebas pasó:

- `Ran 25 tests in 0.063s`
- `OK`

### `/permissions`

Salida obtenida:

- Accessibility: `missing`
- Screen Recording: `missing`
- Automation/System Events: `missing`

### `/windows`

Salida obtenida:

- `source=fallback`
- error: no fue posible enumerar ventanas visibles

## Próximos pasos para layout split

Con esta fase lista, el siguiente paso seguro es:

1. crear un `layout_state` mínimo con `left`, `right`, `main`, `free`,
2. usar el probe de ventanas como inventario,
3. hacer dry-run del layout split,
4. y solo después implementar el movimiento/redimensionamiento.

## Observación importante

Por ahora Tuli ya puede:

- decir qué permiso falta,
- decir que Quartz/CGWindow puede quedar vacío si falta Screen Recording,
- y decir que AX no puede controlar ventanas si falta Accessibility.

Eso deja el sistema listo para construir el split layout sin adivinar el estado del sistema.

