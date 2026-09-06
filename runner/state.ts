import { lstat, mkdir, open, readFile, readdir, realpath, rename, rm } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";

/** Private, explicitly chosen state. Never reuses a personal SDK device. */
export async function privateDirectory(path: string): Promise<string> {
  if (!isAbsolute(path)) throw new Error("Runner state directory must be absolute");
  await mkdir(path, { recursive: true, mode: 0o700 });
  const stat = await lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0 || (process.getuid && stat.uid !== process.getuid())) {
    throw new Error("Runner state must be a directory owned by this account with mode 0700");
  }
  if (await realpath(path) !== resolve(path)) throw new Error("Runner state must use its real path, without symlink ancestors");
  return path;
}

export async function writePrivateJson(path: string, data: unknown): Promise<void> {
  const temporary = `${path}.${randomUUID()}.tmp`;
  const file = await open(temporary, "wx", 0o600);
  try { await file.writeFile(JSON.stringify(data, null, 2) + "\n"); await file.sync(); }
  finally { await file.close(); }
  try { await rename(temporary, path); } finally { await rm(temporary, { force: true }); }
}

/** Exclusive acquisition, never guessed PID cleanup. A crashed experiment
 * leaves its manifest for targeted recovery instead of attaching to a device. */
export async function acquireExperiment(statePath: string) {
  const root = await privateDirectory(statePath);
  const lockPath = join(root, "experiment.lock");
  const lock = await open(lockPath, "wx", 0o600).catch(() => { throw new Error("An experiment already owns this state directory. Inspect experiment.lock and its manifest before recovery."); });
  const id = randomUUID();
  const directory = join(root, `experiment-${id}`);
  try {
    const retained = (await readdir(root)).filter(name => /^experiment-[a-f0-9-]{36}$/.test(name));
    if (retained.length >= 10) throw new Error("Ten experiment directories retained. For completed runtime evidence, run provision-account.sh <account> --archive-runtime; otherwise review the retained evidence before another experiment.");
    await lock.writeFile(JSON.stringify({ id, pid: process.pid, directory, startedAt: new Date().toISOString() }) + "\n");
    await mkdir(directory, { mode: 0o700 });
  } catch (error) { await lock.close(); await rm(lockPath, { force: true }); throw error; }
  await lock.close();
  return { id, directory, release: () => rm(lockPath) };
}

/** Managed runs retain the newest ten completed reports, with device data elsewhere. */
export async function acquireManagedRun(runtimePath: string, managedPath: string) {
  const root=await privateDirectory(runtimePath), runs=await privateDirectory(join(managedPath,'runs'));
  const lockPath=join(root,'experiment.lock'),lock=await open(lockPath,'wx',0o600).catch(()=>{throw Error('Another preview owns this account; inspect runtime/experiment.lock');});
  const id=randomUUID(),directory=join(runs,`experiment-${id}`);
  try{
    const names=(await readdir(runs)).filter(name=>/^experiment-[a-f0-9-]{36}$/.test(name));
    const completed=[];
    for(const name of names){
      const path=join(runs,name);await privateDirectory(path);
      const report=JSON.parse(await readFile(join(path,'report.json'),'utf8'));
      if(report.cleanup!=='complete')throw Error('A managed run needs cleanup; inspect its retained report');
      completed.push({path,startedAt:String(report.startedAt)});
    }
    completed.sort((a,b)=>a.startedAt.localeCompare(b.startedAt));
    for(const old of completed.slice(0,Math.max(0,completed.length-9)))await rm(old.path,{recursive:true});
    await lock.writeFile(JSON.stringify({id,pid:process.pid,directory,startedAt:new Date().toISOString()})+'\n');
    await mkdir(directory,{mode:0o700});
  }catch(error){await lock.close();await rm(lockPath);throw error;}
  await lock.close();return {id,directory,release:()=>rm(lockPath)};
}
