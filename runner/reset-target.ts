import { userInfo } from 'node:os';
import { join } from 'node:path';
import { lstat, open, readFile, rm } from 'node:fs/promises';
import { privateDirectory } from './state';
import { toolEnvironment, toolPaths } from './doctor';
import { checked, command } from './process';

/** Explicit local retirement, after the daemon and all previews have stopped. */
export async function resetTarget(account:string,id:string) {
  const user=userInfo();
  if(process.platform!=='darwin'||user.uid===0||user.username!==account||! /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(id))throw Error('Choose an owned target UUID and the dedicated runner account');
  const root=join(user.homedir,'.local/share/switchyard');
  await privateDirectory(join(root,'managed'));await privateDirectory(join(root,'runtime'));
  const locks:string[]=[];
  try {
    for(const path of [join(root,'managed','runner.lock'),join(root,'runtime','experiment.lock')]) {
      const file=await open(path,'wx',0o600).catch(()=>{throw Error('Stop the runner and active preview before resetting device data');});
      locks.push(path);try{await file.writeFile(JSON.stringify({pid:process.pid,operation:'reset-target',targetId:id})+'\n');}finally{await file.close();}
    }
  const directory=join(root,'managed','targets',id);
  await lstat(directory);await privateDirectory(directory);
  const base={HOME:user.homedir,PATH:`${user.homedir}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`,LANG:'en_US.UTF-8'};
  const tools=await toolPaths(base),env=toolEnvironment(tools,base);
  const android=join(directory,'android-device.json'),ios=join(directory,'ios-device.json');
  const hasAndroid=await Bun.file(android).exists(),hasIos=await Bun.file(ios).exists();
  if(hasAndroid===hasIos)throw Error('Target ownership evidence is incomplete; inspect it before recovery');
  if(hasIos){
    const manifest=JSON.parse(await readFile(ios,'utf8')),set=join(directory,'simulators');
    if(manifest.set!==set||! /^[A-Fa-f0-9-]{36}$/.test(manifest.udid))throw Error('Invalid simulator ownership evidence');
    await privateDirectory(set);
    const argv=[tools.xcrun,'simctl','--set',set];
    const inventory=JSON.parse((await checked(command,[...argv,'list','devices','--json'],{env})).toString());
    const device=inventory.devices?.[manifest.runtime]?.find((d:{udid:string})=>d.udid===manifest.udid);
    if(!device||device.name!==`Switchyard-${id}`||device.state!=='Shutdown')throw Error('Owned simulator is missing or still running; reconcile it first');
    await checked(command,[...argv,'delete',manifest.udid],{env});
  }else{
    const manifest=JSON.parse(await readFile(android,'utf8'));
    if(manifest.name!==`switchyard-${id}`)throw Error('Invalid emulator ownership evidence');
    // The account's one emulator port must be free before removing its disk image.
    const devices=(await checked(command,[tools.adb,'devices'],{env})).toString();
    if(devices.split(/\r?\n/).some(line=>line.startsWith('emulator-5580\t')))throw Error('An emulator is still running; stop it before resetting data');
    await checked(command,[tools.avdmanager,'delete','avd','--name',manifest.name],{env:{...env,ANDROID_USER_HOME:join(directory,'android'),ANDROID_AVD_HOME:join(directory,'avds')}});
  }
  await rm(directory,{recursive:true});
  console.log(`Reset target ${id}. Its next preview will create a fresh device.`);
  } finally { for(const path of locks.reverse())await rm(path); }
}
