import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

// No developer DB: this manifest is created and removed by our browser harness.
export function composerFixture(trackId) {
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database)) throw new Error('Not a browser database');
  if (!/^[a-f0-9-]{36}$/.test(trackId)) throw new Error('Invalid track ID');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = query => execFileSync('psql', [`${server}/${database}`, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
  const quote = value => value === null ? 'NULL' : `'${value.replaceAll("'", "''")}'`;
  const original = JSON.parse(sql(`SELECT json_build_object('conversation_id', conversation_id, 'opened_at', opened_at) FROM ravix.tracks WHERE id = '${trackId}'`));
  return {
    async state(request, status, connected = true) {
      const response = await request.post(`http://localhost:${process.env.MOCK_PORT || 8893}/__browser/conversation-state`, {
        data: { id: original.conversation_id, status: ['running', 'failed'].includes(status) ? status : 'idle' },
      });
      if (!response.ok()) throw new Error(`Provider fixture failed: ${response.status()}`);
      sql(`UPDATE ravix.tracks SET conversation_id = ${quote(connected ? original.conversation_id : null)}, opened_at = ${quote(status === 'opening' ? null : original.opened_at)} WHERE id = '${trackId}'`);
    },
  };
}
