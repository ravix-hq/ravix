defmodule Ravix.Factory do
  @moduledoc """
  Rows for tests, through the real changesets.

  Every `insert_*` takes a keyword list or a map, atom or string keys, and
  fills in whatever was not given, so `insert_track(project: p)` is a whole
  track and `insert_track()` is a whole track on a whole project on a whole
  user. Pass an association (`user: u`, `project: p`, `track: t`) or its id.
  The `*_attrs` helpers return the same defaults as string-keyed maps, the
  shape a context receives from a form or a JSON body.
  """
  alias Ravix.Accounts.{OAuthState, Session, User}
  alias Ravix.Previews.{Preview, PreviewAgentGrant, PreviewDefault, PreviewGrant, Row}
  alias Ravix.Projects.{Project, ProjectInvite, ProjectLink, ProjectMember}
  alias Ravix.PromptQueue.Item
  alias Ravix.Repo
  alias Ravix.Tracks.{Track, TrackInvite, TrackLink, TrackMember, TrackRead}

  @type attrs :: keyword() | map()

  # -- users and sessions ---------------------------------------------------

  @doc "Attributes for a user: a fresh GitHub id and login every call."
  @spec user_attrs(attrs()) :: map()
  def user_attrs(attrs \\ []) do
    n = uniq()

    defaults(attrs, %{
      "github_id" => Integer.to_string(1_000_000 + n),
      "login" => "user#{n}",
      "name" => "User #{n}",
      "avatar_url" => "https://avatars.example/#{n}.png",
      "token_enc" => nil
    })
  end

  @doc "A user."
  @spec insert_user(attrs()) :: User.t()
  def insert_user(attrs \\ []) do
    attrs |> user_attrs() |> then(&User.changeset(%User{}, &1)) |> Repo.insert!()
  end

  @doc "Attributes for a session. Brings a `token_hash` for a random token unless given."
  @spec session_attrs(attrs()) :: map()
  def session_attrs(attrs \\ []) do
    attrs = attrs |> normalize() |> take_assoc("user", "user_id")

    defaults(attrs, %{
      "token_hash" => Ravix.Crypto.sha256(Ravix.Crypto.random_token()),
      "expires_at" => DateTime.add(DateTime.utc_now(), 30, :day)
    })
  end

  @doc """
  A session for `user`. Returns the plaintext token and the row; only the
  token's SHA-256 is stored, as `Ravix.Crypto.sha256/1` computes it.
  """
  @spec insert_session(User.t(), attrs()) :: {String.t(), Session.t()}
  def insert_session(%User{} = user, attrs \\ []) do
    token = Ravix.Crypto.random_token()

    attrs =
      attrs
      |> normalize()
      |> Map.put("user_id", user.id)
      |> Map.put("token_hash", Ravix.Crypto.sha256(token))
      |> session_attrs()

    {token, Session.changeset(%Session{}, attrs) |> Repo.insert!()}
  end

  @doc "An OAuth state row."
  @spec insert_oauth_state(attrs()) :: OAuthState.t()
  def insert_oauth_state(attrs \\ []) do
    attrs =
      defaults(attrs, %{
        "state" => Ravix.Crypto.sha256(Ravix.Crypto.random_token()),
        "kind" => "login",
        "redirect" => nil
      })

    OAuthState.changeset(%OAuthState{}, attrs) |> Repo.insert!()
  end

  # -- projects -------------------------------------------------------------

  @doc "Attributes for a project. `user: u` becomes `user_id`; none is invented."
  @spec project_attrs(attrs()) :: map()
  def project_attrs(attrs \\ []) do
    n = uniq()
    attrs = attrs |> normalize() |> take_assoc("user", "user_id")

    defaults(attrs, %{
      "name" => "project-#{n}",
      "repo_full_name" => "acme/project-#{n}",
      "repo_private" => false,
      "default_branch" => "main",
      "installation_id" => 42,
      "agent_id" => "agent-#{n}",
      "environment_id" => "env-#{n}",
      "vault_id" => "vault-#{n}",
      "runtime" => "claude-code",
      "model" => "anthropic/claude-sonnet-5",
      "rev" => 1,
      "instructions" => ""
    })
  end

  @doc "A project, on a fresh user unless one is given."
  @spec insert_project(attrs()) :: Project.t()
  def insert_project(attrs \\ []) do
    attrs = attrs |> normalize() |> ensure_owner("user", "user_id", fn -> insert_user().id end)
    Project.changeset(%Project{}, project_attrs(attrs)) |> Repo.insert!()
  end

  @doc "A project membership for `user` on `project`."
  @spec insert_project_member(Project.t(), User.t(), attrs()) :: ProjectMember.t()
  def insert_project_member(%Project{} = project, %User{} = user, attrs \\ []) do
    attrs =
      attrs
      |> normalize()
      |> Map.merge(%{"project_id" => project.id, "user_id" => user.id})
      |> defaults(%{"invited_by" => project.user_id})

    ProjectMember.changeset(%ProjectMember{}, attrs) |> Repo.insert!()
  end

  @doc "A project invitation for a GitHub id that has not signed in."
  @spec insert_project_invite(Project.t(), attrs()) :: ProjectInvite.t()
  def insert_project_invite(%Project{} = project, attrs \\ []) do
    n = uniq()

    attrs =
      attrs
      |> normalize()
      |> Map.put("project_id", project.id)
      |> defaults(%{
        "github_id" => Integer.to_string(2_000_000 + n),
        "login" => "invited#{n}",
        "avatar_url" => nil,
        "invited_by" => project.user_id
      })

    ProjectInvite.changeset(%ProjectInvite{}, attrs) |> Repo.insert!()
  end

  @doc "A project link. Returns the plaintext token and the row."
  @spec insert_project_link(Project.t(), attrs()) :: {String.t(), ProjectLink.t()}
  def insert_project_link(%Project{} = project, attrs \\ []) do
    token = Ravix.Crypto.random_token()

    attrs =
      attrs
      |> normalize()
      |> Map.merge(%{"project_id" => project.id, "token_hash" => Ravix.Crypto.sha256(token)})
      |> defaults(%{
        "created_by" => project.user_id,
        "expires_at" => DateTime.add(DateTime.utc_now(), 1, :day)
      })

    {token, ProjectLink.changeset(%ProjectLink{}, attrs) |> Repo.insert!()}
  end

  # -- tracks ---------------------------------------------------------------

  @doc """
  Attributes for a track. `project: p` becomes `project_id`. The id is
  minted here because the branch name carries it, as `shared/ids.ts` does.
  """
  @spec track_attrs(attrs()) :: map()
  def track_attrs(attrs \\ []) do
    n = uniq()
    attrs = attrs |> normalize() |> take_assoc("project", "project_id")
    id = Map.get(attrs, "id", Ecto.UUID.generate())
    slug = Map.get(attrs, "slug", "track-#{n}")
    login = Map.get(attrs, "created_by_login", "user")

    defaults(attrs, %{
      "id" => id,
      "conversation_id" => nil,
      "slug" => slug,
      "title" => "Track #{n}",
      "branch" => "#{login}/#{slug}-#{id}",
      "workdir" => "/home/sprite/work/#{slug}",
      "origin_kind" => "blank",
      "origin_base" => nil,
      "origin_number" => nil,
      "origin_title" => nil,
      "origin_url" => nil,
      "rev" => 1,
      "created_by_login" => login
    })
  end

  @doc "A track, on a fresh project unless one is given."
  @spec insert_track(attrs()) :: Track.t()
  def insert_track(attrs \\ []) do
    attrs =
      attrs |> normalize() |> ensure_owner("project", "project_id", fn -> insert_project().id end)

    Track.changeset(%Track{}, track_attrs(attrs)) |> Repo.insert!()
  end

  @doc "A track membership for `user` on `track`."
  @spec insert_track_member(Track.t(), User.t(), attrs()) :: TrackMember.t()
  def insert_track_member(%Track{} = track, %User{} = user, attrs \\ []) do
    attrs =
      attrs
      |> normalize()
      |> Map.merge(%{"track_id" => track.id, "user_id" => user.id})
      |> defaults(%{"invited_by" => "owner"})

    TrackMember.changeset(%TrackMember{}, attrs) |> Repo.insert!()
  end

  @doc "A track invitation for a GitHub id that has not signed in."
  @spec insert_track_invite(Track.t(), attrs()) :: TrackInvite.t()
  def insert_track_invite(%Track{} = track, attrs \\ []) do
    n = uniq()

    attrs =
      attrs
      |> normalize()
      |> Map.put("track_id", track.id)
      |> defaults(%{
        "github_id" => Integer.to_string(3_000_000 + n),
        "login" => "invited#{n}",
        "avatar_url" => nil,
        "invited_by" => "owner"
      })

    TrackInvite.changeset(%TrackInvite{}, attrs) |> Repo.insert!()
  end

  @doc "A track link. Returns the plaintext token and the row."
  @spec insert_track_link(Track.t(), attrs()) :: {String.t(), TrackLink.t()}
  def insert_track_link(%Track{} = track, attrs \\ []) do
    token = Ravix.Crypto.random_token()

    attrs =
      attrs
      |> normalize()
      |> Map.merge(%{"track_id" => track.id, "token_hash" => Ravix.Crypto.sha256(token)})
      |> defaults(%{
        "created_by" => "owner",
        "expires_at" => DateTime.add(DateTime.utc_now(), 7, :day)
      })

    {token, TrackLink.changeset(%TrackLink{}, attrs) |> Repo.insert!()}
  end

  @doc "A read receipt for `user` on `track`, now unless `seen_at` is given."
  @spec insert_track_read(Track.t(), User.t(), attrs()) :: TrackRead.t()
  def insert_track_read(%Track{} = track, %User{} = user, attrs \\ []) do
    attrs = attrs |> normalize() |> Map.merge(%{"track_id" => track.id, "user_id" => user.id})
    TrackRead.changeset(%TrackRead{}, attrs) |> Repo.insert!()
  end

  # -- prompt queue ---------------------------------------------------------

  @doc "Attributes for a queued prompt. `track: t` and `user: u` become ids."
  @spec prompt_attrs(attrs()) :: map()
  def prompt_attrs(attrs \\ []) do
    attrs =
      attrs
      |> normalize()
      |> take_assoc("track", "track_id")
      |> take_assoc("user", "user_id")

    defaults(attrs, %{
      "id" => Ecto.UUID.generate(),
      "author_login" => "user",
      "payload" => Jason.encode!(%{prompt: "Hello from #{uniq()}", images: []}),
      "status" => "queued",
      "error" => nil
    })
  end

  @doc "A queued prompt, on a fresh track and its owner unless given."
  @spec insert_prompt(attrs()) :: Item.t()
  def insert_prompt(attrs \\ []) do
    attrs = attrs |> normalize() |> ensure_owner("track", "track_id", fn -> insert_track().id end)

    attrs =
      ensure_owner(attrs, "user", "user_id", fn ->
        track_id = Map.get(attrs, "track_id") || Map.fetch!(attrs, "track").id
        Repo.get!(Track, track_id) |> Repo.preload(:project) |> then(& &1.project.user_id)
      end)

    Item.changeset(%Item{}, prompt_attrs(attrs)) |> Repo.insert!()
  end

  # -- previews -------------------------------------------------------------

  @doc """
  Attributes for a preview row: a `t-<hex>` hostname and the stopped record
  `preview-store.ts` writes on `ensure`, keyed as the TypeScript keyed it.
  """
  @spec preview_attrs(attrs()) :: map()
  def preview_attrs(attrs \\ []) do
    attrs = attrs |> normalize() |> take_assoc("track", "track_id")
    hostname = Map.get(attrs, "hostname", "t-" <> String.replace(Ecto.UUID.generate(), "-", ""))
    attrs = attrs |> Map.put("hostname", hostname) |> defaults(%{"sprite" => nil, "port" => nil})

    # Built by the same two functions `Ravix.Previews.Store` writes with, so a
    # fixture cannot describe a row the store would not produce. `row` is the
    # expand-phase document, written alongside the columns exactly as the
    # store writes it.
    row = %Row{
      track_id: attrs["track_id"],
      hostname: hostname,
      service: "sy-" <> hostname,
      sprite: attrs["sprite"],
      port: attrs["port"]
    }

    row
    |> Row.to_attrs()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("row", Row.encode(row))
    |> Map.merge(attrs)
  end

  @doc "A preview row, on a fresh track unless one is given."
  @spec insert_preview(attrs()) :: Preview.t()
  def insert_preview(attrs \\ []) do
    attrs = attrs |> normalize() |> ensure_owner("track", "track_id", fn -> insert_track().id end)
    Preview.changeset(%Preview{}, preview_attrs(attrs)) |> Repo.insert!()
  end

  @doc "Preview defaults for `project`."
  @spec insert_preview_default(Project.t(), attrs()) :: PreviewDefault.t()
  def insert_preview_default(%Project{} = project, attrs \\ []) do
    attrs =
      attrs
      |> normalize()
      |> Map.put("project_id", project.id)
      |> defaults(%{
        "config" => %{"directory" => ".", "command" => "npm run dev", "readinessPath" => "/"}
      })

    PreviewDefault.changeset(%PreviewDefault{}, attrs) |> Repo.insert!()
  end

  @doc "A browser grant on `track` for `session`, an hour from now unless `expires` is given."
  @spec insert_preview_grant(Track.t(), Session.t(), attrs()) :: PreviewGrant.t()
  def insert_preview_grant(%Track{} = track, %Session{} = session, attrs \\ []) do
    attrs =
      attrs
      |> normalize()
      |> Map.merge(%{"track_id" => track.id, "session_hash" => session.token_hash})
      |> defaults(%{
        "hash" => Ravix.Crypto.sha256(Ravix.Crypto.random_token()),
        "expires" => System.system_time(:millisecond) + 3_600_000,
        "kind" => "session"
      })

    PreviewGrant.changeset(%PreviewGrant{}, attrs) |> Repo.insert!()
  end

  @doc "An agent grant on `track` for `user`."
  @spec insert_preview_agent_grant(Track.t(), User.t(), attrs()) :: PreviewAgentGrant.t()
  def insert_preview_agent_grant(%Track{} = track, %User{} = user, attrs \\ []) do
    hash = Ravix.Crypto.sha256(Ravix.Crypto.random_token())
    expires = System.system_time(:millisecond) + 3_600_000

    attrs =
      attrs
      |> normalize()
      |> Map.merge(%{"track_id" => track.id, "user_id" => user.id})
      |> defaults(%{"hash" => hash, "expires" => expires})

    attrs =
      defaults(attrs, %{
        "row" => %{
          "hash" => attrs["hash"],
          "trackId" => track.id,
          "userId" => user.id,
          "conversationId" => track.conversation_id || "conv-#{uniq()}",
          "promptId" => Ecto.UUID.generate(),
          "sandboxId" => "sandbox-#{uniq()}",
          "sprite" => "sprite-#{uniq()}",
          "expires" => attrs["expires"]
        }
      })

    PreviewAgentGrant.changeset(%PreviewAgentGrant{}, attrs) |> Repo.insert!()
  end

  # -- plumbing -------------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  # Keyword or map, atom or string keys, to a string-keyed map.
  defp normalize(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp defaults(attrs, defaults), do: Map.merge(defaults, normalize(attrs))

  # `%{"user" => %User{}}` to `%{"user_id" => id}`; an id already given wins.
  defp take_assoc(attrs, assoc, key) do
    case Map.pop(attrs, assoc) do
      {nil, attrs} -> attrs
      {%{id: id}, attrs} -> Map.put_new(attrs, key, id)
    end
  end

  # Insert the parent when neither the struct nor its id was given; `owner_id`
  # is only called in that case.
  defp ensure_owner(attrs, assoc, key, owner_id) do
    if Map.has_key?(attrs, assoc) or Map.has_key?(attrs, key),
      do: attrs,
      else: Map.put(attrs, key, owner_id.())
  end
end
