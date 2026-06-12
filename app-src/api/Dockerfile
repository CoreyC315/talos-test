FROM golang:1.25-alpine AS build
WORKDIR /src
COPY . .
# go.sum is not committed; resolve and verify dependencies at build time.
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /ks-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /ks-api /ks-api
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/ks-api"]
