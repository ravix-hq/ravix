import type { Database } from 'bun:sqlite';
export interface NativeServiceReservation {
    id: string;
    trackId: string;
    sprite: string;
    metro: number;
    backend: number;
}
/** Gate-2 service cleanup journal. Ports 30000–39999 are disjoint from the
 * existing web allocator (20000–29999), including older deployed versions. */
export class NativeExperimentStore {
    constructor(private db: Database) {
        db.exec(`CREATE TABLE IF NOT EXISTS native_experiment_services (
      id TEXT PRIMARY KEY, track_id TEXT NOT NULL REFERENCES tracks(id), sprite TEXT NOT NULL,
      metro INTEGER NOT NULL, backend INTEGER NOT NULL,
      UNIQUE(sprite, metro), UNIQUE(sprite, backend)
    )`);
    }
    all(): NativeServiceReservation[] { return this.db.query<{
        id: string;
        track_id: string;
        sprite: string;
        metro: number;
        backend: number;
    }, [
    ]>('SELECT * FROM native_experiment_services').all().map(r => ({ id: r.id, trackId: r.track_id, sprite: r.sprite, metro: r.metro, backend: r.backend })); }
    allocate(id: string, trackId: string, sprite: string): NativeServiceReservation {
        return this.db.transaction(() => {
            const rows = this.all(), existing = rows.find(r => r.id === id);
            if (existing)
                return existing;
            const used = new Set(rows.filter(r => r.sprite === sprite).flatMap(r => [r.metro, r.backend]));
            let metro = 30000;
            while (used.has(metro) && metro < 40000)
                metro++;
            let backend = metro + 1;
            while (used.has(backend) && backend < 40000)
                backend++;
            if (backend >= 40000)
                throw new Error('No available native service ports');
            this.db.run('INSERT INTO native_experiment_services VALUES (?,?,?,?,?)', [id, trackId, sprite, metro, backend]);
            return { id, trackId, sprite, metro, backend };
        }).immediate();
    }
    remove(id: string) { this.db.run('DELETE FROM native_experiment_services WHERE id=?', [id]); }
}
