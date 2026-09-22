import { test, expect } from '@playwright/test';
import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';

const base = `http://localhost:${process.env.BROWSER_PORT || 4103}`;
let callback;
let callbackServer;

test.beforeAll(async () => {
  callbackServer = createServer((_request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/plain' });
    response.end('Connected to the desktop test client.');
  });
  await new Promise((resolve, reject) => {
    callbackServer.once('error', reject);
    callbackServer.listen(0, '127.0.0.1', resolve);
  });
  callback = `http://127.0.0.1:${callbackServer.address().port}/callback`;
});

test.afterAll(async () => {
  await new Promise(resolve => callbackServer?.close(resolve));
});
const scopes = 'projects:read projects:write tracks:read tracks:write tracks:cancel';

async function connect(page, request, resource, name) {
  const registered = await request.post('/oauth/register', {
    data: { client_name: name, redirect_uris: [callback], token_endpoint_auth_method: 'none' },
  });
  expect(registered.status()).toBe(201);
  const { client_id } = await registered.json();
  const verifier = randomBytes(32).toString('base64url');
  const state = randomBytes(16).toString('hex');
  const params = new URLSearchParams({
    client_id, redirect_uri: callback, response_type: 'code', resource: `${base}/${resource}`,
    scope: scopes, state, code_challenge_method: 'S256',
    code_challenge: createHash('sha256').update(verifier).digest('base64url'),
  });
  await page.goto(`/oauth/authorize?${params}`);
  if (new URL(page.url()).port === (process.env.MOCK_PORT || '8893')) {
    await page.getByRole('link', { name: 'Sign in as @dana', exact: true }).click();
  }
  const heading = page.getByRole('heading', { name: `Connect ${name} to Ravix` });
  await expect(heading).toBeVisible();
  await page.getByRole('button', { name: 'Allow access', exact: true }).click();
  await expect(page).toHaveURL(url => url.href.startsWith(`${callback}?`));
  const returned = new URL(page.url()).searchParams;
  expect(returned.get('state')).toBe(state);
  const exchanged = await request.post('/oauth/token', { form: {
    grant_type: 'authorization_code', client_id, code: returned.get('code'),
    code_verifier: verifier, redirect_uri: callback, resource: `${base}/${resource}`,
  } });
  expect(exchanged.status()).toBe(200);
  return { ...(await exchanged.json()), client_id };
}

async function rpc(request, token, endpoint, method, params = {}) {
  const response = await request.post(`/${endpoint}`, {
    headers: { Authorization: `Bearer ${token.access_token}`, Accept: 'application/json, text/event-stream' },
    data: { jsonrpc: '2.0', id: randomBytes(8).toString('hex'), method, params },
  });
  expect(response.status()).toBe(200);
  const body = await response.json();
  expect(body.error).toBeUndefined();
  return body.result;
}

async function tool(request, token, name, args = {}) {
  const result = await rpc(request, token, 'mcp', 'tools/call', { name, arguments: args });
  expect(result.isError, JSON.stringify(result.content)).toBe(false);
  return result.structuredContent;
}

test('browser consent connects MCP and A2A, work survives reconnect, and disconnect revokes access', async ({ page, request }) => {
  test.setTimeout(120_000);
  const mcp = await connect(page, request, 'mcp', 'MCP browser test');
  const initialized = await rpc(request, mcp, 'mcp', 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'browser-test', version: '1' } });
  expect(initialized.capabilities.tools).toBeDefined();
  const key = randomBytes(12).toString('hex');
  const project = await tool(request, mcp, 'create_project', { name: `Tooling ${key}`, request_id: key });
  const track = await tool(request, mcp, 'create_track', { project_id: project.id, title: 'Desktop work', request_id: key });
  const a2a = await connect(page, request, 'a2a', 'A2A browser test');
  const submitted = await rpc(request, a2a, 'a2a', 'SendMessage', {
    message: { messageId: key, role: 'ROLE_USER', contextId: track.id, parts: [{ text: 'Say hello.' }] },
    configuration: { returnImmediately: true },
  });
  expect(submitted.task.contextId).toBe(track.id);
  const refresh = await request.post('/oauth/token', { form: {
    grant_type: 'refresh_token', client_id: a2a.client_id, refresh_token: a2a.refresh_token, resource: `${base}/a2a`,
  } });
  expect(refresh.status()).toBe(200);
  const reconnected = await refresh.json();
  await expect.poll(async () => {
    const task = await rpc(request, reconnected, 'a2a', 'GetTask', { id: submitted.task.id });
    return task.status.state;
  }, { timeout: 60_000, intervals: [1000] }).toBe('TASK_STATE_COMPLETED');
  const finished = await rpc(request, reconnected, 'a2a', 'GetTask', { id: submitted.task.id });
  expect(finished.artifacts[0].parts[0].text.length).toBeGreaterThan(0);
  await page.goto('/settings/connections');
  const connection = page.locator('section').filter({ has: page.getByRole('heading', { name: 'A2A browser test', exact: true }) });
  await connection.getByRole('button', { name: 'Disconnect', exact: true }).click();
  await expect(connection.getByText('Disconnected or expired')).toBeVisible();
  const revoked = await request.post('/a2a', { headers: { Authorization: `Bearer ${reconnected.access_token}` }, data: { jsonrpc: '2.0', id: 1, method: 'GetTask', params: { id: submitted.task.id } } });
  expect(revoked.status()).toBe(401);
});
