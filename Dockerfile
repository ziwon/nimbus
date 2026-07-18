FROM python:3.13-slim AS build

ARG TARGETARCH=amd64
WORKDIR /src
RUN python -m pip install --no-cache-dir ziglang==0.16.0
COPY build.zig build.zig.zon ./
COPY src ./src
COPY third_party ./third_party
RUN case "$TARGETARCH" in \
      amd64) target="x86_64-linux-musl" ;; \
      arm64) target="aarch64-linux-musl" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    python -m ziglang build -Dtarget="$target" -Doptimize=ReleaseSmall
RUN mkdir /nimbus-data && chown 65532:65532 /nimbus-data

FROM scratch
COPY --from=build /src/zig-out/bin/nimbus /nimbus
COPY --from=build --chown=65532:65532 /nimbus-data /data
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/nimbus"]
CMD ["server", "--bind", "0.0.0.0", "--port", "8080", "--database", "/data/nimbus.db"]
