<div align="center">
  <img src="logo.png" alt="Makima logo" width="180">
  <h1>Makima</h1>
  <p>A self-hosted AI assistant for iOS, built for conversation, voice and everyday tasks.</p>
  <p>
    <img src="https://img.shields.io/badge/iOS-SwiftUI-orange" alt="iOS with SwiftUI">
    <img src="https://img.shields.io/badge/backend-FastAPI-009688" alt="FastAPI backend">
    <img src="https://img.shields.io/badge/models-Ollama-black" alt="Ollama models">
    <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license">
  </p>
</div>

## What is Makima?

Makima is an iOS assistant backed by services you host yourself. It combines streaming chat with local language models, speech transcription and synthesis, persistent memory, and a personal agenda. An optional OpenCode integration adds an agent capable of using tools.

The iOS app is a **modified derivative of [SwiftChat](https://github.com/sachaservan/SwiftChat)** by Sacha Servan-Schreiber, adapted for Makima's self-hosted gateway and features. The server components are maintained separately in this workspace. This description does not imply that the complete Makima workspace is an official GitHub fork or that it is endorsed by SwiftChat's author.

Self-hosting gives you control over where the core services run; it does **not** automatically make every feature private. Optional web search, external model providers, agent tools and deployment integrations can send data to third parties. Review their configuration before enabling them.

## Features

- **Chat:** streaming responses, conversation history, image input with a compatible vision model, and Fast and Normal model modes.
- **Voice:** microphone transcription with whisper.cpp and speech playback with Kokoro.
- **Memory:** Engram stores selected memories separately from conversation history.
- **Agenda:** calendar events, tasks and local reminders, with optional export to Apple Calendar.
- **Agent tools:** optional OpenCode integration, web search and a sandboxed terminal. Availability depends on the deployed services and configuration.
- **Response recovery:** server-side response tracking helps the app reconnect to in-progress responses. Local reminders are not remote push notifications.

## How it works

```text
 iOS app (SwiftUI)
        │ HTTPS + bearer token
        ▼
 FastAPI gateway ─── Ollama (chat / vision models)
        ├────────── whisper.cpp (speech-to-text)
        ├────────── Kokoro (text-to-speech)
        ├────────── Engram (persistent memories)
        ├────────── SQLite (agenda and response data)
        └────────── OpenCode / tools (optional)
```

The app connects to the gateway over HTTPS. The gateway authenticates requests and coordinates the selected services. The server handles model inference and audio processing; the app stores the gateway token in iOS Keychain. Reminders already synchronized to the device can be delivered locally, but require periodic app use to refresh their coverage.

## Technology

| Component | Technology | Purpose |
| --- | --- | --- |
| iOS app | Swift, SwiftUI, Swift Package Manager | Chat, audio and agenda interface |
| Gateway | Python, FastAPI, Uvicorn | Authentication, API and service orchestration |
| Models | Ollama, Qwen 2.5 and Qwen 2.5 VL | Text and image understanding |
| Speech | whisper.cpp, Kokoro, FFmpeg | Transcription and voice playback |
| Persistence | Engram, SQLite, Docker volumes | Memory, agenda and response state |
| Optional tools | OpenCode, SearXNG, sandbox | Agent workflows, search and command execution |
| Infrastructure | Docker Compose, Traefik / Coolify | Service deployment and HTTPS routing |

## Deployment

> The included Compose configuration targets a server with an **existing** Coolify/Traefik proxy and an external Docker network named `coolify`. It is not a turnkey setup for every host. Review the Compose files and adapt routing, storage and permissions to your environment before exposing the service.

### Requirements

- Docker Engine and Docker Compose on a server with enough CPU, RAM and disk for the models. Requirements depend on the models selected; the included Compose file allows Ollama up to 23 GB of RAM.
- A domain pointing to the server, with HTTPS configured through the existing Traefik proxy. The included labels expect `http` and `https` entrypoints and a `letsencrypt` certificate resolver.
- macOS with Xcode compatible with the project's iOS deployment target, and an iOS device or simulator. Check the target and signing settings in Xcode; the current app target is set to iOS 26.6.
- Access to the server and permission to configure its firewall, Docker networks, file ownership and secrets.

### 1. Configure the server

From the project root, create your local configuration:

```sh
cp config/.env.example .env
cp config/user-profile.txt.example config/user-profile.txt
```

Set `MAKIMA_DOMAIN` in `.env` to your own domain. Customize the profile only if needed and keep it private. Create independent random secrets without printing them:

```sh
umask 077
openssl rand -hex 32 > config/makima_token
openssl rand -hex 32 > config/opencode_password
```

The gateway runs as UID/GID `10001`. Ensure that it can read both secret files and write to `data/history` without making those files publicly readable. On a Linux host where those IDs are appropriate, one way is:

```sh
mkdir -p data/history data/sandbox
sudo chgrp 10001 config/makima_token config/opencode_password
chmod 640 config/makima_token config/opencode_password
sudo chown 10001:10001 data/history
```

Adapt ownership for your Docker setup, particularly with rootless Docker or user namespaces. Do not overwrite existing secrets on an active installation: doing so changes the credentials its clients require.

### 2. Build and start core services

After confirming the external `coolify` network and HTTPS proxy exist:

```sh
docker compose build gateway sandbox whisper engram
docker compose up -d ollama

docker compose exec ollama ollama pull qwen2.5vl:7b-q4_K_M
docker compose exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M
```

Download the Whisper model into the named model volume, then start the services:

```sh
docker compose run --rm --entrypoint /bin/sh whisper \
  /usr/local/bin/download-ggml-model.sh large-v3-turbo /models

docker compose up -d gateway engram whisper kokoro
```

Model downloads may be large. The Whisper service expects `/models/ggml-large-v3-turbo.bin`; if downloading fails because of volume permissions, fix the named volume's ownership for the Whisper container's UID `10002`. Check status and logs:

```sh
docker compose ps
docker compose logs --tail=100 gateway whisper engram
```

The base gateway depends on the sandbox service, so Compose may start it as well. The separate `nginx` service publishes port `8085` and is **not** required for the core commands above. Do not expose it without reviewing access and content.

### 3. Configure the iOS app

1. Open `SwiftChat/SwiftChat.xcodeproj` in Xcode and allow Swift packages to resolve.
2. Select your development team and update signing settings for your own device.
3. Build and run the `SwiftChat` scheme.
4. At the connection prompt, enter your gateway's HTTPS domain **without** the scheme and the gateway token from `config/makima_token`. The app stores the token in Keychain.
5. Verify chat, transcription and playback. Enable microphone and notification permissions when needed.

### Optional: Awakenning font

The launch screen uses a system font by default. To use **Awakenning Personal Use** by Billy Argel Fonts instead:

1. Read the author's terms and download the font from the [official font listing](https://www.dafont.com/awakenning.font).
2. Extract the archive and copy `AWAKENNING Personal Use.ttf` into `SwiftChat/SwiftChat/Resources/`.
3. Reopen the Xcode project if needed, verify the font is included in the app target, then rebuild the app.

The font file is intentionally excluded from Git. Its personal-use license does not grant the same rights as the project's MIT license; contact the author for commercial or other non-personal use. Do not commit or redistribute it without permission.

### Change the assistant's personality

For Normal and Fast modes, edit [`config/system-prompt.txt`](config/system-prompt.txt) on the server to describe the assistant's role, tone, language and behavior. For example:

```text
You are a helpful technical assistant. Respond clearly and concisely in English.
Explain tradeoffs and ask for clarification when the request is ambiguous.
```

The gateway reads this file for each response, so an in-place edit normally applies to the next request without rebuilding. If your editor replaces the file rather than editing it in place, recreate the gateway to refresh its Docker bind mount: `docker compose up -d --force-recreate gateway`. Existing memories and the optional private `config/user-profile.txt` are also added as context and may influence responses. Keep personal information and secrets out of the shared prompt.

**Super mode is different:** its personality comes from the OpenCode agent configuration (`opencode.json` in its workspace), not `config/system-prompt.txt`. A generic OpenCode configuration is not yet included; see the optional agent section below.

### Optional: OpenCode agent

`docker-compose.opencode.yml` is an additional, more privileged integration, not a prerequisite for the core stack. It requires a separately reviewed OpenCode configuration, an Engram binary at `bin/engram`, writable workspace directories, a shared Engram volume with compatible ownership and `config/vercel_token` (an empty file if Vercel is not used). The existing local agent configuration is intentionally ignored because it contains personal information; a public generic template is not yet provided. Review the overlay, external providers, tool permissions and network exposure before deploying it.

## Project layout

```text
SwiftChat/                 iOS application and tests
gateway/                   FastAPI gateway, tools and Python tests
config/                    Configuration examples and server configuration
engram/                    Engram container definition
whisper/                   whisper.cpp container definition
opencode/                  Optional OpenCode container definition
scripts/                   Operational and verification scripts
docker-compose.yml         Core service definitions
docker-compose.opencode.yml Optional agent overlay
```

## Development and verification

Install the gateway dependencies and pytest in an isolated Python environment, then run:

```sh
python -m pip install -r gateway/requirements.txt pytest
python -m pytest gateway
```

Open the Xcode project to build or run the iOS test schemes. These checks do not replace on-device testing, a security review or a scan of Git history and release artifacts.

## Security and publication

- Never commit `.env`, tokens, private profiles, user data or backups. Ignore rules do not remove files already tracked in Git.
- Rotate any credential that was previously embedded in source code or an app build; removing it from the source does not revoke it.
- Review tracked files, history and remotes before publishing changes.
- The [SwiftChat README](https://github.com/sachaservan/SwiftChat#license) states that SwiftChat is available under MIT, but its linked `LICENSE` file was not available when checked. Verify the applicable upstream license and preserve its copyright and license notices before distributing the derivative. Other assets, models, services and dependencies may have separate licenses.
- Review exposed ports, agent tool permissions and third-party services before deployment. Do not assume the included configuration is hardened for a public multi-user service.

## Fan project notice

Makima is an unofficial fan project inspired by the character Makima from [*Chainsaw Man*](https://www.viz.com/chainsaw-man), created by Tatsuki Fujimoto. This project is not affiliated with, endorsed by, or sponsored by the creator or rights holders. The character and related intellectual property belong to their respective rights holders. This notice does not grant permission to use or redistribute protected material.

## License

Makima project contributions are made available under the [MIT License](LICENSE). The iOS app derives from [SwiftChat by Sacha Servan-Schreiber](https://github.com/sachaservan/SwiftChat); its upstream licensing and notices must be verified before distribution. Third-party code, fonts, models and assets remain subject to their own licenses and permissions; the MIT license here does not override those terms.

The optional **Awakenning Personal Use** font by Billy Argel Fonts is not distributed with the project. Its [original terms](SwiftChat/SwiftChat/Resources/AWAKENNING-LICENSE.txt) restrict it to personal use and require a separate license for commercial or other non-personal uses; they do not grant the MIT rights described above. The font is available from its [author's listing](https://www.dafont.com/awakenning.font).
