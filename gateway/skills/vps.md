---
name: vps
description:iagnostico y operacion del servidor makima, contenedores, logs y recursos
---

# VPS makima

- Host con 8 nucleos, 32 GB RAM, **sin GPU**. Toda inferencia es CPU.
- Servicios: gateway, ollama, engram, whisper, kokoro, searxng.
- RAM justa: con dos modelos residentes (9b + 4b) quedan ~13 GB disponibles.
- Carga tipica con inferencia activa: load average 6-8 sobre 8 nucleos.
- Backups de compose/app.py en `/opt/makima/backups/`.
