# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:24.18.0-bookworm-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d

FROM ${NODE_IMAGE} AS api-build
WORKDIR /src/sync-server
COPY sync-server/package.json sync-server/package-lock.json ./
RUN npm ci
COPY sync-server/tsconfig.json sync-server/tsconfig.build.json ./
COPY sync-server/src ./src
COPY sync-server/db ./db
COPY sync-server/docs ./docs
COPY sync-server/openapi ./openapi
RUN npm run build && npm prune --omit=dev

FROM ${NODE_IMAGE} AS web-build
WORKDIR /src/web
COPY web ./
RUN npm ci
COPY domain-spec /src/domain-spec
COPY sync-server/openapi /src/sync-server/openapi
COPY SarosHarmonicJournal/Resources/SolarData /src/SarosHarmonicJournal/Resources/SolarData
COPY SarosHarmonicJournal/Resources/SolarGeoData /src/SarosHarmonicJournal/Resources/SolarGeoData
RUN npm run build && npm prune --omit=dev

FROM ${NODE_IMAGE} AS release
ARG RELEASE_ID=unknown
ARG SOURCE_REVISION=unknown
WORKDIR /release

# The target does not build or install Node packages. The official Linux x64
# Node binary and Linux-native dependencies are shipped in the release.
RUN mkdir -p runtime api web \
  && cp /usr/local/bin/node runtime/node \
  && printf '%s\n' "$RELEASE_ID" > RELEASE_ID \
  && printf '%s\n' "$SOURCE_REVISION" > SOURCE_REVISION

COPY --from=api-build /src/sync-server/dist api/dist
COPY --from=api-build /src/sync-server/db api/db
COPY --from=api-build /src/sync-server/docs api/docs
COPY --from=api-build /src/sync-server/openapi api/openapi
COPY --from=api-build /src/sync-server/package.json api/package.json
COPY --from=api-build /src/sync-server/package-lock.json api/package-lock.json
COPY --from=api-build /src/sync-server/node_modules api/node_modules

COPY --from=web-build /src/web/build web/build
COPY --from=web-build /src/web/packages web/packages
COPY --from=web-build /src/web/package.json web/package.json
COPY --from=web-build /src/web/package-lock.json web/package-lock.json
COPY --from=web-build /src/web/node_modules web/node_modules

RUN chmod 0755 runtime/node \
  && find . -type f ! -name RELEASE.sha256 -print0 \
    | sort -z \
    | xargs -0 sha256sum > RELEASE.sha256
