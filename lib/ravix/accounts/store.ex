defmodule Ravix.Accounts.Store do
  @moduledoc """
  The `users` table read by id or login, with nobody's access established.

  `Ravix.Accounts` is where a person comes *from*: a session token or a
  GitHub round trip is presented and a `User` comes back, and those reads
  are the door rather than something behind one. This module is the other
  kind of read -- a stored `user_id` or a typed login turned into the row
  it names -- and the caller already holds the reason it may ask: the
  project whose owner it is, the track whose seat it is, the queued prompt
  that recorded who sent it. Nothing here checks that reason; a caller in
  another context says which one in its `# ownership:` comment, and a page
  may not call this at all.
  """

  import Ecto.Query

  alias Ravix.Accounts.User
  alias Ravix.Repo

  @doc "A user by id, or nil."
  @spec get_user(String.t()) :: User.t() | nil
  def get_user(id) when is_binary(id), do: Repo.get(User, id)
  def get_user(_), do: nil

  @doc "Several users by id, in no particular order. An unknown id is simply absent."
  @spec get_users([String.t()]) :: [User.t()]
  def get_users([]), do: []
  def get_users(ids) when is_list(ids), do: Repo.all(from(u in User, where: u.id in ^ids))

  @doc """
  A user by GitHub login, case-insensitively, or nil.

  Nil for an *ambiguous* login as much as an unknown one, and the difference
  is worth naming. `login` has no unique index and cannot have one: GitHub
  frees a name the moment somebody renames, and a row here is allowed to be
  stale until they next sign in, so a stale `dana` and the new owner of
  `dana` can both exist. Both callers are consequential -- one grants access
  to a track, the other takes it away -- and answering either with a guess is
  how "remove @dana" silently revokes the wrong account. The invite path
  falls through to GitHub, which answers by numeric id; the removal path
  refuses rather than picking.
  """
  @spec user_by_login(String.t()) :: User.t() | nil
  def user_by_login(login) when is_binary(login) do
    lowered = String.downcase(login)

    case Repo.all(from u in User, where: fragment("lower(?)", u.login) == ^lowered, limit: 2) do
      [%User{} = user] -> user
      _none_or_ambiguous -> nil
    end
  end

  @doc """
  People who have signed in here whose login or name contains `q`, for the
  invite box. Never the caller.

  This does mean the box will tell you who has signed in here, which is a
  trade this deployment has accepted. Confirming one login at a time is the
  whole of that trade, so the term's own `%` and `_` are escaped rather than
  left live: `People.search/2` refuses an empty query precisely so nobody can
  ask for the whole userbase, and a bare `%` walked straight past it into
  `ILIKE '%%%'`, which matches every row. Ordered so a prefix match beats a
  contains match, because somebody typing `ana` means `ana` before `joana`.
  """
  @spec search_users(String.t(), String.t(), pos_integer()) :: [User.t()]
  def search_users(q, exclude_user_id, limit \\ 8) do
    escaped = escape_like(q)
    like = "%#{escaped}%"
    prefix = "#{escaped}%"

    Repo.all(
      from u in User,
        where: u.id != ^exclude_user_id and (ilike(u.login, ^like) or ilike(u.name, ^like)),
        order_by: [
          asc: fragment("CASE WHEN ? ILIKE ? THEN 0 ELSE 1 END", u.login, ^prefix),
          asc: u.login
        ],
        limit: ^limit
    )
  end

  # `\\` first, or it would escape the escapes added after it.
  defp escape_like(q) do
    q
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
