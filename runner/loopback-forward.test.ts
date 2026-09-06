import {expect, test} from 'bun:test';
import {createServer, connect, type Server} from 'node:net';
import {reserveLoopbackForward} from './loopback-forward';
const listen = (server:Server) => new Promise<number>((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const a=server.address();if(!a || typeof a==='string')reject(Error('Missing port'));else resolve(a.port);});});
const close = (server:Server) => new Promise<void>(resolve=>server.close(()=>resolve()));
test('free ports stay reserved, reject input before activation, and close on assignment loss', async () => {
  const active=new AbortController();
  const a=await reserveLoopbackForward({signal:active.signal}), b=await reserveLoopbackForward({signal:active.signal});
  try {
    expect(a.port).not.toBe(b.port);
    await expect(reserveLoopbackForward({signal:active.signal,port:a.port})).rejects.toThrow(`127.0.0.1:${a.port}`);
    await new Promise<void>((resolve,reject)=>{
      const peer=connect({host:'127.0.0.1',port:a.port});
      const timer=setTimeout(()=>{peer.destroy();reject(Error('Unassigned forward stayed open'));},1000);
      peer.on('error',()=>{});peer.on('close',()=>{clearTimeout(timer);resolve();});
    });
    expect(()=>a.activate({endpoint:'wss://switchyard.test/forward',token:'bad'})).toThrow('credential');
    a.activate({endpoint:'wss://switchyard.test/forward',token:'a'.repeat(43)});
    expect(()=>a.activate({endpoint:'wss://switchyard.test/forward',token:'b'.repeat(43)})).toThrow('again');
  } finally {active.abort();}
  expect(()=>b.activate({endpoint:'wss://switchyard.test/forward',token:'a'.repeat(43)})).toThrow('after ending');
});
test('a bind conflict leaves the unrelated listener running', async () => {
  const unrelated=createServer(peer=>peer.end('unrelated')), port=await listen(unrelated), active=new AbortController();
  try {
    await expect(reserveLoopbackForward({port,signal:active.signal})).rejects.toThrow(`127.0.0.1:${port}`);
    expect(unrelated.listening).toBe(true);
    const free=await reserveLoopbackForward({signal:active.signal});expect(free.port).not.toBe(port);
  } finally {active.abort();await close(unrelated);}
});
