import type { NativePlatform } from './native-preview';
export const RUNNER = { version: 1, heartbeatMs: 15000, leaseMs: 60000, pairingMs: 300000, queueLimit: 32 } as const;
export interface RunnerBuild {
    platform: NativePlatform;
    architecture: 'arm64' | 'arm64-v8a';
    profile: string;
    runtime: string;
    toolchain: string;
    artifactSha256: string;
    sourceDigest: string;
    lockfileDigest: string;
}
export interface RunnerCapabilities {
    version: 1;
    capacity: {
        sessions: 1;
        builds: 1;
    };
    builds: RunnerBuild[];
}
export interface RunnerInfo {
    id: string;
    name: string;
    projects: string[];
    online: boolean;
    revoked: boolean;
    capabilities: RunnerCapabilities;
}
export interface RunnerWork {
    id: string;
    sessionId: string;
    targetId: string;
    generation: number;
    epoch: number;
    platform: NativePlatform;
    artifactSha256: string;
    deadline: number;
    pairingCode: string;
}
export function parseRunnerCapabilities(value: unknown): RunnerCapabilities {
    const v = value as RunnerCapabilities;
    if (!v || v.version !== 1 || v.capacity?.sessions !== 1 || v.capacity?.builds !== 1 || !Array.isArray(v.builds) || !v.builds.length || v.builds.length > 2)
        throw Error('Runner protocol 1 supports one device and one build slot');
    const seen = new Set<string>();
    const builds = v.builds.map(b => {
        if (!b || !['android', 'ios'].includes(b.platform) || seen.has(b.platform) || b.architecture !== (b.platform === 'ios' ? 'arm64' : 'arm64-v8a'))
            throw Error('Invalid runner platform or architecture');
        seen.add(b.platform);
        if (![b.artifactSha256, b.sourceDigest, b.lockfileDigest].every(s => typeof s === 'string' && /^[a-f0-9]{64}$/.test(s)))
            throw Error('Runner builds require verified artifact and source identities');
        if (![b.profile, b.runtime, b.toolchain].every(s => typeof s === 'string' && /^[\w .;:+-]{1,160}$/.test(s)))
            throw Error('Invalid runner toolchain description');
        return { platform: b.platform, architecture: b.architecture, profile: b.profile, runtime: b.runtime, toolchain: b.toolchain, artifactSha256: b.artifactSha256, sourceDigest: b.sourceDigest, lockfileDigest: b.lockfileDigest };
    });
    return { version: 1, capacity: { sessions: 1, builds: 1 }, builds };
}
