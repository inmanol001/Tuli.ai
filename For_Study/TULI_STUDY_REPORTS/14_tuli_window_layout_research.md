# Tuli Window Layout Research

Fecha de investigación: 2026-06-21  
Alcance: estudiar cómo Tuli puede detectar ventanas visibles, organizar layouts por slots y mover/redimensionar ventanas en macOS sin usar fullscreen nativo.

## Resumen ejecutivo

La forma más sólida de implementar layouts en Tuli es separar el problema en tres capas:

1. **Inventario de ventanas visibles**: descubrir qué ventanas existen, cuáles están realmente visibles y cuáles están disponibles para organización.
2. **Planificador de layout**: decidir qué ventana va a qué slot, con soporte para `left`, `right`, `main` y `free`.
3. **Ejecución segura**: mover y redimensionar con verificación previa, dry-run y registro JSONL.

Mi recomendación es comenzar con **split left/right** y no intentar todavía un gestor genérico de mosaico. Eso reduce riesgo, es más predecible para el usuario y encaja con el flujo que describiste: si ya hay una app ocupando la izquierda, Tuli puede poner la siguiente en el hueco derecho sin pedirte una orden nueva de posición.

## Archivos actuales relacionados

### macOS control

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/macos_control/macos_control.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/macos_control/macos_control_types.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/macos_control/__init__.py`

### Actividad y eventos

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/activity/activity_watcher.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/activity/activity_types.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/events/event_schema.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/events/jsonl_writer.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/actions/event_bridge.py`

### Comandos y brain

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/commands/command_parser.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/commands/command_registry.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/brain.py`
- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/__main__.py`

