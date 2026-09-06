import {afterEach, expect, test} from 'bun:test';
import {chmod, mkdtemp, mkdir, realpath, rm, symlink, writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {iosArtifact} from './ios-artifact';
import {verifyIosBuild} from './ios-runtime';
import {parseBuildConfig} from './build-experiment';
const roots: string[] = [];
afterEach(async () => {for (const root of roots.splice(0)) await rm(root,{recursive:true,force:true});});
async function fixture() {const root=await realpath(await mkdtemp(join(tmpdir(),'sy-ios-artifact-')));roots.push(root);const app=join(root,'Hello.app');await mkdir(app);await writeFile(join(app,'Hello'),'executable');await chmod(join(app,'Hello'),0o755);await writeFile(join(app,'Info.plist'),'fixture');return app;}
test('simulator bundle identity detects changed bytes, paths and executable permissions', async () => {
  const app=await fixture(), initial=await iosArtifact(app);
  expect(initial.files).toBe(2); expect(initial.size).toBe(17);
  expect((await iosArtifact(app)).sha256).toBe(initial.sha256);
  await chmod(join(app,'Hello'),0o644);
  expect((await iosArtifact(app)).sha256).not.toBe(initial.sha256);
  await chmod(join(app,'Hello'),0o755);
  await writeFile(join(app,'Hello'),'altered!!!');
  expect((await iosArtifact(app)).sha256).not.toBe(initial.sha256);
  await mkdir(join(app,'Resources'));await writeFile(join(app,'Resources','asset'),'image');
  expect((await iosArtifact(app)).files).toBe(3);
});
test('bundle verification rejects links, empty bundles and non-directory roots', async () => {
  const app=await fixture();await symlink('/etc/passwd',join(app,'escape'));
  await expect(iosArtifact(app)).rejects.toThrow('link');
  await rm(join(app,'escape'));await symlink(app,app+'-link');
  await expect(iosArtifact(app+'-link')).rejects.toThrow('directory');
  await expect(iosArtifact(join(app,'Hello'))).rejects.toThrow('directory');
  await rm(app,{recursive:true});await mkdir(app);
  await expect(iosArtifact(app)).rejects.toThrow('Empty');
});
test('build target is explicit and keeps the existing Android config compatible', () => {
  const config={snapshot:'/private/snapshot.json',stateDirectory:'/Users/switchyard/builds',expectedAccount:'switchyard'};
  expect(parseBuildConfig(config)).toEqual(config);
  expect(parseBuildConfig({...config,platform:'ios'}).platform).toBe('ios');
  expect(()=>parseBuildConfig({...config,platform:'macos'})).toThrow('android or ios');
});

test('iOS runtime verifies successful build evidence and rehashes the entire app before use', async () => {
  const app=await fixture(), directory=join(app,'..');
  const {rename} = await import('node:fs/promises');
  const artifactPath=join(directory,'SwitchyardHello.app'); await rename(app,artifactPath);
  const artifact=await iosArtifact(artifactPath);
  const config={expectedAccount:'switchyard',buildDirectory:directory,artifactSha256:artifact.sha256};
  const report={kind:'ios-build-experiment',platform:'ios',account:'switchyard',architecture:'arm64',applicationId:'com.managoat.switchyard.hello',error:null,artifact,sourceDigest:'f'.repeat(64),phases:[{name:'verify-artifact',passed:true}]};
  const save=()=>writeFile(join(directory,'report.json'),JSON.stringify(report),{mode:0o600});
  await save();
  expect((await verifyIosBuild(config)).apk).toBe(artifactPath);
  report.architecture='x86_64'; await save();
  await expect(verifyIosBuild(config)).rejects.toThrow('pinned Hello');
  report.architecture='arm64'; await save();
  await writeFile(join(artifactPath,'Info.plist'),'changed');
  await expect(verifyIosBuild(config)).rejects.toThrow('digest');
});
