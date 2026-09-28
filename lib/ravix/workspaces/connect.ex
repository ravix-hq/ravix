defmodule Ravix.Workspaces.Connect do
  @moduledoc """
  Connecting a GitHub App installation to a workspace (ADR 0009, phase 4b).

  A workspace owner or admin presses "Connect GitHub": `begin/3` parks a
  round trip and returns GitHub's install/configure page, carrying a state
  that names the workspace. GitHub sends the browser back to the App's
  setup URL (`/api/auth/callback`) with the `installation_id` the person
  installed or configured, and `finish/4` binds it to that workspace.

  The completed flow is the authority (owner decision 4): no personal
  GitHub token is read or kept. What makes the callback trustworthy is the
  state, which is

    * **bound to its workspace, person and session.** Only a hash of the
      nonce together with those three is stored, so a state finishes only
      for the workspace written in it, by the person who began it, in the
      browser session that began it;
    * **single-use.** The row is deleted by the statement that finds it, so
      a replayed callback finds nothing;
    * **short-lived.** Fifteen minutes, as the sign-in state is.

  The caller must still hold `:connect_repos` in the workspace when the
  callback lands, and GitHub must still have the installation (read as the
  App). One installation may be connected to several workspaces, each by
  its own round trip. Binding it refreshes that workspace's catalog
  (`Ravix.Workspaces.Repositories`).
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Crypto
  alias Ravix.Workspaces.{Repositories, Store}

  @max_age_s 15 * 60
  @prefix "ws."

  @type reason ::
          :not_found
          | :stale
          | {:forbidden, String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unconfigured, :github}
          | Ravix.GitHub.Error.t()

  @doc """
  Begin connecting GitHub to a workspace: where to send the browser.
  Owners and admins, behind `RAVIX_WORKSPACE_ACCESS`; `session_hash` is the
  caller's browser session, which the callback must present again.
  """
  @spec begin(User.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, reason()}
  def begin(%User{} = user, workspace_id, session_hash) when is_binary(session_hash) do
    with {:ok, app} <- Ravix.Providers.github(),
         {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :connect_repos) do
      nonce = Crypto.random_token(18)
      key = key(nonce, workspace.id, user.id, session_hash)
      :ok = Store.put_connect_state(key, workspace.id, user.id, @max_age_s)
      {:ok, Ravix.GitHub.install_url(app, @prefix <> workspace.id <> "." <> nonce)}
    end
  end

  def begin(%User{}, _workspace_id, _session_hash), do: {:error, :not_found}

  @doc "Whether a callback's `state` is a connect round trip's rather than sign-in's."
  @spec state?(term()) :: boolean()
  def state?(@prefix <> _rest), do: true
  def state?(_state), do: false

  @doc "The workspace a connect `state` names, unverified: where to send the browser back."
  @spec workspace_of(term()) :: String.t() | nil
  def workspace_of(state) do
    case parse(state) do
      {:ok, workspace_id, _nonce} -> workspace_id
      :error -> nil
    end
  end

  @doc """
  Finish a connect round trip: bind `installation_id` to the workspace the
  state names. The state is spent first, whatever happens after, so it
  cannot be tried twice. Answers the workspace id.

  `:stale` for a state that is unknown, spent, expired, or minted for
  another workspace, person or session; not found when the caller no
  longer manages the workspace; `no_installation` when GitHub does not have
  that installation of this App.
  """
  @spec finish(User.t(), String.t() | nil, term(), term()) ::
          {:ok, String.t()} | {:error, reason()}
  def finish(%User{} = user, session_hash, state, installation_id)
      when is_binary(session_hash) do
    with {:ok, workspace_id, nonce} <- parse(state) |> stale(),
         %{} = row <-
           Store.take_connect_state(key(nonce, workspace_id, user.id, session_hash), @max_age_s) ||
             {:error, :stale},
         {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, row.workspace_id, :connect_repos),
         {:ok, installation_id} <- installation_id(installation_id),
         {:ok, app} <- Ravix.Providers.github(),
         {:ok, found} <- Ravix.GitHub.installation(app, installation_id),
         {:ok, found} <- present(found) do
      {:ok, _binding} =
        Store.bind_installation(workspace.id, installation_id, found.account, user.id)

      # The catalog is best-effort here: the connection stands, and the
      # workspace page offers a refresh when GitHub was not answering.
      _ = Repositories.refresh_unchecked(workspace.id)
      Ravix.Hub.publish_workspace(workspace.id, :members)
      {:ok, workspace.id}
    end
  end

  def finish(%User{}, _session_hash, _state, _installation_id), do: {:error, :stale}

  defp parse(@prefix <> rest) do
    case String.split(rest, ".", parts: 2) do
      [workspace_id, nonce] when workspace_id != "" and nonce != "" -> {:ok, workspace_id, nonce}
      _ -> :error
    end
  end

  defp parse(_state), do: :error

  defp stale(:error), do: {:error, :stale}
  defp stale(ok), do: ok

  defp installation_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp installation_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> installation_id(nil)
    end
  end

  defp installation_id(_id),
    do:
      {:error,
       {:unprocessable, "no_installation", "GitHub did not say which installation to connect."}}

  defp present(nil),
    do:
      {:error,
       {:unprocessable, "no_installation",
        "GitHub does not have that installation of the Ravix App."}}

  defp present(found), do: {:ok, found}

  defp key(nonce, workspace_id, user_id, session_hash),
    do: Crypto.sha256(Enum.join([nonce, workspace_id, user_id, session_hash], "\n"))
end
