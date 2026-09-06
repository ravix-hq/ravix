#!/usr/bin/env bun
import { doctor } from "./doctor";
import { writePrivateJson } from "./state";
import { join } from "node:path";
import { readFile } from "node:fs/promises";
import { experiment, parseExperimentConfig } from "./adapters/experiment";
import { exportSnapshot } from "./snapshot";
import { buildExperiment, parseBuildConfig } from "./build-experiment";
import { runtimeExperiment, parseRuntimeConfig } from "./runtime-experiment";
import { previewExperiment, parsePreviewExperiment } from "./preview-experiment";

async function main() {
  const args = process.argv.slice(2);
  if (args[0] === "preview-experiment" && args.length === 2) {
    const config = parsePreviewExperiment(JSON.parse(await readFile(args[1]!, "utf8")));
    const controller = new AbortController();
    const cancel = () => controller.abort();
    process.on("SIGINT", cancel); process.on("SIGTERM", cancel);
    try {
      const result = await previewExperiment(config, controller.signal);
      console.log(JSON.stringify(result, null, 2));
      process.exitCode = result.report.error ? 1 : 0;
    } finally { process.off("SIGINT", cancel); process.off("SIGTERM", cancel); }
    return;
  }
  if (args[0] === "runtime-experiment" && args.length === 2) {
    const config = parseRuntimeConfig(JSON.parse(await readFile(args[1]!, "utf8")));
    const controller = new AbortController();
    const cancel = () => controller.abort();
    process.on("SIGINT", cancel); process.on("SIGTERM", cancel);
    try {
      const result = await runtimeExperiment(config, controller.signal);
      console.log(JSON.stringify(result, null, 2));
      process.exitCode = result.report.error ? 1 : 0;
    } finally { process.off("SIGINT", cancel); process.off("SIGTERM", cancel); }
    return;
  }
  if (args[0] === "snapshot" && args.length === 3) {
    const snapshot = await exportSnapshot(args[1]!);
    await writePrivateJson(args[2]!, snapshot);
    console.log(JSON.stringify({ file: args[2], digest: snapshot.digest, files: snapshot.files.length }));
    return;
  }
  if (args[0] === "build-experiment" && args.length === 2) {
    const config = parseBuildConfig(JSON.parse(await readFile(args[1]!, "utf8")));
    const controller = new AbortController();
    const cancel = () => controller.abort();
    process.on("SIGINT", cancel); process.on("SIGTERM", cancel);
    try {
      const result = await buildExperiment(config, controller.signal);
      console.log(JSON.stringify(result, null, 2));
      process.exitCode = result.report.error ? 1 : 0;
    } finally { process.off("SIGINT", cancel); process.off("SIGTERM", cancel); }
    return;
  }
  if (args[0] === "doctor" && args.length === 1) {
    const report = await doctor();
    console.log(JSON.stringify(report, null, 2));
    process.exitCode = report.android.prerequisites && report.ios.prerequisites ? 0 : 1;
    return;
  }
  if (args[0] === "experiment" && args.length === 2) {
    const config = parseExperimentConfig(JSON.parse(await readFile(args[1]!, "utf8")));
    const controller = new AbortController();
    const cancel = () => controller.abort();
    process.on("SIGINT", cancel); process.on("SIGTERM", cancel);
    try {
      const inventory = await doctor();
      const result = await experiment(config, controller.signal);
      await writePrivateJson(join(result.directory, "doctor.json"), inventory);
      console.log(JSON.stringify(result, null, 2));
      process.exitCode = result.report.error ? 1 : 0;
    } finally { process.off("SIGINT", cancel); process.off("SIGTERM", cancel); }
    return;
  }
  console.log("Usage: bun run runner/index.ts doctor | experiment <config.json> | snapshot <repository> <output.json> | build-experiment <config.json> | runtime-experiment <config.json>\nDoctor: read-only workstation and native toolchain inventory. Does not register a runner or start devices.");
  if (args.length && args[0] !== "--help") process.exitCode = 2;
}
if (import.meta.main) main().catch(error => { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; });
