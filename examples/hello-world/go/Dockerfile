# syntax=docker/dockerfile:1
# ============================================================================
# Hello-Go — net/http, scratch image (~5 MB final).
# ============================================================================
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/hello-go .

FROM scratch
COPY --from=build /out/hello-go /hello-go
EXPOSE 8080
ENTRYPOINT ["/hello-go"]
