---
name: memoria
description: Engram, memoria, recuerdos, contexto irrelevante, informacion que nada que ver, se inventa datos, recuerda cosas que no debe, forget, borrar memoria
---

# Memoria (Engram)

Makima guarda recuerdos en Engram y los reinyecta en el system prompt. Si el usuario se
queja de que aparecen datos que no tienen que ver con su pregunta:

- La memoria relevante se selecciona por **solapamiento de terminos**, con un minimo de
  `MAKIMA_MEM_MIN_SHARED_TERMS` (2 por defecto) terminos compartidos.
- Cada recuerdo se corta a `MAKIMA_MEM_CHARS` (260) y se injectan como mucho
  `MAKIMA_MEM_COUNT` (4). Los recuerdos "core" son `MAKIMA_CORE_LIMIT` (6) de 120 chars.
- Si aun asi mete ruido, la causa suele ser que Engram guardo el hecho equivocado.
  Revisa con `GET /observations?project=makima` y borra el que no corresponda.
- No inventes recuerdos: si no esta en el contexto, di que no lo sabes.
