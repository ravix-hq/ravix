import { afterEach, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { command, type Command } from "./process";
import { doctor, installedSystemImages, toolEnvironment, type ToolPaths } from "./doctor";
import { acquireExperiment, acquireManagedRun, privateDirectory, writePrivateJson } from "./state";
import { experiment, AndroidExperiment, IosExperiment, parseExperimentConfig, type ExperimentConfig } from "./adapters/experiment";
import { iosStartupAction } from "./ios-runtime";

const paths: ToolPaths = { adb: "adb", emulator: "emulator", avdmanager: "avdmanager", scrcpy: "scrcpy", idb: "idb", xcrun: "xcrun", sdk: "/test/sdk" };
const ok = (stdout = "", code = 0) => ({ stdout: Buffer.from(stdout), stderr: Buffer.alloc(0), code });
const cleanup: string[] = [];
afterEach(async () => { for (const path of cleanup.splice(0)) await rm(path, { recursive: true, force: true }); });
async function temp() { const path = await realpath(await mkdtemp(join(tmpdir(), "sy-runner-"))); cleanup.push(path); return path; }
async function config(): Promise<Extract<ExperimentConfig, { platform: "android" }>> {
  return { stateDirectory: await temp(), platform: "android", systemImage: "system-images;android-35;google_apis;arm64-v8a", deviceType: "pixel_7", emulatorPort: 5580, scrcpyVersion: "3.3.1" };
}

test("commands preserve arguments literally without a shell", async () => {
  const text = "hello; $(whoami) `pwd` 'quoted'\nnext";
  const result = await command([process.execPath, "-e", "process.stdout.write(process.argv[1])", text]);
  expect(result.code).toBe(0); expect(result.stdout.toString()).toBe(text);
});

test("output and deadlines are bounded and cancellation terminates work", async () => {
  await expect(command([process.execPath, "-e", "process.stdout.write('x'.repeat(10000)); setInterval(()=>{},1000)"], { maxBytes: 100 })).rejects.toThrow("output bytes");
  await expect(command([process.execPath, "-e", "setInterval(()=>{},1000)"], { timeoutMs: 30 })).rejects.toThrow("exceeded 30 ms");
  const controller = new AbortController();
  const task = command([process.execPath, "-e", "setInterval(()=>{},1000)"], { signal: controller.signal });
  controller.abort(); await expect(task).rejects.toThrow("cancelled");
});

test("capture can finish gracefully on SIGINT and stdin is explicit", async () => {
  const result = await command([process.execPath, "-e", "process.on('SIGINT',()=>{process.stdout.write('finished');process.exit(0)});setInterval(()=>{},1000)"], { interruptAfterMs: 300, timeoutMs: 3000 });
  expect(result.code).toBe(0); expect(result.stdout.toString()).toBe("finished");
  const input = await command([process.execPath, "-e", "process.stdin.pipe(process.stdout)"], { input: "no\n" });
  expect(input.stdout.toString()).toBe("no\n");
});

test("inventory does not boot devices, start adb, install tools or claim live readiness", async () => {
  const calls: string[][] = [];
  const run: Command = async argv => {
    calls.push(argv);
    if (argv.includes("runtimes")) return ok(JSON.stringify({ runtimes: [
      { isAvailable: true, identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-6", name: "iOS 18.6", version: "18.6" },
      { isAvailable: false, identifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-0", name: "unavailable", version: "17.0" },
      { isAvailable: true, identifier: "com.apple.CoreSimulator.SimRuntime.tvOS-18-0", name: "tvOS", version: "18.0" },
    ] }));
    if (argv.includes("devicetypes")) return ok(JSON.stringify({ devicetypes: [{ identifier: "phone", name: "iPhone 16" }] }));
    if (argv.includes("-list-avds")) return ok("Pixel\n");
    return ok("version 1");
  };
  const report = await doctor(run, paths);
  expect(report.ios.runtimes.map(r => r.name)).toEqual(["iOS 18.6"]);
  expect(report.android.profiles).toEqual(["Pixel"]);
  expect(report.livePreviewVerified).toBe(false);
  expect(calls.filter(c => c[0] === "adb")).toEqual([["adb", "version"]]);
  expect(calls.some(c => c.some(a => ["boot", "install", "create", "devices", "connect"].includes(a)))).toBe(false);
});

test("missing SDK and malformed simulator output are explicit failures", async () => {
  const run: Command = async argv => {
    if (argv[0] === "adb") throw new Error("SDK missing");
    if (argv.includes("runtimes")) return ok("not json");
    return ok("", 1);
  };
  const report = await doctor(run, paths);
  expect(report.android.prerequisites).toBe(false);
  expect(report.android.blockers.join("\n")).toContain("SDK missing");
  expect(report.ios.prerequisites).toBe(false);
  expect(report.tools.iosRuntimes?.error).toBe("Tool did not return valid JSON");
});

test("emulator inventory serializes startup probes and retains failures and timings", async () => {
  let active = 0, peak = 0;
  const calls: string[] = [];
  const run: Command = async (argv, options) => {
    if (argv[0] !== paths.emulator) return ok("{}", 1);
    calls.push(argv[1]!);
    expect(options?.timeoutMs).toBe(60_000);
    active++; peak = Math.max(peak, active);
    await Bun.sleep(5);
    active--;
    if (argv[1] === "-version") throw new Error("Command exceeded 60000 ms");
    return ok(argv[1] === "-list-avds" ? "Pixel\n" : "Hypervisor.Framework available");
  };
  const report = await doctor(run, paths);
  expect(peak).toBe(1);
  expect(calls).toEqual(["-version", "-accel-check", "-list-avds"]);
  expect(report.tools.emulator?.available).toBe(false);
  expect(report.tools.emulator?.timeoutMs).toBe(60_000);
  expect(report.tools.emulator?.elapsedMs).toBeGreaterThanOrEqual(0);
  expect(report.tools.acceleration?.available).toBe(true);
  expect(report.android.profiles).toEqual(["Pixel"]);
  expect(report.android.blockers).toContain("emulator: Command exceeded 60000 ms");
  expect(report.livePreviewVerified).toBe(false);
});

test("private state refuses shared permissions and symbolic links", async () => {
  const dir = await temp();
  await chmod(dir, 0o755); await expect(privateDirectory(dir)).rejects.toThrow("0700");
  await chmod(dir, 0o700); await expect(privateDirectory(dir)).resolves.toBe(dir);
  const link = join(await temp(), "link"); await symlink(dir, link);
  await expect(privateDirectory(link)).rejects.toThrow();
  await expect(privateDirectory("relative")).rejects.toThrow("absolute");
});

test("exclusive state acquisition preserves private evidence after release", async () => {
  const dir = await temp(); const first = await acquireExperiment(dir);
  await expect(acquireExperiment(dir)).rejects.toThrow("already owns");
  const report = join(first.directory, "report.json"); await writePrivateJson(report, { owned: first.id });
  expect((await stat(report)).mode & 0o777).toBe(0o600);
  await first.release(); expect(JSON.parse(await readFile(report, "utf8"))).toEqual({ owned: first.id });
  const second = await acquireExperiment(dir); expect(second.id).not.toBe(first.id); await second.release();
});

test("experiment config cannot select arbitrary executables, devices or flags", async () => {
  const c = await config(); expect(parseExperimentConfig(c)).toEqual(c);
  for (const patch of [{ deviceType: "--force" }, { emulatorPort: 5555 }, { emulatorPort: 0 }, { systemImage: "../../other" }, { scrcpyVersion: "3.3.1;whoami" }, { platform: "desktop" }, { stateDirectory: "relative" }]) {
    expect(() => parseExperimentConfig({ ...c, ...patch })).toThrow();
  }
});

test("occupied Android device is never adopted, controlled or stopped", async () => {
  const c = await config(); const calls: string[][] = [];
  const run: Command = async argv => { calls.push(argv); return ok(argv[0] === "scrcpy" ? "scrcpy 3.3.1\n" : `List of devices attached\nemulator-${c.emulatorPort}\tdevice\n`); };
  const result = await experiment(c, undefined, run, paths);
  expect(result.report.error).toContain("occupied");
  expect(calls).toEqual([["scrcpy", "--version"], ["adb", "devices"]]);
  expect(result.report.browserVerified).toBe(false); expect(result.report.cleanup).toBe("complete");
});

test("scrcpy version mismatch fails before device creation", async () => {
  const c = await config(); const calls: string[][] = [];
  const result = await experiment(c, undefined, async argv => { calls.push(argv); return ok("scrcpy 4.0\n"); }, paths);
  expect(result.report.error).toContain("version"); expect(calls).toHaveLength(1);
});

test("failed Android boot cleans only its owned AVD and retains cleanup failures", async () => {
  const c = await config(); const calls: string[][] = [];
  const run: Command = async (argv, options) => {
    calls.push(argv);
    if (argv[0] === "scrcpy") return ok("scrcpy 3.3.1\n");
    if (argv[0] === "emulator") return new Promise((_, reject) => options!.signal!.addEventListener("abort", () => reject(new Error("cancelled")), { once: true }));
    if (argv.includes("wait-for-device")) throw new Error("boot failed");
    if (argv.includes("delete")) return ok("", 1);
    return ok();
  };
  const result = await experiment(c, undefined, run, paths);
  expect(result.report.error).toContain("boot failed"); expect(result.report.cleanup).toContain("failed");
  const create = calls.find(c => c.includes("create"))!, remove = calls.find(c => c.includes("delete"))!;
  expect(create[create.indexOf("--name") + 1]).toBe(remove[remove.indexOf("--name") + 1]);
  expect(remove.join(" ")).not.toContain("all"); expect(calls.some(c => c.includes("kill-server"))).toBe(false);
  const lock = JSON.parse(await readFile(join(c.stateDirectory, "experiment.lock"), "utf8"));
  expect(lock.directory).toBe(result.directory);
});

test("iOS cleanup uses only its private set and created UDID", async () => {
  const calls: string[][] = []; const udid = "11111111-2222-3333-4444-555555555555";
  const short = await mkdtemp(process.platform === "darwin" ? "/private/tmp/sy-" : "/tmp/sy-"); cleanup.push(short);
  const run: Command = async argv => {
    calls.push(argv);
    if (argv.includes("create")) return ok(udid);
    if (argv.includes("boot")) throw new Error("boot failure");
    return ok();
  };
  const result = await experiment({ stateDirectory: short, platform: "ios", deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-16", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-6" }, undefined, run, paths);
  expect(result.report.error).toBe("boot failure"); expect(result.report.cleanup).toBe("complete");
  for (const argv of calls.filter(c => c[0] === "xcrun")) {
    expect(argv[2]).toBe("--set"); expect(argv[3]).toBe(join(result.directory, "simulators"));
    expect(argv).not.toContain("booted"); expect(argv).not.toContain("all");
  }
  expect(calls.filter(c => c.includes("delete"))[0]?.at(-1)).toBe(udid);
});


test("iOS dialog accessibility points become integer idb tap coordinates", async () => {
  // Actual iOS 18.6 confirmation geometry from the dedicated-account run.
  const hierarchy = JSON.stringify([
    { AXLabel: 'Open in “Switchyard Hello”?', frame: { x: 77.66666666666666, y: 406, width: 237.99999999999997, height: 20.333333333333314 } },
    { AXLabel: 'Cancel', frame: { x: 61.66666666666666, y: 446.6666666666667, width: 135, height: 44 } },
    { AXLabel: 'Open', frame: { x: 197.00000000000003, y: 446.6666666666667, width: 134.66666666666666, height: 44 } },
  ]);
  const calls: string[][] = [], directory = await temp();
  const run: Command = async (argv, options) => {
    calls.push(argv);
    if (argv.includes('create')) return ok('11111111-2222-3333-4444-555555555555');
    if (argv.includes('--grpc-domain-sock')) return new Promise((_, reject) => options!.signal!.addEventListener('abort', () => reject(Error('cancelled')), { once: true }));
    return ok();
  };
  const adapter = new IosExperiment({ stateDirectory: directory, platform: 'ios', deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-18-6' }, 'fixture', directory, paths, run);
  try {
    await adapter.boot();
    const point = iosStartupAction(hierarchy)!;
    expect(point).not.toBeNull();
    await adapter.tap(point.x, point.y);
    expect(calls.find(argv => argv.includes('tap'))?.slice(-4)).toEqual(['ui', 'tap', '264', '469']);
    await adapter.tap(100, 200);
    expect(calls.at(-1)?.slice(-2)).toEqual(['100', '200']);
    const count = calls.length;
    for (const [x, y] of [[NaN, 1], [1, Infinity], [-1, 1], [1, 4096]]) await expect(adapter.tap(x!, y!)).rejects.toThrow('Invalid iOS tap');
    expect(calls).toHaveLength(count);
  } finally { await adapter.stop(); }
});

test("retained experiment quota refuses new work without leaving a stale lock", async () => {
  const dir = await temp();
  for (let i = 0; i < 10; i++) await mkdir(join(dir, `experiment-${crypto.randomUUID()}`));
  await expect(acquireExperiment(dir)).rejects.toThrow("Ten experiment directories");
  await expect(readFile(join(dir, "experiment.lock"))).rejects.toThrow();
});


test("Android readiness inventories installed images without requiring a disposable AVD", async () => {
  const sdk = await temp();
  const image = join(sdk, "system-images/android-35/google_apis/arm64-v8a");
  await mkdir(image, { recursive: true });
  expect(await installedSystemImages(sdk)).toEqual([]);
  await writeFile(join(image, "source.properties"), "Pkg.Revision=9\n");
  expect(await installedSystemImages(sdk)).toEqual(["system-images;android-35;google_apis;arm64-v8a"]);
});

test("tool environment adds Java and SDK commands without changing the caller's environment", () => {
  const base = { PATH: "/usr/bin", HOME: "/account", KEPT: "value" };
  const env = toolEnvironment({ ...paths, adb: "/sdk/platform-tools/adb", javaHome: "/java" }, base);
  expect(env.JAVA_HOME).toBe("/java"); expect(env.PATH).toContain("/sdk/platform-tools");
  expect(env.PATH?.startsWith("/java/bin:")).toBe(true); expect(env.HOME).toBe("/account");
  expect(base).toEqual({ PATH: "/usr/bin", HOME: "/account", KEPT: "value" });
});

test('retained iOS targets reuse only their own shutdown simulator and preserve data',async()=>{
  const root=await temp(),runtime='com.apple.CoreSimulator.SimRuntime.iOS-18-6',deviceType='com.apple.CoreSimulator.SimDeviceType.iPhone-16';
  const devices=new Map<string,{udid:string;name:string;state:string;isAvailable:boolean}>(),calls:string[][]=[];
  const run:Command=async(argv,options)=>{
    calls.push(argv);
    const set=argv.includes('--set')?argv[argv.indexOf('--set')+1]!:'',device=devices.get(set);
    if(argv.includes('create')){const udid=crypto.randomUUID();devices.set(set,{udid,name:argv[argv.indexOf('create')+1]!,state:'Shutdown',isAvailable:true});return ok(udid);}
    if(argv.includes('list'))return ok(JSON.stringify({devices:{[runtime]:device?[device]:[]}}));
    if(argv.includes('boot'))device!.state='Booted';
    if(argv.includes('shutdown'))device!.state='Shutdown';
    if(argv.includes('--grpc-domain-sock'))return new Promise((_,reject)=>options!.signal!.addEventListener('abort',()=>reject(Error('stopped')),{once:true}));
    return ok();
  };
  const one=join(root,'one'),two=join(root,'two');await mkdir(one,{mode:0o700});await mkdir(two,{mode:0o700});
  const adapter=(directory:string,id:string)=>new IosExperiment({platform:'ios',stateDirectory:directory,runtime,deviceType},id,directory,paths,run,undefined,{},60000,true);
  const a=adapter(one,'one');await a.boot();await writeFile(join(one,'simulators','app-data.txt'),'track one');await a.stop();
  const b=adapter(two,'two');await b.boot();await writeFile(join(two,'simulators','app-data.txt'),'track two');await b.stop();
  const resumed=adapter(one,'one');await resumed.boot();await resumed.stop();
  expect(calls.filter(c=>c.includes('create'))).toHaveLength(2);
  expect(calls.some(c=>c.includes('delete')||c.includes('erase')||c.includes('all')||c.includes('booted'))).toBe(false);
  expect(await readFile(join(one,'simulators','app-data.txt'),'utf8')).toBe('track one');
  expect(await readFile(join(two,'simulators','app-data.txt'),'utf8')).toBe('track two');
  devices.get(join(one,'simulators'))!.state='Booted';
  const occupied=adapter(one,'one');await expect(occupied.boot()).rejects.toThrow('still running');await occupied.stop();
});

test('managed retention bounds reports without evicting target data and shares the experiment lock',async()=>{
  const root=await temp(),runtime=join(root,'runtime'),managed=join(root,'managed');
  await mkdir(managed,{mode:0o700});await mkdir(join(managed,'targets'),{mode:0o700});await writeFile(join(managed,'targets','data'),'keep');
  const reports:string[]=[];
  for(let i=0;i<11;i++){
    const run=await acquireManagedRun(runtime,managed);reports.push(run.directory);
    await expect(acquireExperiment(runtime)).rejects.toThrow('already owns');
    await writePrivateJson(join(run.directory,'report.json'),{startedAt:String(i).padStart(2,'0'),cleanup:'complete'});await run.release();
  }
  expect(await Bun.file(join(reports[0]!,'report.json')).exists()).toBe(false);
  expect(await Bun.file(join(reports[1]!,'report.json')).exists()).toBe(true);
  expect(await readFile(join(managed,'targets','data'),'utf8')).toBe('keep');
  const broken=await acquireManagedRun(runtime,managed);await writePrivateJson(join(broken.directory,'report.json'),{cleanup:'failed'});await broken.release();
  await expect(acquireManagedRun(runtime,managed)).rejects.toThrow('needs cleanup');
});

test('retained Android targets reuse private AVDs and install without clearing app data',async()=>{
  const root=await temp(),calls:string[][]=[];
  const run:Command=async(argv,options)=>{
    calls.push(argv);
    if(argv[0]==='scrcpy')return ok('scrcpy 3.3.1');
    if(argv[0]==='emulator')return new Promise((_,reject)=>options!.signal!.addEventListener('abort',()=>reject(Error('stopped')),{once:true}));
    if(argv.includes('getprop'))return ok('1');
    if(argv.includes('emu')){const avds=options!.env!.ANDROID_AVD_HOME!;return ok('switchyard-'+avds.split('/').at(-2)+'\nOK');}
    return ok();
  };
  const one=join(root,'one'),two=join(root,'two');await mkdir(one,{mode:0o700});await mkdir(two,{mode:0o700});
  const base=await config();
  const adapter=(directory:string,id:string)=>new AndroidExperiment({...base,stateDirectory:directory},id,directory,paths,run,undefined,{},60000,true);
  const a=adapter(one,'one');await a.boot();await a.installHello('/build/app.apk');await writeFile(join(one,'avds','data'),'track one');await a.stop();
  const b=adapter(two,'two');await b.boot();await b.stop();
  const resumed=adapter(one,'one');await resumed.boot();await resumed.installHello('/build/app.apk');await resumed.stop();
  expect(calls.filter(c=>c.includes('create'))).toHaveLength(2);
  expect(calls.filter(c=>c.includes('install')).every(c=>c.includes('-r'))).toBe(true);
  expect(calls.some(c=>c.includes('delete')||c.includes('wipe-data')||c.includes('clear'))).toBe(false);
  expect(await readFile(join(one,'avds','data'),'utf8')).toBe('track one');
});
