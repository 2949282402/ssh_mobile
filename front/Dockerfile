FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

# The Docker context is `front/`; production code must consume the committed,
# self-contained generated catalog rather than reaching outside this context.
COPY . .
RUN test -s src/generated/telemetry_contract.ts \
    && ! grep -R -E '\.\./[^;]*\.json' src
RUN npm run build

FROM nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10

ARG FRONT_INTERNAL_PORT=80
ENV FRONT_INTERNAL_PORT=${FRONT_INTERNAL_PORT}

COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE ${FRONT_INTERNAL_PORT}
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s CMD wget -q -O /dev/null "http://127.0.0.1:$FRONT_INTERNAL_PORT/healthz" || exit 1
