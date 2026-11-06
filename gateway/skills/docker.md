---
name: docker
description: contenedores, imagenes, volumes, redes, compose y despliegue en el VPS
---

# Docker

Al trabajar con Docker, ten en cuenta:

- El host de produccion corre el stack en `/opt/makima` con `docker compose`.
- `makima-gateway-1` es `read_only: true` con `mem_limit: 768m`; los cambios de codigo
  requieren `docker compose up -d --build gateway`, no solo copiar el fichero.
- `engram` usa `network_mode: "service:gateway"`. Recrear el gateway lo deja huerfano y
  todo request devuelve `503 Memory service unavailable`; se recupera con
  `docker compose up -d --force-recreate engram`.
- OLLAMA corre en CPU pura: no asumas GPU.
