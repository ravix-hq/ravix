import { arch, platform, userInfo } from 'node:os';
import { lstat, readFile, realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { command } from './process';
import { buildEnvironment } from './build-experiment';
import { toolPaths } from './doctor';
import { privateDirectory, writePrivateJson } from './state';

/** Inspect an explicit retained build; never compile, boot or change runtime mappings. */
async function diagnose(account: string, id: string) {
  const user = userInfo();
  if (platform() !== 'darwin' || arch() !== 'arm64' || user.uid === 0 || user.username !== account || !/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(id)) throw Error('Use the dedicated account and an explicit build UUID');
  const directory = join(user.homedir, '.local/share/switchyard/builds', `experiment-${id}`);
  const stat = await lstat(directory);
  if (!stat.isDirectory()) throw Error('Build directory missing');
  await privateDirectory(directory);
  const reportPath = join(directory, 'report.json'), reportStat = await lstat(reportPath);
  if (!reportStat.isFile() || reportStat.size > 1024 * 1024 || await realpath(reportPath) !== reportPath) throw Error('Invalid build report');
  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  if (report.kind !== 'ios-build-experiment' || report.account !== account || report.applicationId !== 'com.managoat.switchyard.hello') throw Error('Not this account’s Hello iOS build');
  const base = {HOME: user.homedir, PATH: `${user.homedir}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: 'en_US.UTF-8'};
  const paths = await toolPaths(base), env = {...buildEnvironment(paths, user.homedir, directory), COCOAPODS_DISABLE_STATS: 'true', RCT_NO_LAUNCH_PACKAGER: '1'};
  const results: Record<string, unknown> = {};
  const probe = async (name: string, argv: string[], summarize?: (text: string) => unknown) => {
    console.log(`iOS diagnostic: ${name}`);
    try {
      const result = await command(argv, {env, cwd: directory, timeoutMs: 60000, maxBytes: 2 * 1024 * 1024});
      const output = result.stdout.toString();
      results[name] = {code: result.code, output: summarize && result.code === 0 ? summarize(output) : output.slice(-16000), stderr: result.stderr.toString().slice(-8000)};
    } catch (error) { results[name] = {error: String(error)}; }
  };
  await probe('firstLaunch', ['xcodebuild', '-checkFirstLaunchStatus']);
  await probe('sdks', ['xcodebuild', '-showsdks']);
  await probe('runtimes', [paths.xcrun, 'simctl', 'list', 'runtimes', '-j'], text => JSON.parse(text).runtimes.map((r: Record<string, unknown>) => ({identifier:r.identifier, version:r.version, build:r.buildversion, available:r.isAvailable, error:r.availabilityError})));
  await probe('runtimeMatches', [paths.xcrun, 'simctl', 'runtime', 'match', 'list', '-j'], JSON.parse);
  await probe('deviceCounts', [paths.xcrun, 'simctl', 'list', 'devices', 'available', '-j'], text => Object.fromEntries(Object.entries(JSON.parse(text).devices).map(([runtime, devices]) => [runtime, (devices as unknown[]).length])));
  const project = ['xcodebuild', '-workspace', join(directory, 'worktree/ios/SwitchyardHello.xcworkspace'), '-scheme', 'SwitchyardHello', '-configuration', 'Debug', '-sdk', 'iphonesimulator'];
  await probe('destinations', [...project, '-showdestinations']);
  await probe('simulatorSettings', [...project, '-destination', 'generic/platform=iOS Simulator', 'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', '-showBuildSettings'], text => text.split('\n').filter(line => /^\s*(SDKROOT|SUPPORTED_PLATFORMS|PLATFORM_NAME|IPHONEOS_DEPLOYMENT_TARGET|ARCHS|EXCLUDED_ARCHS)\s*=/.test(line)));
  await writePrivateJson(join(directory, 'ios-diagnostic.json'), results);
  console.log(JSON.stringify({directory, results}, null, 2));
}
if (import.meta.main) await diagnose(process.argv[2] ?? '', process.argv[3] ?? '');
