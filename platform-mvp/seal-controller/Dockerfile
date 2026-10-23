FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /seal-controller .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /seal-controller /seal-controller
ENTRYPOINT ["/seal-controller"]