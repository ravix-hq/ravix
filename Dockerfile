# Render builds this from the repository on every deploy (render.yaml). The
# first stage installs with the workspace lockfile and builds the SPA and the
# server bundle; the runtime image is bun plus those two directories. Tests
# are not run here: CI (.github/workflows/ci.yml) is the gate, and Render is
# told to wait for it.
FROM oven/bun:1-alpine AS build
WORKDIR /app
COPY package.json bun.lock ./
COPY packages/fountain-app/package.json packages/fountain-app/
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build

# The server bundle includes the npm streaming HTTP/WebSocket implementations.
FROM oven/bun:1-alpine
WORKDIR /app
COPY --from=build /app/dist-server/ dist-server/
COPY --from=build /app/dist/ dist/
# One listener: the app and the track-preview gateway share PORT, told apart
# by Host. Render injects its own PORT (10000) over this default. State is in
# the Postgres that DATABASE_URL names; nothing here needs a volume.
ENV PORT=8080 STATIC_DIR=/app/dist
EXPOSE 8080
CMD ["bun", "dist-server/index.js"]
