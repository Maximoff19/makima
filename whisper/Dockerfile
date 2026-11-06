FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends git cmake make g++ ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch v1.9.4 https://github.com/ggml-org/whisper.cpp.git /src
RUN cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_SERVER=ON \
    && cmake --build /src/build --config Release -j 4

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl grep libgomp1 && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10002 --create-home whisper
COPY --from=build /src/build/bin/whisper-server /usr/local/bin/whisper-server
COPY --from=build /src/build/bin/lib*.so* /usr/local/lib/
COPY --from=build /src/models/download-ggml-model.sh /usr/local/bin/download-ggml-model.sh
RUN ldconfig && mkdir /models && chown whisper:whisper /models
USER 10002
ENTRYPOINT ["whisper-server"]
CMD ["--host", "0.0.0.0", "--port", "8080", "-m", "/models/ggml-large-v3-turbo.bin", "-l", "auto", "-t", "4", "-ng"]
