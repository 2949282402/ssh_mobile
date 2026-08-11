FROM node:22-alpine AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM nginx:1.27-alpine

ARG FRONT_INTERNAL_PORT=80
ENV FRONT_INTERNAL_PORT=${FRONT_INTERNAL_PORT}

COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE ${FRONT_INTERNAL_PORT}
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s CMD wget -q -O /dev/null "http://127.0.0.1:$FRONT_INTERNAL_PORT/healthz" || exit 1
