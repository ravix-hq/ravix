import { readFileSync, readdirSync, readlinkSync, existsSync } from 'node:fs';
import { join } from 'node:path';

export function checkRepository(root = '.') {
  const errors = [];
  const read = path => readFileSync(join(root, path), 'utf8');
  const check = (value, message) => { if (!value) errors.push(message); };
  const versions = Object.fromEntries(read('.tool-versions').trim().split('\n').map(line => line.split(/\s+/)));
  const elixir = versions.elixir.split('-otp-')[0];
  const otpMajor = versions.elixir.split('-otp-')[1];
  check(versions.erlang.split('.')[0] === otpMajor, 'Elixir OTP target must match Erlang');
  const docker = read('Dockerfile');
  check(docker.includes(`ARG ELIXIR_VERSION=${elixir}\n`), 'Docker Elixir version drift');
  check(docker.includes(`ARG OTP_VERSION=${versions.erlang}\n`), 'Docker OTP version drift');
  for (const name of readdirSync(join(root, '.github/workflows')).filter(n => /\.ya?ml$/.test(n))) {
    const text = read(`.github/workflows/${name}`);
    const workflow = Bun.YAML.parse(text);
    check(workflow.on?.pull_request !== undefined || workflow.on?.schedule !== undefined, `${name}: missing trigger`);
    for (const job of Object.values(workflow.jobs)) {
      for (const step of job.steps || []) {
        if (!step.uses || step.uses.startsWith('./')) continue;
        check(/@[a-f0-9]{40}$/.test(step.uses), `${name}: unpinned action ${step.uses}`);
        const with_ = step.with || {};
        const resolve = value => String(value).replace(/\$\{\{ env\.(\w+) \}\}/g, (_, key) => workflow.env?.[key]);
        if (step.uses.startsWith('erlef/setup-beam@')) {
          check(resolve(with_['elixir-version']) === elixir, `${name}: Elixir version drift`);
          check(resolve(with_['otp-version']) === versions.erlang, `${name}: OTP version drift`);
        }
        if (step.uses.startsWith('actions/setup-node@')) {
          check(String(with_['node-version']) === versions.nodejs, `${name}: Node version drift`);
        }
        if (step.uses.startsWith('oven-sh/setup-bun@')) {
          check(String(with_['bun-version']) === versions.bun, `${name}: Bun version drift`);
        }
      }
    }
    // Required workflows cannot be skipped by path filters and leave PRs pending forever.
    check(!workflow.on?.pull_request?.paths && !workflow.on?.pull_request?.['paths-ignore'], `${name}: required workflow has path filters`);
  }
  for (const [link, target] of [['CLAUDE.md', 'AGENTS.md'], ['.claude/skills', '../.agents/skills']]) {
    try { check(readlinkSync(join(root, link)) === target && existsSync(join(root, link)), `${link}: broken shared link`); }
    catch { errors.push(`${link}: must be a symlink to ${target}`); }
  }
  const skills = readdirSync(join(root, '.agents/skills'));
  for (const expected of ['ravix-testing', 'ravix-elixir']) check(skills.includes(expected), `Missing skill ${expected}`);
  for (const name of skills) {
    const path = `.agents/skills/${name}/SKILL.md`;
    const text = read(path);
    const frontmatter = text.match(/^---\n([\s\S]*?)\n---\n/);
    if (!frontmatter) { errors.push(`${path}: missing frontmatter`); continue; }
    const meta = Bun.YAML.parse(frontmatter[1]);
    check(meta.name === name && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name), `${path}: invalid name`);
    check(typeof meta.description === 'string' && meta.description.length > 20, `${path}: missing useful description`);
    check(text.includes('AGENTS.md'), `${path}: missing shared guide reference`);
  }
  return errors;
}

if (import.meta.main) {
  const errors = checkRepository();
  if (errors.length) { console.error(errors.join('\n')); process.exit(1); }
  console.log('Repository guards: versions, immutable actions, required workflows, and shared agent skills agree.');
}
