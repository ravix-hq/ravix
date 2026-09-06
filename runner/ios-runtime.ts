import { lstat, readFile, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { iosArtifact } from './ios-artifact';
import { privateDirectory } from './state';
import type { RuntimeConfig } from './runtime-experiment';

export async function verifyIosBuild(config: RuntimeConfig) {
  await privateDirectory(config.buildDirectory);
  const path = join(config.buildDirectory, 'report.json'), stat = await lstat(path);
  if (!stat.isFile() || stat.size > 1024 * 1024 || await realpath(path) !== path) throw Error('Invalid iOS build report');
  const report = JSON.parse(await readFile(path, 'utf8'));
  const app = join(config.buildDirectory, 'SwitchyardHello.app');
  if (report.kind !== 'ios-build-experiment' || report.platform !== 'ios' || report.account !== config.expectedAccount || report.architecture !== 'arm64' || report.applicationId !== 'com.managoat.switchyard.hello' || report.error !== null || report.artifact?.path !== app || report.artifact?.sha256 !== config.artifactSha256 || !report.phases?.some((p: {name: string; passed: boolean}) => p.name === 'verify-artifact' && p.passed === true) || !/^[a-f0-9]{64}$/.test(report.sourceDigest)) throw Error('Build report does not identify the pinned Hello simulator app');
  const artifact = await iosArtifact(app);
  if (artifact.sha256 !== config.artifactSha256 || artifact.size !== report.artifact.size || artifact.files !== report.artifact.files) throw Error('Simulator app does not match the pinned build digest');
  return { apk: app, sourceDigest: report.sourceDigest as string };
}

/** idb accessibility frames are in simulator points, not encoded-video pixels. */
export function iosNode(hierarchy: string, label: string) {
  if (Buffer.byteLength(hierarchy) > 4 * 1024 * 1024) throw Error('iOS hierarchy exceeded limit');
  const root: unknown = JSON.parse(hierarchy);
  let count = 0;
  const visit = (value: unknown, depth: number): {x:number; y:number} | null => {
    if (++count > 20000 || depth > 32) throw Error('iOS hierarchy exceeded limit');
    if (!value || typeof value !== 'object') return null;
    if (Array.isArray(value)) { for (const child of value) { const found = visit(child, depth + 1); if (found) return found; } return null; }
    const node = value as Record<string, unknown>, frame = node.frame as Record<string, number> | undefined;
    if ((node.AXLabel === label || node.AXValue === label) && frame && [frame.x,frame.y,frame.width,frame.height].every(n => Number.isFinite(n)) && frame.x! >= 0 && frame.y! >= 0 && frame.width! > 0 && frame.height! > 0 && frame.x! + frame.width! <= 4096 && frame.y! + frame.height! <= 4096)
      return {x: frame.x! + frame.width! / 2, y: frame.y! + frame.height! / 2};
    if (Array.isArray(node.children)) return visit(node.children, depth + 1);
    return null;
  };
  return visit(root, 0);
}
export function iosStartupAction(hierarchy: string) {
  const node = (text: string) => iosNode(hierarchy, text);
  // iOS asks before opening the development-client URL on a fresh simulator.
  // The alert can hide the app's own title from the accessibility hierarchy.
  if ((node('Open in “Switchyard Hello”?') || node('Open in "Switchyard Hello"?')) && node('Cancel')) return node('Open');
  if (!node('Switchyard Hello')) return null;
  if (node('This is the developer menu. It gives you access to useful tools in your development builds.')) return node('Continue');
  if (node('Reload') && node('Go home')) return node('Close');
  return null;
}
