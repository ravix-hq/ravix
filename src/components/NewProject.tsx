/**
 * The repository picker: the one screen between signing in and having a
 * machine.
 *
 * Everything it shows comes from `GET /api/github/repos`, which answers as
 * *you* — so the list is the repositories the App was granted on the account
 * you chose, not every repository on GitHub with a matching name. Picking one
 * is four Fountain calls on the server (environment, vault, clone token,
 * agent) and takes a few seconds, which is long enough that a silent button
 * reads as a broken one. So the row that was clicked says what is happening.
 */
import { useEffect, useMemo, useState } from "react";
import type { Project, RepoRef } from "../../shared/api";
import { api } from "../lib/api";
import { Folder, GitHub, Search } from "../lib/icons";
import { Dialog, ago } from "./Dialog";
import { Empty } from "./Empty";

type Listing = Awaited<ReturnType<typeof api.repos>>;

/**
 * A real navigation, not a fetch.
 *
 * `/api/auth/install` is the front of an OAuth round trip that ends at
 * GitHub's own "choose repositories" screen. Fetching it would follow the
 * redirect with XHR and land the person nowhere.
 */
function install(): void {
  window.location.href = "/api/auth/install";
}

export interface NewProjectProps {
  onCreated: (project: Project) => void;
  onClose: () => void;
}

export function NewProject({ onCreated, onClose }: NewProjectProps) {
  const [listing, setListing] = useState<Listing | null>(null);
  const [loading, setLoading] = useState(true);
  const [account, setAccount] = useState<number | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  // The repository being turned into a project, by full name, so the row that
  // was clicked is the row that reports.
  const [building, setBuilding] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    api.repos(account).then(
      (data) => {
        if (!live) return;
        setListing(data);
        setLoading(false);
      },
      (err: unknown) => {
        if (!live) return;
        setLoading(false);
        setError(err instanceof Error ? err.message : "Could not read your repositories.");
      },
    );
    // The previous listing is deliberately left in place while this runs, so
    // switching accounts does not take the account switcher off the screen
    // that the switch was made from.
    return () => {
      live = false;
    };
  }, [account]);

  const repos = listing?.repos ?? [];
  const filtered = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    if (!needle) return repos;
    // Server order is preserved throughout: it is sorted by push date, and
    // what you touched last is what you came here for.
    return repos.filter(
      (r) => r.fullName.toLowerCase().includes(needle) || (r.description ?? "").toLowerCase().includes(needle),
    );
  }, [repos, filter]);

  async function build(repo: RepoRef): Promise<void> {
    if (building) return;
    setBuilding(repo.fullName);
    setError(null);
    try {
      onCreated(await api.createProject({ repo: repo.fullName, installationId: repo.installationId }));
    } catch (err) {
      setBuilding(null);
      setError(err instanceof Error ? err.message : "Could not build that project.");
    }
  }

  const installations = listing?.installations ?? [];
  const uninstalled = !loading && !!listing && installations.length === 0;
  // An explicit choice wins over the server's, which still names the previous
  // account until the new listing lands.
  const chosen = account ?? listing?.selected;

  return (
    <Dialog
      title="New project"
      onClose={onClose}
      footer={
        uninstalled ? null : (
          <>
            <button type="button" className="linkish" onClick={install}>
              Add another account
            </button>
            <span className="spacer" />
            <span className="dimmer">
              {building ? "Creating the environment, vault and agent." : "A project is one repository on one machine."}
            </span>
          </>
        )
      }
    >
      {uninstalled ? (
        <div className="dialog-body">
          <Empty
            icon={<GitHub size={20} />}
            title="Switchyard cannot see any repositories yet"
            because="Installing it is how you choose which repositories it may read, clone and push to — you can pick a single one."
            action={{ label: "Install on an account", onClick: install }}
          >
            Switchyard works through a GitHub App, and the App is not installed on any account you belong to. Until it is,
            there is nothing here to build a project from.
          </Empty>
        </div>
      ) : (
        <>
          {installations.length > 1 ? (
            <div className="tabs" role="group" aria-label="Account">
              {installations.map((i) => (
                <button
                  key={i.id}
                  type="button"
                  className={`tab${chosen === i.id ? " on" : ""}`}
                  aria-pressed={chosen === i.id}
                  disabled={!!building}
                  onClick={() => setAccount(i.id)}
                >
                  {i.account}
                </button>
              ))}
            </div>
          ) : null}

          <div className="search-line">
            <Search />
            <input
              autoFocus
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="Filter repositories"
              aria-label="Filter repositories"
            />
          </div>

          <div className="dialog-body flush">
            {error ? <p className="fine error">{error}</p> : null}
            {loading ? (
              <Empty icon={<Folder size={20} />} title="Reading your repositories">
                Asking GitHub what this installation grants.
              </Empty>
            ) : filtered.length === 0 ? (
              <Empty icon={<Folder size={20} />} title="Nothing matches">
                {filter.trim()
                  ? `No repository on this account matches "${filter.trim()}".`
                  : "This installation does not grant any repositories yet."}
              </Empty>
            ) : (
              filtered.map((repo) => (
                <button
                  key={repo.fullName}
                  type="button"
                  className="pick-row"
                  disabled={!!building}
                  onClick={() => void build(repo)}
                >
                  <span className="ico">
                    <Folder />
                  </span>
                  <span className="mono truncate">{repo.fullName}</span>
                  {repo.private ? <span className="chip">private</span> : null}
                  <span className="meta">
                    {building === repo.fullName ? (
                      <span className="chip accent">Building the machine…</span>
                    ) : (
                      <>
                        {repo.language ? <span>{repo.language}</span> : null}
                        {repo.pushedAt ? <span>pushed {ago(repo.pushedAt)}</span> : null}
                      </>
                    )}
                  </span>
                </button>
              ))
            )}
          </div>
        </>
      )}
    </Dialog>
  );
}
