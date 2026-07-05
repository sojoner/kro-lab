# Build context must be the repo root (../.. relative to this file), since
# platform-mvp/binding-controller/go.mod replaces github.com/sojoner/kro-lab
# with the root module via a local path.
FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
COPY platform-mvp/binding-controller/go.mod platform-mvp/binding-controller/go.sum platform-mvp/binding-controller/
RUN cd platform-mvp/binding-controller && go mod download
COPY . .
RUN cd platform-mvp/binding-controller && CGO_ENABLED=0 go build -o /out/binding-controller .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /out/binding-controller /binding-controller
USER nonroot:nonroot
ENTRYPOINT ["/binding-controller"]
