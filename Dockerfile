# The Switchyard server (Bun) with the built SPA. The bundle is built by CI
# (bun run build) before docker build, so this image is bun + server/ +
# shared/ + dist/ and multi-arch comes for free. The server has no
# dependencies beyond Bun itself (bun:sqlite is built in) — the Sprites and
# GitHub clients are both a handful of `fetch` calls in server/.
FROM oven/bun:1-alpine
WORKDIR /app
COPY server/ server/
COPY shared/ shared/
COPY dist/ dist/
ENV PORT=8080 DATA_DIR=/data STATIC_DIR=/app/dist
EXPOSE 8080
VOLUME ["/data"]
CMD ["bun", "server/index.ts"]