### Pruebas

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tests/test_core_smoke.py`

## Qué hace hoy Tuli

Hoy Tuli ya tiene una base útil para este proyecto:

- puede observar el estado frontmost de macOS,
- puede abrir aplicaciones,
- puede registrar actividad en JSONL,
- puede emitir eventos derivados de la respuesta,
- y ya tiene una separación conceptual entre comandos, acciones, eventos y observación de sistema.

Lo que todavía no existe es un **gestor de ventanas** como tal. En particular:

- no hay inventario completo de ventanas visibles,
- no hay estado de slots,
- no hay planificador de layout,
- no hay dry-run de colocación,
- no hay comandos de layout en el parser o registry,
- y no hay un módulo dedicado como `mac_window_manager.py`.

## Definición propuesta de “ventana visible”

Para que Tuli actúe de forma útil y no confunda ventanas reales con ventanas ocultas, propongo definir una ventana visible como:

- no minimizada,
- no oculta,
- perteneciente a una app que realmente tiene ventana accesible,
- con bounds que intersectan el área útil de al menos una pantalla,
- y no clasificada por macOS como ventana de sistema no relevante.

En términos prácticos, la lista de “ventanas visibles” debe excluir:

- ventanas minimizadas,
- ventanas completamente fuera de pantalla,
- ventanas que no pueden redimensionarse o moverse,
- y ventanas auxiliares que no representan un documento o vista útil para el usuario.

## Método recomendado para detectar ventanas

### Recomendación principal

Usar **Accessibility API** como fuente principal de inventario y manipulación.

Motivos:

- permite enumerar procesos, ventanas y propiedades relevantes,
- permite mover y redimensionar ventanas de forma más fiable,
- permite distinguir ventanas por app, título, posición y tamaño,
- y es el camino más cercano a una automatización real de layout.

### Fallback de inventario

Usar **CoreGraphics window listing** como respaldo para enumeración visual cuando Accessibility no esté disponible todavía.

Esto sirve para:

- listar ventanas on-screen,
- detectar IDs y títulos de ventanas,
- saber qué ventanas están activas en pantalla,
- y construir una vista preliminar del layout.

### Observación importante

En esta máquina de prueba el entorno mostró límites reales:

- `AXIsProcessTrusted()` no estaba concedido,
- y la captura de ventanas por CoreGraphics con la ruta probada no devolvió un inventario usable.

Conclusión: la arquitectura puede y debe soportar ambos caminos, pero la implementación real tendrá que verificar permisos en el arranque y degradar con claridad si macOS no autoriza observación o control.

## Método recomendado para mover y redimensionar

### Recomendación principal

Mover y redimensionar con **Accessibility**.

Ese método es el más apropiado para:

- cambiar posición,
- cambiar tamaño,
- evitar fullscreen nativo,
- y colocar una ventana en un slot determinado.

### Qué evitar

No basar el layout en fullscreen nativo de macOS.

Motivos:

- fullscreen nativo cambia el espacio de trabajo,
- rompe el modelo de “slot visible”,
- hace más difícil encadenar ventanas en el mismo escritorio,
- y complica mucho el comportamiento de “abrí una app nueva, colócala en el hueco libre”.

### Si Accessibility falla

Se puede usar AppleScript/`System Events` como fallback, pero solo como respaldo.

Ese fallback sirve mejor para:

- traer una app al frente,
- intentar posicionarla,
- y confirmar si la app expone una ventana controlable.

No debería ser el núcleo del sistema de layout porque es menos robusto y algunas apps no cooperan bien.

## Área útil de pantalla

Para calcular el espacio real disponible hay que usar el área útil, no el frame bruto del monitor.

La definición recomendada es:

- restar la menu bar,
- respetar el Dock,
- y trabajar con el `visibleFrame` de la pantalla activa.

Eso hace que el layout no tape elementos del sistema y se vea natural.

## Qué significa “organizar” para Tuli

Para este sistema, “organizar” no debería significar “poner la app en cualquier lugar”.

Debería significar:

- leer el estado actual de slots,
- elegir el slot libre o más conveniente,
- mover la ventana a ese slot,
- y ajustar tamaño para que encaje en el área útil del escritorio.

### Primer comportamiento recomendado

Split simple:

- `left`
- `right`

Flujo esperado:

1. si ya existe una ventana en `left`, Tuli la reconoce,
2. cuando pides “split screen”, Tuli activa el layout,
3. si ya hay una app ocupando `left`, la respeta,
4. la siguiente app se coloca en `right`,
5. si `right` ya está ocupada, se propone reemplazo o un slot libre alternativo.

### Por qué no arrancar con un mosaico complejo

Porque complica demasiado la decisión del slot:

- necesitas reglas de prioridad,
- manejo de múltiples pantallas,
- resolución de conflictos,
- y memoria persistente de layout.

Empezar con dos slots reduce riesgo y ya resuelve el uso real que describiste.

## Estado de slots propuesto

El sistema debería mantener un estado mínimo como este:

- `main`: ventana principal del contexto actual
- `left`: slot izquierdo
- `right`: slot derecho
- `free`: ventana visible pero sin slot asignado

### Reglas sugeridas

- `main` es la ventana activa de referencia.
- `left` y `right` son slots físicos del layout actual.
- `free` guarda ventanas visibles que no pertenecen al layout.
- una ventana puede moverse de `free` a `left` o `right`.
- una ventana no debe duplicarse en dos slots.

## Comandos propuestos

La idea es que Tuli entienda tanto comandos explícitos como frases naturales.

### Comandos nuevos propuestos

- `/windows`
- `/layout`
- `/split`
- `/layout status`
- `/layout dry-run`
- `/layout apply`
- `/layout left`
- `/layout right`
- `/layout place chrome left`
- `/layout place codex right`
- `/layout organize`

### Frases naturales sugeridas

- “Tuli, activa split screen”
- “Pon Chrome a la izquierda”
- “Abre Codex a la derecha”
- “Organiza las ventanas para setup”
- “Pon esta app en el hueco libre”

### Recomendación de diseño

No conviene depender solo de comandos una-a-una.

Lo ideal es que Tuli combine:

- comando de layout general,
- inventario de ventanas visibles,
- y asignación automática al slot libre.

Eso es lo que hace que se sienta inteligente.

## Estructura de archivos recomendada

### Nueva carpeta de layout

Propuesta:

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/layout/`

Archivos sugeridos:

- `__init__.py`
- `layout_types.py`
- `layout_state.py`
- `layout_planner.py`
- `layout_service.py`
- `layout_events.py`

### Nuevo gestor de ventanas

Propuesta:

- `/Users/inma/Documents/Vroid/local_agent/tuli_local_brain_lab/tuli_brain/macos_control/mac_window_manager.py`

Responsabilidades:

- listar ventanas visibles,
- consultar título, app, bounds y flags útiles,
- mover y redimensionar ventanas,
- comprobar si una ventana se puede controlar,
- y exponer resultados seguros para el planificador de layout.

## Eventos JSONL propuestos

Ya existe una base buena para registrar eventos. Para layout, propongo agregar un conjunto específico.

### Tipos de evento sugeridos

- `layout_requested`
- `layout_inventory_snapshot`
- `layout_dry_run_started`
- `layout_dry_run_result`
- `layout_apply_started`
- `layout_slot_assigned`
- `layout_window_moved`
- `layout_window_resized`
- `layout_apply_completed`
- `layout_apply_failed`
- `layout_permission_missing`
- `layout_state_updated`

### Payload mínimo sugerido

Cada evento debería incluir, según corresponda:

- `layout_name`
- `slot`
- `app_name`
- `window_title`
- `window_id`
- `display_id`
- `bounds_before`
- `bounds_after`
- `visible_frame`
- `dry_run`
- `permission_state`
- `reason`
- `result`

### Ejemplo conceptual

