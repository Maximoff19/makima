FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 makima && useradd --create-home --uid 10001 --gid 10001 makima
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# skills.py, terminal.py and skills/ are imported by app.py. Without these the image
# builds fine and then dies at startup on ImportError.
COPY skills.py terminal.py mcp.py tools.py opencode_bridge.py agenda.py response_turns.py ./
COPY skills/ ./skills/
USER 10001
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log"]
