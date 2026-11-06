---
name: desplegar-vercel
description: despliega un proyecto en vercel con la CLI, usando deploy temporal si no hay token, o el token de la sesion para un deploy permanente. usar cuando pide publicar, subir, desplegar, deployar, hostear o compartir en vercel, o cuando nombra vercel
---

# Desplegar en Vercel

Alternativa a publicar en el VPS con nginx. La diferencia real no es el hosting: es que **Vercel
puede compilar** (Next.js, Vite, Astro, SvelteKit, React Router) y nginx no, porque no hay paso de
build ahi.

## Cuando usar cada uno

- **nginx / el VPS**: sitio estatico, vive en `YOUR_SERVER_IP:8085`, sin build, sin costo.
- **Vercel**: cuando pide dominio, HTTPS automatico, o el proyecto tiene un framework con build.

## Deploy temporal (funciona siempre, sin cuenta)

Es el camino por defecto. No necesita token y no necesita que Pietoro tenga cuenta:

```
vercel deploy --temporary --yes
```

Devuelve una URL publica que cualquiera puede abrir. **Es temporal y no se puede reclamar desde
la sesion del agente**: si the user quiere quedársela, que la abra, entre a vercel.com y la reclame
con su cuenta.

## Deploy permanente (necesita token)

El token esta en `/run/secrets/vercel_token`. **Ahora esta vacio**, asi que este camino falla con
"No existing credentials found" hasta que the user lo cargue. No lo muestres, no lo escribas en un
proyecto y no lo pegues en la respuesta.

```
vercel --token "$(cat /run/secrets/vercel_token)" --yes --prod
```

## Antes de desplegar

- **No corras `npm install` ni `npm run build` en local.** Vercel compila en sus servidores: vos
  solo subis el codigo fuente. Instalar dependencias aqui waste memoria y fue exactamente lo que
  mata el contenedor (limite de 4 GB) en un proyecto React.
- Un proyecto con framework necesita `package.json` con `build` y `output` correctos, y un
  `vercel.json` si el framework no se autodetecta. Sin eso Vercel no sabe que construir.
- Node 24 y npm 11 estan en la imagen, por si hace falta validar algo puntual.
- Secretos del proyecto (claves de API) van en el panel de Vercel como variables de entorno,
  **nunca** en un archivo del repo ni en el HTML.
- Revisa que no se suban `.env`, claves ni datos personales.

## Si falla

- "No existing credentials found": el token esta vacio o vencio. No reintentes, decile a the user
  que lo cargue. El deploy temporal sigue disponible como alternativa.
- Un 404 en la URL de Vercel significa que no hay deploy: revisa que termine el build.
- El HTML/JS del sitio lo sirve Vercel, no nginx: los archivos en `/workspace/site` no aparecen
  en Vercel y viceversa. Son dos publicaciones distintas del mismo codigo.
