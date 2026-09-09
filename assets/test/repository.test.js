import { test, expect } from 'bun:test';
import { cpSync, mkdtempSync, rmSync, writeFileSync, readFileSync, unlinkSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkRepository } from '../../scripts/quality.mjs';

function fixture(change) {
  const root = mkdtempSync(join(tmpdir(), 'ravix-guards-'));
  try {
    for (const path of ['.tool-versions', 'Dockerfile', '.github', '.agents', '.claude', 'CLAUDE.md', 'AGENTS.md']) {
      // Only the shared skill link belongs in the fixture, never local agent sessions.
      if (path === '.claude') continue;
      cpSync(path, join(root, path), { recursive: true, verbatimSymlinks: true });
    }
    mkdirSync(join(root, '.claude'));
    cpSync('.claude/skills', join(root, '.claude/skills'), { verbatimSymlinks: true });
    change(root);
    return checkRepository(root);
  } finally { rmSync(root, { recursive: true, force: true }); }
}
function replace(root, file, from, to) {
  const path = join(root, file);
  writeFileSync(path, readFileSync(path, 'utf8').replace(from, to));
}

test('the real repository passes metadata guards', () => expect(checkRepository()).toEqual([]));
test('a changed Docker runtime fails', () => {
  expect(fixture(root => replace(root, 'Dockerfile', 'ARG OTP_VERSION=28.5', 'ARG OTP_VERSION=27.0')).join()).toContain('Docker OTP version drift');
});
test('a floating action tag fails', () => {
  expect(fixture(root => replace(root, '.github/workflows/ci.yml', /actions\/checkout@[a-f0-9]+/, 'actions/checkout@main')).join()).toContain('unpinned action');
});
test('broken shared guides fail', () => {
  expect(fixture(root => unlinkSync(join(root, 'CLAUDE.md'))).join()).toContain('CLAUDE.md');
});
test('malformed skills fail', () => {
  expect(fixture(root => replace(root, '.agents/skills/ravix-testing/SKILL.md', 'name: ravix-testing', 'name: unrelated')).join()).toContain('invalid name');
});
