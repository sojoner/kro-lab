# Build context must be the repo root (.)
FROM golang:1.24-alpine AS builder
ENV GOTOOLCHAIN=auto
WORKDIR /src
COPY platform-mvp/token-rotator/go.mod platform-mvp/token-rotator/go.sum ./
RUN go mod download
COPY platform-mvp/token-rotator/ .
RUN CGO_ENABLED=0 go build -o /token-rotator .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /token-rotator /usr/local/bin/token-rotator
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/token-rotator"]