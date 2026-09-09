/**
 * Postgres, behind the smallest interface the stores need.
 *
 * Two clients answer it. In production `DATABASE_URL` names a Render Postgres
 * and Bun's built-in client speaks to it. Without one — `bun run server`, the
 * tests — PGlite runs the same Postgres in-process, on disk under `DATA_DIR`
 * or in memory, so nothing has to be installed to work on this. Both are
 * Postgres, so the SQL is written once.
 *
 * Two things the interface settles so the stores do not have to:
 *
 *   - **Transactions are serialised and nest.** The stores were written
 *     against SQLite's `.immediate()` transactions, where a read-then-write
 *     (allocate the next free port, register against a pending pairing)
 *     could not interleave with another. `transaction()` keeps that promise
 *     with one advisory lock held for the transaction, and a call made from
 *     inside a transaction joins it rather than opening another. Which
 *     connection a query goes to is carried by `AsyncLocalStorage`, so a
 *     store method reads the same inside a transaction as outside it.
 *   - **Numbers are numbers.** Postgres `BIGINT` and `COUNT(*)` come back as
 *     BigInt (Bun) or already as numbers (PGlite); every row here has them as
 *     numbers, which is what the millisecond timestamps in the stores are.
 */
import { AsyncLocalStorage } from "node:async_hooks";
import { join } from "node:path";

export interface Sql {
  /** Rows, with `$1`-style parameters. */
  query<T = Record<string, unknown>>(text: string, params?: unknown[]): Promise<T[]>;
  /** The number of rows an INSERT, UPDATE or DELETE touched. */
  run(text: string, params?: unknown[]): Promise<number>;
  /** Several statements at once, for schema. No parameters. */
  exec(text: string): Promise<void>;
  /** One serialised transaction; nested calls join the outer one. */
  transaction<T>(fn: () => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

/** One key for the whole database: writes were serialised before, and still are. */
const LOCK = 7_240_119;

function plain(rows: Record<string, unknown>[]): Record<string, unknown>[] {
  for (const row of rows) for (const key in row) if (typeof row[key] === "bigint") row[key] = Number(row[key]);
  return rows;
}

interface Executor {
  query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[]; affected: number }>;
  exec(text: string): Promise<void>;
}

/** Shared shape: routing through the transaction in scope, and joining one already open. */
abstract class Base implements Sql {
  protected readonly scope = new AsyncLocalStorage<Executor>();
  protected abstract readonly root: Executor;
  protected abstract begin<T>(fn: (tx: Executor) => Promise<T>): Promise<T>;
  abstract close(): Promise<void>;

  private current(): Executor { return this.scope.getStore() ?? this.root; }
  async query<T>(text: string, params: unknown[] = []): Promise<T[]> {
    return plain((await this.current().query(text, params)).rows) as T[];
  }
  async run(text: string, params: unknown[] = []): Promise<number> {
    return (await this.current().query(text, params)).affected;
  }
  exec(text: string): Promise<void> { return this.current().exec(text); }
  transaction<T>(fn: () => Promise<T>): Promise<T> {
    if (this.scope.getStore()) return fn();
    return this.begin(async tx => {
      await tx.query("SELECT pg_advisory_xact_lock($1)", [LOCK]);
      return this.scope.run(tx, fn);
    });
  }
}

type BunSql = InstanceType<typeof import("bun").SQL>;
/** What `sql.begin` hands its callback: the same `unsafe` on one reserved connection. */
type BunTx = Pick<BunSql, "unsafe">;

function bunExecutor(client: BunSql | BunTx): Executor {
  return {
    async query(text, params = []) {
      const result = await client.unsafe(text, params as never[]);
      return { rows: Array.from(result) as Record<string, unknown>[], affected: result.count ?? 0 };
    },
    async exec(text) { await client.unsafe(text); },
  };
}

class BunPostgres extends Base {
  protected readonly root: Executor;
  constructor(private readonly sql: BunSql) { super(); this.root = bunExecutor(sql); }
  protected begin<T>(fn: (tx: Executor) => Promise<T>): Promise<T> {
    return this.sql.begin(tx => fn(bunExecutor(tx as unknown as BunTx))) as Promise<T>;
  }
  close(): Promise<void> { return this.sql.close(); }
}

type PGlite = import("@electric-sql/pglite").PGlite;
type PGliteTx = import("@electric-sql/pglite").Transaction;

function pgliteExecutor(client: PGlite | PGliteTx): Executor {
  return {
    async query(text, params = []) {
      const result = await client.query<Record<string, unknown>>(text, params);
      return { rows: result.rows, affected: result.affectedRows ?? 0 };
    },
    async exec(text) { await client.exec(text); },
  };
}

class Embedded extends Base {
  protected readonly root: Executor;
  constructor(private readonly db: PGlite, private readonly shared: boolean) { super(); this.root = pgliteExecutor(db); }
  protected begin<T>(fn: (tx: Executor) => Promise<T>): Promise<T> {
    return this.db.transaction(tx => fn(pgliteExecutor(tx))) as Promise<T>;
  }
  /** A shared instance (the tests') outlives any one handle on it. */
  async close(): Promise<void> { if (!this.shared) await this.db.close(); }
}

export interface OpenSql {
  /** A Postgres URL. Production always has one. */
  url?: string | null;
  /** Without a URL: the directory an embedded Postgres persists under. */
  dataDir?: string;
}

/** The database this process talks to, by configuration. */
export async function openSql(options: OpenSql): Promise<Sql> {
  if (options.url) {
    const { SQL } = await import("bun");
    return new BunPostgres(new SQL({ url: options.url, bigint: true }));
  }
  // A development dependency, and left out of the production bundle: a
  // deployment without DATABASE_URL should say so rather than quietly keep
  // its state in a directory the next deploy throws away.
  const { PGlite } = await import("@electric-sql/pglite").catch(() => {
    throw new Error("DATABASE_URL is not set, and this build has no embedded database. Point it at Postgres.");
  });
  const db = new PGlite(options.dataDir ? join(options.dataDir, "pg") : undefined);
  await db.waitReady;
  return new Embedded(db, false);
}

let embedded: Promise<Embedded> | undefined;
let external: Promise<Sql> | undefined;

/** Bun's client with `close()` made a no-op: one pool serves every test in the process. */
class Shared implements Sql {
  constructor(private readonly inner: Sql) {}
  query<T>(text: string, params?: unknown[]) { return this.inner.query<T>(text, params); }
  run(text: string, params?: unknown[]) { return this.inner.run(text, params); }
  exec(text: string) { return this.inner.exec(text); }
  transaction<T>(fn: () => Promise<T>) { return this.inner.transaction(fn); }
  async close() {}
}

/**
 * A fresh, empty database for a test, on one in-process Postgres per test
 * process — the instance takes a second to start, an empty schema takes a
 * millisecond. Set `RAVIX_TEST_DATABASE_URL` to run the same tests against a
 * real server instead; the schema is reset the same way.
 */
export async function testSql(): Promise<Sql> {
  const url = process.env.RAVIX_TEST_DATABASE_URL;
  if (url) {
    external ??= openSql({ url }).then(sql => new Shared(sql));
    const sql = await external;
    await sql.exec("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
    return sql;
  }
  embedded ??= import("@electric-sql/pglite").then(async ({ PGlite }) => {
    const db = new PGlite();
    await db.waitReady;
    return new Embedded(db, true);
  });
  const sql = await embedded;
  await sql.exec("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
  return sql;
}
