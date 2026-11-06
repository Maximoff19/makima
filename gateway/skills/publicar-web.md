---
name: publicar-web
description: publica proyectos, cartas, paginas, landings y sitios web estaticos en el VPS con nginx, escribiendo los archivos en /workspace/site. la ruta es IP mas puerto mas carpeta, tipo YOUR_SERVER_IP:8085/proyecto-web. usar cuando pide crear, publicar, subir, compartir o desplegar en el vps una web, carta, pagina, portfolio o sitio
---

# Publicar web en el VPS con nginx

Escribir el archivo ES publicar. No hay build, no hay deploy, no hay script, no hay shell en el
host: escribis en `/workspace/site` y nginx ya lo esta sirviendo.

## La ruta

```
http://YOUR_SERVER_IP:8085/<carpeta>/
```

IP del VPS, puerto 8085, y la carpeta del proyecto. Sin dominio, sin HTTPS, sin DNS.

## Donde se escribe

- Directorio de publicacion: `/workspace/site`
- Un proyecto = una subcarpeta con `index.html`: `/workspace/site/proyecto-web/index.html`
- Se publica en `http://YOUR_SERVER_IP:8085/proyecto-web/`
- Ese mismo archivo es el proyecto Y el sitio publicado: una sola carpeta, no copies el codigo.

## Reglas

- **El nombre de la carpeta es la URL.** Sin espacios y en minusculas con guiones: "proyecto web"
  se llama `proyecto-web`. Un espacio en la carpeta llega a la URL como `%20` y queda feo.
- **Un proyecto, una subcarpeta.** No escribas archivos sueltos en la raiz: `/carta.html` NO queda
  en `http://YOUR_SERVER_IP:8085/carta/`.
- **Rutas relativas siempre.** `styles.css`, `./img/logo.png`. Si usas un CDN externo, avisale a
  the user que esa pagina depende de un tercero.
- **Sin frameworks ni build.** HTML, CSS y JS planos en archivos sueltos. Nada de `npm install`,
  nada de bundler: no hay paso de build que lo ejecute, asi que un proyecto con `package.json`
  queda sin servir.
- **La raiz del proyecto es su propia carpeta.** CSS, JS e imagenes van junto al `index.html`.

## Verificar

La imagen no tiene `curl`: usa `wget`, que si esta. Comprobalo antes de decirle a the user que esta
publicado:

```
wget -q -O /dev/null http://YOUR_SERVER_IP:8085/<carpeta>/ && echo PUBLICADO || echo NO-HAY-NADA-AHI
```

- **PUBLICADO**: pasale la URL tal cual.
- **NO-HAY-NADA-AHI**: el nombre de la carpeta no coincide con la URL que le vas a dar. Revisalo.

Un fallo de wget significa "no hay nada publicado en esa ruta", no un error del sitio.

## Actualizar

Sobrescribi los archivos y volve a comprobar. No hay cache en el HTML, asi que el cambio se ve
en el primer refresh. Para borrarlo: `rm -rf /workspace/site/<carpeta>`.

## Lo que NO se puede hacer

- No ejecutes `nginx`, `docker`, `systemctl` ni comandos de deploy: no tenes acceso al host.
- No hay `curl`, `node`, `npm`, `git` ni `python` en esta imagen. Para verificar usaras `wget`.
- No escribas fuera de `/workspace/site`. `/workspace` es tu workspace privado y **no** se publica.
- No uses symlinks: nginx los ignora si apuntan fuera de la carpeta de publicacion.
- Para desplegar en Vercel en vez de en el VPS, es otra skill: `desplegar-vercel`.

## Estilo

Aplicas el sistema de diseno de tu prompt (jerarquia por contraste, una fuente, espaciado de 8px,
paleta en 4 capas). Mobile-first: se va a ver en un telefono. Para una carta o presentacion
personal: mucho aire, un titulo grande, tipografia con contraste, nada de emojis en la interfaz.