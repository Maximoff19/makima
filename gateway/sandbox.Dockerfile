# Read-only inspection sandbox. Kept deliberately small: it runs shell commands, so every
# package added here is attack surface. procps for ps, nothing else.
FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends procps coreutils \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10002 sandbox
WORKDIR /app
COPY sandbox-requirements.txt .
RUN pip install --no-cache-dir -r sandbox-requirements.txt
COPY app.py terminal.py sandbox.py ./
USER 10002
CMD ["uvicorn", "sandbox:app", "--host", "0.0.0.0", "--port", "8001", "--workers", "1", "--no-access-log"]
