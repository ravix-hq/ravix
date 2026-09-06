import { expect, test } from 'bun:test';
import { withIosBuildRuntime } from './ios-build-runtime';
import type { Command, CommandOptions } from './process';
function fixture(previous?: string) {
  let override = previous;
  const calls: {args:string[]; options?:CommandOptions}[] = [];
  const run: Command = async (args, options) => {
    calls.push({args, options});
    let output: unknown = {};
    if (args.includes('--show-sdk-version')) output = '18.5';
    else if (args.includes('runtimes')) output = {runtimes:[{identifier:'com.apple.CoreSimulator.SimRuntime.iOS-18-6',isAvailable:true,buildversion:'22G86'}]};
    else if (args.includes('set')) override = args[6] === '--default' ? undefined : args[6];
    else output = {'iphoneos18.5':{sdkBuild:'22F76',chosenRuntimeBuild:override ?? '22F76',...(override ? {userOverriddenBuild:override} : {})}};
    return {code:0,stdout:Buffer.from(typeof output === 'string' ? output : JSON.stringify(output)),stderr:Buffer.alloc(0)};
  };
  return {run,calls,current:()=>override};
}
test('the provisioned runtime is selected only during the build and the default is restored', async () => {
  const f=fixture();
  const result=await withIosBuildRuntime({run:f.run,xcrun:'xcrun',env:{HOME:'/Users/switchyard'}},async selection=>{
    expect(f.current()).toBe('22G86'); expect(selection.previousOverride).toBeNull(); return 'built';
  });
  expect(result).toBe('built'); expect(f.current()).toBeUndefined();
  expect(f.calls.filter(c=>c.args.includes('set')).every(c=>c.args.includes('--sdkBuild') && c.args.at(-1)==='22F76')).toBe(true);
});
test('build failure and cancellation restore an existing override without the aborted signal', async () => {
  const f=fixture('22F77'), controller=new AbortController();
  await expect(withIosBuildRuntime({run:f.run,xcrun:'xcrun',env:{},signal:controller.signal},async()=>{controller.abort();throw Error('compile failed');})).rejects.toThrow('compile failed');
  expect(f.current()).toBe('22F77'); expect(f.calls.at(-1)!.options?.signal).toBeUndefined();
});
test('an already-selected runtime is not changed, and missing runtime prevents the build', async () => {
  const f=fixture('22G86');await withIosBuildRuntime({run:f.run,xcrun:'xcrun',env:{}},async s=>expect(s.changed).toBe(false));
  expect(f.calls.some(c=>c.args.includes('set'))).toBe(false);
  let built=false;
  const run:Command=async(args,options)=>args.includes('runtimes') ? {code:0,stdout:Buffer.from('{"runtimes":[]}'),stderr:Buffer.alloc(0)} : f.run(args,options);
  await expect(withIosBuildRuntime({run,xcrun:'xcrun',env:{}},async()=>{built=true;})).rejects.toThrow('Install'); expect(built).toBe(false);
});
