# syntax=docker/dockerfile:1
# The build runs on the build host and cross-compiles, so no emulation is needed.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -buildid=" -o /out/notallyxyz-server . \
 && mkdir -p /out/data

# Final image: one static binary, no shell, no package manager.
FROM scratch
COPY --from=build /out/notallyxyz-server /notallyxyz-server
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
ENV DATA_DIR=/data LISTEN_ADDR=:8080 GOMEMLIMIT=192MiB
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=60s --timeout=5s --retries=3 CMD ["/notallyxyz-server", "-healthcheck"]
ENTRYPOINT ["/notallyxyz-server"]
