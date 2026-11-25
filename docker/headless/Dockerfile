# syntax=docker/dockerfile:1
# Headless Budgero client (spec §11). SRC_MODE=clone (production) clones the fork at FORK_TAG;
# SRC_MODE=local extracts src.tar written by build-local.sh (fork branch not pushed yet).
ARG SRC_MODE=clone

FROM node:22-alpine AS src-clone
ARG FORK_TAG=headless-v1.22.1-1
RUN apk add --no-cache git && git clone --depth 1 --branch "$FORK_TAG" https://github.com/f-liva/budgero /src

FROM node:22-alpine AS src-local
COPY src.tar /src.tar
RUN mkdir /src && tar -xf /src.tar -C /src && rm /src.tar

FROM src-${SRC_MODE} AS build
WORKDIR /src
RUN corepack enable && corepack prepare pnpm@11.1.2 --activate
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store \
    CI=true pnpm install --frozen-lockfile --prod=false
RUN pnpm --filter @budgero/headless build \
 && mkdir -p /out/node_modules && cp -rL packages/core/node_modules/sql.js /out/node_modules/sql.js

FROM node:22-alpine
ARG FORK_TAG=headless-v1.22.1-1
ARG SOURCE_REVISION=$FORK_TAG
LABEL org.opencontainers.image.source="https://github.com/f-liva/budgero" \
      org.opencontainers.image.revision="$SOURCE_REVISION"
RUN apk add --no-cache busybox-extras \
 && addgroup -g 1001 headless && adduser -D -H -u 1001 -G headless headless
COPY --from=build /src/packages/headless/dist/ /app/dist/
COPY --from=build /out/node_modules/ /app/node_modules/
COPY --from=build --chmod=755 /src/packages/headless/scripts/entrypoint.sh /app/entrypoint.sh
COPY --from=build --chmod=755 /src/packages/headless/scripts/healthz.cgi /src/packages/headless/scripts/status.cgi /app/cgi/
USER 1001
WORKDIR /app
ENV HEADLESS_CONFIG_DIR=/lzcapp/var/headless
EXPOSE 8787
ENTRYPOINT ["/app/entrypoint.sh"]
