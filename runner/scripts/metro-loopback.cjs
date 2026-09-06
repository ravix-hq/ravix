// SDK 54's --localhost changes advertised URLs; its Metro server still calls
// listen(port, undefined). Constrain TCP listeners in this experiment process.
// No inherited NODE_OPTIONS: runtime-experiment passes this file explicitly.
const net = require('node:net');
const original = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  const first = args[0];
  if (first && typeof first === 'object' && !Array.isArray(first)) {
    if (first.path || first.fd != null || first.handle) throw new Error('Metro experiment expects a TCP listener');
    args[0] = { ...first, host: '127.0.0.1' };
  } else if (typeof first === 'number' || (typeof first === 'string' && /^\d+$/.test(first))) {
    if (typeof args[1] === 'string' || args[1] === undefined || args[1] === null) args[1] = '127.0.0.1';
    else args.splice(1, 0, '127.0.0.1');
  } else {
    throw new Error('Metro experiment expects a TCP listener');
  }
  return original.apply(this, args);
};
