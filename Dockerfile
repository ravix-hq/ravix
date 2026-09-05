# CI builds both the SPA and the server bundle with the workspace lockfile.
# The server bundle includes the npm streaming HTTP/WebSocket implementations.
FROM oven/bun:1-alpine
WORKDIR /app
COPY dist-server/ dist-server/
COPY dist/ dist/
ENV PORT=8080 DATA_DIR=/data STATIC_DIR=/app/dist
EXPOSE 8080 8082
VOLUME ["/data"]
CMD ["bun", "dist-server/index.js"]