```json
{
  "event_type": "layout_slot_assigned",
  "payload": {
    "layout_name": "split",
    "slot": "right",
    "app_name": "Google Chrome",
    "window_title": "YouTube",
    "dry_run": false
  }
}
```

## Detección de permisos necesarios

Para que esto funcione bien en macOS, hay que verificar dos permisos clave:

- **Accessibility**
- **Screen Recording** si se usa enumeración visual por CoreGraphics o se necesitan detalles on-screen confiables

### Qué debe hacer Tuli

- detectar permisos al arrancar,
- registrar cuándo faltan,
- informar de forma clara que solo puede hacer dry-run,
- y evitar intentar una operación que va a fallar silenciosamente.

## Cómo reconocer si una app no permite mover o redimensionar

No todas las apps cooperan igual.

Tuli debe detectar señales como:

- no expone ventana accesible,
- el intento de cambiar bounds no tiene efecto,
- la ventana vuelve a su posición original,
- o Accessibility devuelve error/rechazo.

### Política recomendada

Si una app no se puede mover con confianza:

- marcarla como `locked` o `non_layoutable`,
- dejarla fuera de la estrategia automática,
- y registrar el motivo.

## Dry-run de layout

Esto es importante antes de mover nada.

### Qué debe hacer el dry-run

- listar ventanas visibles,
- calcular el área útil,
- simular asignación de slots,
- verificar colisiones,
- y devolver el plan sin ejecutarlo.

### Qué debería responder

- qué ventana iría a cada slot,
- qué ventanas ya están ocupadas,
- si se necesita cerrar o sustituir algo,
- y qué permisos faltan para aplicar.

Esto te permite decirle a Tuli cosas como:

“muéstrame cómo quedarían Chrome y Codex antes de moverlos”.

## Plan de implementación por fases

### Fase 1: inventario

- crear `mac_window_manager.py`,
- listar ventanas visibles,
- obtener `app`, `title`, `bounds` y `frontmost`,
- ignorar minimizadas e invisibles,
- guardar resultados en JSONL.

### Fase 2: slots y dry-run

- crear estado de `left`, `right`, `main`, `free`,
- simular asignación,
- exponer comandos `/layout status` y `/layout dry-run`,
- no mover todavía.

### Fase 3: mover/redimensionar

- habilitar `apply`,
- mover primero solo una ventana,
- luego dos ventanas en split,
- verificar que el resultado encaje en el `visibleFrame`.

### Fase 4: integración con comandos naturales

- reconocer “split screen”,
- reconocer “pon Chrome a la izquierda”,
- reconocer “abre Codex en el hueco libre”,
- y unirlo con el flujo de abrir apps.

### Fase 5: persistencia y aprendizaje

- guardar layouts recientes,
- recordar ocupación de slots,
- y reutilizar el hueco libre inteligentemente en siguientes órdenes.

## Pruebas necesarias

### Unit tests

- parseo de comandos nuevos,
- resolución de slot,
- cálculo de visible frame,
- planificador de layout,
- serialización de eventos JSONL,
- y degradación cuando faltan permisos.

### Integration tests

- abrir una app,
- inventariar ventanas visibles,
- simular split,
- mover a left/right,
- y validar que no se usa fullscreen nativo.

### Manual tests en macOS

- Chrome en la izquierda,
- otra app en la derecha,
- reabrir una app ya existente sin perder el layout,
- probar una app que no coopera,
- verificar que Dock y menu bar no quedan tapados.

## Riesgos técnicos en macOS

### Riesgo 1: permisos

Sin Accessibility, el movimiento real puede fallar.

### Riesgo 2: ventanas no cooperativas

Algunas apps tienen ventanas protegidas, múltiples ventanas internas o reglas propias de tamaño.

### Riesgo 3: múltiples monitores

Hay que definir si `left/right` se aplica al monitor principal o al monitor activo.

### Riesgo 4: ventana sin título o sin bounds útiles

No todas las ventanas tienen un título claro, y eso exige usar identificadores adicionales.

### Riesgo 5: fullscreen nativo accidental

Hay que evitar que el sistema confunda “maximizar visible” con “activar fullscreen”.

## Recomendación final

Sí es posible hacer el sistema que quieres, y además no necesita ser enredado si se diseña por slots.

Mi recomendación concreta es:

1. implementar primero inventario de ventanas visibles,
2. crear un estado de slots,
3. hacer dry-run,
4. y recién después mover/redimensionar.

Eso permitirá que Tuli entienda instrucciones del tipo:

- “pon Chrome a la izquierda”,
- “ahora abre YouTube y colócalo en el hueco libre”,
- “activa split screen”,
- “organiza mi setup”.

## Siguiente paso sugerido

Cuando quieras, el siguiente documento o tarea puede ser la especificación técnica de:

- `layout_state.py`
- `layout_planner.py`
- `mac_window_manager.py`
- y los nuevos comandos `/layout` y `/windows`.

