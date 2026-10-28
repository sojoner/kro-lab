# Build context must be the repo root: go.mod replaces github.com/sojoner/kro-lab
# with the local checkout (the cluster-inventory-api provider lives there).
FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
COPY platform-mvp/bucket-binding-controller/go.mod platform-mvp/bucket-binding-controller/go.sum platform-mvp/bucket-binding-controller/
RUN cd platform-mvp/bucket-binding-controller && go mod download
COPY . .
RUN cd platform-mvp/bucket-binding-controller && CGO_ENABLED=0 go build -o /out/bucket-binding-controller .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /out/bucket-binding-controller /bucket-binding-controller
USER nonroot:nonroot
ENTRYPOINT ["/bucket-binding-controller"]
