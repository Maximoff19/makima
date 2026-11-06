"""Run on the VPS after deployment; no results are fabricated or checked in."""

import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen


def command(*args, data=None):
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout.decode().strip()


def post(url, token, body, content_type="application/json"):
    request = Request(url, data=body, headers={"Authorization": f"Bearer {token}", "Content-Type": content_type})
    started = time.monotonic()
    with urlopen(request, timeout=300) as response:
        payload = response.read()
    return round(time.monotonic() - started, 2), payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True, help="HTTPS gateway base URL")
    parser.add_argument("--audio", required=True, type=Path, help="Real Spanish or English voice recording")
    args = parser.parse_args()
    token = Path("config/makima_token").read_text().strip()
    url = args.url.rstrip("/")

    # Ollama's own timing counters, not estimated word counts.
    native = json.loads(command("docker", "compose", "exec", "-T", "gateway", "python", "-c",
        "import json,httpx; r=httpx.post('http://ollama:11434/api/chat',json={'model':'qwen3:30b','messages':[{'role':'user','content':'Makima, responde únicamente Sistema cognitivo operativo.'}],'stream':False,'think':False,'options':{'num_ctx':8192,'num_thread':6}},timeout=300);r.raise_for_status();print(r.text)"))
    llm = {
        "eval_count": native.get("eval_count"),
        "tokens_per_second": round(native["eval_count"] / (native["eval_duration"] / 1e9), 2) if native.get("eval_duration") else None,
        "prompt_eval_seconds": round(native.get("prompt_eval_duration", 0) / 1e9, 2),
        "load_seconds": round(native.get("load_duration", 0) / 1e9, 2),
    }
    request = Request(url + "/v1/responses", data=json.dumps({"model": "makima", "input": "Hola Makima", "stream": True}).encode(),
                      headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    started = time.monotonic()
    first_delta = None
    with urlopen(request, timeout=300) as response:
        for line in response:
            if line.startswith(b"event: response.output_text.delta") and first_delta is None:
                first_delta = round(time.monotonic() - started, 2)
    llm["gateway_time_to_first_text_seconds"] = first_delta

    boundary = "makima-benchmark"
    audio = args.audio.read_bytes()
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{args.audio.name}\"\r\n"
            f"Content-Type: application/octet-stream\r\n\r\n").encode() + audio + f"\r\n--{boundary}--\r\n".encode()
    stt_seconds, transcription = post(url + "/v1/audio/transcriptions", token, body, f"multipart/form-data; boundary={boundary}")
    duration = command("docker", "compose", "exec", "-T", "gateway", "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", "pipe:0", data=audio)
    speech_seconds, speech = post(url + "/v1/audio/speech", token,
        json.dumps({"model": "makima-voice", "voice": "makima", "input": "Hola. Soy Makima y mi sistema de voz está funcionando correctamente."}).encode())
    speech_duration = command("docker", "compose", "exec", "-T", "gateway", "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", "pipe:0", data=speech)
    stats = command("docker", "stats", "--no-stream", "--format", "{{.Name}} {{.MemUsage}} {{.CPUPerc}}")
    system = command("free", "-h") + "\n" + command("uptime") + "\n" + command("swapon", "--show")
    report = (f"# VPS benchmark — {datetime.now(timezone.utc).isoformat()}\n\n"
              f"## Qwen3:30b (local CPU)\n```json\n{json.dumps(llm, indent=2)}\n```\n\n"
              f"## Whisper\nInput: {duration} s; transcription: {stt_seconds} s; text: {json.loads(transcription)['text']}\n\n"
              f"## Kokoro\nOutput duration: {speech_duration} s; complete-response latency: {speech_seconds} s. "
              "Time to first audio is not measured because the gateway currently buffers MP3.\n\n"
              f"## Containers\n```\n{stats}\n```\n\n## System\n```\n{system}\n```\n")
    Path("BENCHMARK.md").write_text(report)
    print("Wrote BENCHMARK.md from live VPS measurements")


if __name__ == "__main__":
    main()
