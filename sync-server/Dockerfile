FROM node:24.11.1-bookworm-slim@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57 AS dependencies

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM dependencies AS build

COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

FROM node:24.11.1-bookworm-slim@sha256:48abc13a19400ca3985071e287bd405a1d99306770eb81d61202fb6b65cf0b57 AS runtime

ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=build /app/dist ./dist
COPY db ./db
COPY docs ./docs
COPY openapi ./openapi

RUN mkdir -p /var/lib/exeligmos/media \
  && chown -R node:node /var/lib/exeligmos

ENV MEDIA_STORAGE_ROOT=/var/lib/exeligmos/media
VOLUME ["/var/lib/exeligmos/media"]

USER node
EXPOSE 8788

CMD ["node", "--enable-source-maps", "dist/server.js"]
