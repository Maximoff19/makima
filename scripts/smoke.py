"""Authenticated integration checks against a running private VPS stack."""

import argparse
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def send(url, token, payload, content_type="application/json"):
    headers = {"Content-Type": content_type}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urlopen(Request(url, data=payload, headers=headers), timeout=300) as response:
        return response.read()


def json_request(base, token, route, data):
    return json.loads(send(base + route, token, json.dumps(data).encode()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--audio-es", type=Path, required=True)
    parser.add_argument("--audio-en", type=Path, required=True)
    args = parser.parse_args()
    base = args.url.rstrip("/")
    token = Path("config/makima_token").read_text().strip()
    try:
        json_request(base, None, "/v1/responses", {"model": "makima", "input": "Hola"})
        raise AssertionError("Unauthenticated requests must not succeed")
    except HTTPError as exc:
        assert exc.code == 401

    response = json_request(base, token, "/v1/responses", {"model": "makima", "input": "Makima, responde únicamente Sistema cognitivo operativo."})
    assert "Sistema cognitivo operativo" in response["output"][0]["content"][0]["text"]

    json_request(base, token, "/v1/responses", {"model": "makima", "input": "Makima, recuerda que mi proyecto Atlas utiliza Go y PostgreSQL."})
    fresh = json_request(base, token, "/v1/responses", {"model": "makima", "input": "¿Qué tecnologías utiliza Atlas?"})
    assert "Go" in fresh["output"][0]["content"][0]["text"]
    assert "PostgreSQL" in fresh["output"][0]["content"][0]["text"]

    for language, audio in (("es", args.audio_es), ("en", args.audio_en)):
        boundary = "makima-smoke-boundary"
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n{language}\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{audio.name}\"\r\n"
                "Content-Type: application/octet-stream\r\n\r\n").encode() + audio.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        transcript = json.loads(send(base + "/v1/audio/transcriptions", token, body, f"multipart/form-data; boundary={boundary}"))["text"]
        assert transcript.strip(), f"Empty transcription for {language}"
        print(f"{language} transcript (review manually for accuracy): {transcript}")

    mp3 = send(base + "/v1/audio/speech", token, json.dumps({"model": "makima-voice", "voice": "makima", "input": "Hola. Soy Makima y mi voz funciona."}).encode())
    assert mp3[:3] == b"ID3" or (len(mp3) > 2 and mp3[0] == 0xFF and mp3[1] & 0xE0 == 0xE0), "TTS did not return MP3 audio"
    print("Authenticated text, memory across fresh conversations, local audio routes and MP3 passed.")
    print("Still required: visual/voice validation on iPhone, load testing, and post-reboot checks.")


if __name__ == "__main__":
    main()
