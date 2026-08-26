FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /relay ./cmd/relay

FROM gcr.io/distroless/static-debian12:nonroot
ARG RELAY_INTERNAL_PORT=8080
COPY --from=build /relay /relay
EXPOSE ${RELAY_INTERNAL_PORT}
USER nonroot:nonroot
ENTRYPOINT ["/relay"]
