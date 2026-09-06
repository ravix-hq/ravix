import { checked, type Command } from './process';

export interface IosBuildRuntimeSelection {
  sdk: string; sdkBuild: string; runtime: string; runtimeBuild: string;
  previousBuild: string; previousOverride: string | null; changed: boolean;
}
/** The Hello fixture uses the provisioned iOS 18.6 runtime. Overrides are
 * account-scoped, apply only while Xcode builds, and are restored on failure. */
export async function withIosBuildRuntime<T>(options: {
  run: Command; xcrun: string; env: NodeJS.ProcessEnv; signal?: AbortSignal;
}, work: (selection: IosBuildRuntimeSelection) => Promise<T>): Promise<T> {
  const {run, xcrun, env, signal} = options;
  const probe = (args: string[]) => checked(run, [xcrun, ...args], {env, signal, timeoutMs: 15000});
  const version = (await probe(['--sdk', 'iphonesimulator', '--show-sdk-version'])).toString().trim();
  // This experiment deliberately pins its toolchain instead of guessing which
  // new runtime is compatible when Xcode is upgraded.
  if (version !== '18.5') throw Error('Hello iOS build expects the provisioned Xcode 16.4 / iOS 18.5 SDK');
  const sdk = `iphoneos${version}`;
  const runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-18-6';
  const runtimes = JSON.parse((await probe(['simctl', 'list', 'runtimes', '-j'])).toString());
  const installed = runtimes.runtimes?.find((r: Record<string, unknown>) => r.identifier === runtime && r.isAvailable === true && r.buildversion === '22G86');
  if (!installed) throw Error('Install the provisioned iOS 18.6 (22G86) simulator runtime');
  const mapping = JSON.parse((await probe(['simctl', 'runtime', 'match', 'list', '-j'])).toString())[sdk];
  const valid = (build: unknown): build is string => typeof build === 'string' && /^[A-Za-z0-9]{4,32}$/.test(build);
  if (!mapping || !valid(mapping.sdkBuild) || !valid(mapping.chosenRuntimeBuild) || mapping.userOverriddenBuild !== undefined && !valid(mapping.userOverriddenBuild)) throw Error('Invalid Xcode runtime mapping');
  const selection: IosBuildRuntimeSelection = {sdk, sdkBuild:mapping.sdkBuild, runtime, runtimeBuild:'22G86', previousBuild:mapping.chosenRuntimeBuild, previousOverride:mapping.userOverriddenBuild ?? null, changed:mapping.chosenRuntimeBuild !== '22G86'};
  let restore = false;
  try {
    if (selection.changed) {
      restore = true; // A cancelled command may have changed the preference.
      await probe(['simctl', 'runtime', 'match', 'set', sdk, selection.runtimeBuild, '--sdkBuild', selection.sdkBuild]);
      const applied = JSON.parse((await probe(['simctl', 'runtime', 'match', 'list', '-j'])).toString())[sdk];
      if (applied?.chosenRuntimeBuild !== selection.runtimeBuild) throw Error('Xcode did not select the installed iOS runtime');
    }
    return await work(selection);
  } finally {
    if (restore) {
      // Cleanup must run even if the build's signal is already aborted.
      await checked(run, [xcrun, 'simctl', 'runtime', 'match', 'set', sdk, selection.previousOverride ?? '--default', '--sdkBuild', selection.sdkBuild], {env, timeoutMs:15000});
    }
  }
}
