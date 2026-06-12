FROM golang:1.25-alpine AS build
WORKDIR /src
COPY . .
# go.sum is not committed; resolve and verify dependencies at build time.
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /ks-worker .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /ks-worker /ks-worker
USER nonroot
EXPOSE 9090
ENTRYPOINT ["/ks-worker"]
