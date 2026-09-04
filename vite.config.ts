import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The browser talks only to the Switchyard server (server/), same origin. It
// never reaches Fountain, GitHub or Sprites directly and holds no credential
// for any of them — see shared/api.ts for why that wall is where it is.
//
// In dev, Vite serves the SPA and forwards the API to the server:
//
//   bun run mock                                   a fake Fountain on :8793
//   FOUNTAIN_URL=http://localhost:8793 bun run server
//   bun run dev                                    this, on :5183
const server = process.env.SWITCHYARD_SERVER ?? "http://localhost:8081";
const appCommit = (process.env.GITHUB_SHA ?? "dev").slice(0, 7);

export default defineConfig({
  base: process.env.VITE_BASE ?? "/",
  define: { __APP_COMMIT__: JSON.stringify(appCommit) },
  plugins: [react()],
  server: {
    port: 5183,
    proxy: {
      "/api": { target: server, changeOrigin: false },
      "/gh": { target: server, changeOrigin: false },
    },
  },
  build: { outDir: "dist", sourcemap: true },
});
