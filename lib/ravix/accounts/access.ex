defmodule Ravix.Accounts.Access do
  @moduledoc """
  Who is asking, and what they are allowed to touch.

  Shorter than paddock's equivalent, and the difference is worth naming:
  paddock admits people with no account at all, so identity there is a union
  and every route downstream has to handle both halves. Ravix has one kind
  of caller, somebody signed in with GitHub, and three doors, in widening
  order:

      track_access/2    one branch, because you were named on it
      project_access/2  every branch on a machine, because you were named on it
      project_of/2      the machine itself, because you own it

  All three are enforced by lookup rather than by a check, and all three
  answer *not found* rather than refusing: the existence of somebody else's
  project is not the caller's to learn. Every context function that touches
  a project or a track goes through one of these first; the `_unsafe_`
  functions elsewhere are only ever called beside a door that already
  answered.

  The port of `server/context.ts`, with the HTTP taken out: the doors return
  `{:ok, ...} | {:error, :not_found}` and the two `require_*` guards return
  `:ok | {:error, {:forbidden, message}}`; `RavixWeb.Error` turns those back
  into the 404 and 403 the TypeScript threw.
  """

  import Ecto.Query

  alias Ravix.Accounts.User
  alias Ravix.Projects.{Project, ProjectMember}
  alias Ravix.Repo
  alias Ravix.Tracks.{Track, TrackMember}

  @typedoc "Owner, or somebody invited to the track or the project in question."
  @type role :: :owner | :member

  @type project_access :: %{project: Project.t(), role: role()}
  @type track_access :: %{track: Track.t(), project: Project.t(), role: role()}

  @doc """
  A project the caller **owns**. Not found for anyone else's.

  The project's *controls* go through this and nothing else: its settings,
  its packages and secrets, the rebuild, and the delete. Somebody invited to
  the project is not a caller here (they are a caller at `project_access/2`)
  and gets the same answer as a stranger, because a machine you were let
  onto is still not a machine you get to re-provision.
  """
  @spec project_of(User.t(), String.t()) :: {:ok, Project.t()} | {:error, :not_found}
  def project_of(%User{id: user_id}, project_id) do
    case live_project(project_id) do
      %Project{user_id: ^user_id} = project -> {:ok, project}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  A project the caller may work in, and in what capacity.

  The wider door, and the one added when "invite somebody to the whole
  project" became a thing ravix can do. A project member reaches every
  track on it, the ones open now and the ones opened tomorrow, and may cut
  tracks of their own, because a project you were let into where you cannot
  start a line of work is only a bundle of track invitations with a nicer
  name.

  What it is *not* is `project_of/2`. The line between the two is the line
  the README draws: the work on the machine is shared, the machine is not.
  So the settings panel, the package list, the secrets, the rebuild and the
  delete all keep resolving through `project_of/2` and refuse a member
  exactly as they refuse a stranger.
  """
  @spec project_access(User.t(), String.t()) :: {:ok, project_access()} | {:error, :not_found}
  def project_access(%User{id: user_id}, project_id) do
    case live_project(project_id) do
      nil ->
        {:error, :not_found}

      %Project{user_id: ^user_id} = project ->
        {:ok, %{project: project, role: :owner}}

      %Project{} = project ->
        if project_member?(project.id, user_id),
          do: {:ok, %{project: project, role: :member}},
          else: {:error, :not_found}
    end
  end

  @doc """
  A track the caller may reach, and in what capacity.

  Two ways in, and the order they are tried in is the order of how much they
  grant. Somebody named on *this track* gets this track: a second track of
  the same project lands here again and is refused again, which is what
  makes "an invitation is to a branch, not to the machine" true by
  construction rather than by everybody remembering. Somebody invited to the
  **project** gets all of them, which is the point of that invitation and is
  why it is a separate, deliberate act by the owner rather than something a
  track invite grows into.

  Both come back as `:member`. The distinction between them is about how
  they got here, not about what they may do once they are, and every caller
  of this door wants the second question.

  A project that has been archived is gone for its members too, and a closed
  track stops admitting anyone: neither has a surface left to share.
  """
  @spec track_access(User.t(), String.t()) :: {:ok, track_access()} | {:error, :not_found}
  def track_access(%User{id: user_id}, track_id) do
    with %Track{} = track <- get_track(track_id),
         %Project{} = project <- live_project(track.project_id) do
      cond do
        project.user_id == user_id ->
          {:ok, %{track: track, project: project, role: :owner}}

        track.closed_at != nil ->
          {:error, :not_found}

        member?(track.id, user_id) or project_member?(project.id, user_id) ->
          {:ok, %{track: track, project: project, role: :member}}

        true ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Owner-only operations on a track somebody else may also be in."
  @spec require_owner(role(), String.t()) :: :ok | {:error, {:forbidden, String.t()}}
  def require_owner(:owner, _what), do: :ok

  def require_owner(_role, what),
    do: {:error, {:forbidden, "Only the owner of this project can #{what}."}}

  @doc """
  The same, plus whoever cut the track.

  For renaming and closing, and it exists because project members can open
  tracks. Somebody who may make a directory on the machine and then may not
  tidy it up leaves the owner sweeping up after their guests, which is a
  worse outcome than the one owner-only was protecting against. It is still
  not "any member": being invited to help on a branch is not being handed
  the ability to end it for everybody else in it.

  Matched on the login rather than a user id because that is what the row
  holds: `created_by_login` is written for the ribbon, and the person who
  renames their GitHub account is a rarer event than the one this prevents.
  """
  @spec require_owner_or_cutter(role(), User.t(), Track.t(), String.t()) ::
          :ok | {:error, {:forbidden, String.t()}}
  def require_owner_or_cutter(:owner, _user, _track, _what), do: :ok

  def require_owner_or_cutter(_role, %User{login: login}, %Track{created_by_login: cutter}, what) do
    if is_binary(cutter) and String.downcase(cutter) == String.downcase(login || "") do
      :ok
    else
      {:error,
       {:forbidden, "Only the owner of this project, or whoever opened this track, can #{what}."}}
    end
  end

  @doc "Whether `user_id` was named on `track_id`."
  @spec member?(String.t(), String.t()) :: boolean()
  def member?(track_id, user_id) do
    Repo.exists?(from m in TrackMember, where: m.track_id == ^track_id and m.user_id == ^user_id)
  end

  @doc "Whether `user_id` was let into the whole of `project_id`."
  @spec project_member?(String.t(), String.t()) :: boolean()
  def project_member?(project_id, user_id) do
    Repo.exists?(
      from m in ProjectMember, where: m.project_id == ^project_id and m.user_id == ^user_id
    )
  end

  # A project that exists and has not been archived. Every door starts here:
  # an archived project is gone for everybody, its owner included.
  defp live_project(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{archived_at: nil} = project -> project
      _ -> nil
    end
  end

  defp live_project(_), do: nil

  defp get_track(track_id) when is_binary(track_id), do: Repo.get(Track, track_id)
  defp get_track(_), do: nil
end
