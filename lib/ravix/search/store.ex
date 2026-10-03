defmodule Ravix.Search.Store do
  @moduledoc "Indexed row queries; callers establish membership through Access predicates."
  import Ecto.Query
  alias Ravix.Accounts.Access
  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Search.Entry
  alias Ravix.Tracks.{Thread, Track}

  def index_turn(conversation_id, entries) do
    # ownership: no door on this internal ingestion path; settlement selected
    # the follower's current conversation, or Access.thread_access admitted
    # the page. Match only the current/archived conversation of that thread.
    thread_id =
      Repo.one(
        from th in Thread,
          where:
            th.conversation_id == ^conversation_id or
              ^conversation_id in th.previous_conversation_ids,
          select: th.id
      )

    if thread_id && entries != [] do
      conflict =
        from e in Entry,
          where:
            fragment(
              "EXCLUDED.last_event_id >= ? AND length(EXCLUDED.text) >= length(?)",
              e.last_event_id,
              e.text
            ),
          update: [
            set: [
              text: fragment("EXCLUDED.text"),
              last_event_id: fragment("EXCLUDED.last_event_id")
            ]
          ]

      Repo.insert_all(Entry, Enum.map(entries, &Map.put(&1, :thread_id, thread_id)),
        conflict_target: [:id],
        on_conflict: conflict
      )
    end

    :ok
  end

  def search(_user_id, _project_ids, %{query: ""}), do: []

  def search(user_id, project_ids, opts) do
    projects = projects(project_ids, opts)
    tracks = tracks(user_id) |> narrow(opts)
    names = track_names(tracks, opts.query)
    entries = entries(tracks, opts.query)
    prompts = prompts(tracks, opts.query)

    all = projects |> union_all(^names) |> union_all(^entries) |> union_all(^prompts)

    Repo.all(
      from row in subquery(all),
        order_by: [desc: row.occurred_at, asc: row.kind, asc: row.id],
        offset: ^((opts.page - 1) * 20),
        limit: 21
    )
  end

  def filters(user_id, project_ids, project_id) do
    visible_projects = tracks(user_id) |> select([project: p], p.id)

    project_query =
      from p in Project,
        where: p.id in ^project_ids or p.id in subquery(visible_projects),
        order_by: [asc: p.name, asc: p.id],
        limit: 200,
        select: %{id: p.id, name: p.name}

    track_query = tracks(user_id)

    track_query =
      if project_id in [nil, ""],
        do: track_query,
        else: where(track_query, [project: p], p.id == ^project_id)

    %{
      projects: Repo.all(project_query),
      tracks:
        Repo.all(
          from [track: t] in track_query,
            order_by: [asc: t.title, asc: t.id],
            limit: 200,
            select: %{id: t.id, name: t.title}
        )
    }
  end

  def visible_ids(user_id, ids) do
    tracks(user_id)
    |> where([track: t], t.id in ^Enum.reject(ids, &is_nil/1))
    |> select([track: t], t.id)
    |> Repo.all()
  end

  defp tracks(user_id) do
    from(t in Track,
      as: :track,
      join: p in Project,
      as: :project,
      on: p.id == t.project_id,
      where: is_nil(p.archived_at) and is_nil(p.deletion_requested_at)
    )
    |> Access.visible(user_id)
  end

  defp narrow(query, opts) do
    query = if opts.project, do: where(query, [project: p], p.id == ^opts.project), else: query
    if opts.track, do: where(query, [track: t], t.id == ^opts.track), else: query
  end

  defp projects(ids, opts) do
    query =
      from p in Project,
        where: p.id in ^ids and is_nil(p.archived_at) and is_nil(p.deletion_requested_at)

    query = if opts.project, do: where(query, [p], p.id == ^opts.project), else: query
    query = if opts.track, do: where(query, [p], false), else: query
    text = dynamic([p], fragment("? || ' ' || coalesce(?, '')", p.name, p.repo_full_name))

    query
    |> matching(text, opts.query)
    |> select([p], %{
      id: p.id,
      kind: "project",
      project_id: p.id,
      project_name: p.name,
      track_id: fragment("NULL::text"),
      thread_id: fragment("NULL::text"),
      conversation_id: fragment("NULL::text"),
      turn_id: fragment("NULL::text"),
      title: p.name,
      excerpt: fragment("left(? || ' ' || coalesce(?, ''), 400)", p.name, p.repo_full_name),
      occurred_at: p.created_at
    })
  end

  defp track_names(query, words) do
    text =
      dynamic(
        [track: t],
        fragment("coalesce(?, '') || ' ' || ? || ' ' || ?", t.title, t.slug, t.branch)
      )

    query
    |> matching(text, words)
    |> select([track: t, project: p], %{
      id: t.id,
      kind: "track",
      project_id: p.id,
      project_name: p.name,
      track_id: t.id,
      thread_id: fragment("NULL::text"),
      conversation_id: fragment("NULL::text"),
      turn_id: fragment("NULL::text"),
      title: t.title,
      excerpt:
        fragment("left(coalesce(?, '') || ' ' || ? || ' ' || ?, 400)", t.title, t.slug, t.branch),
      occurred_at: t.created_at
    })
  end

  defp entries(query, words) do
    query =
      query
      |> join(:inner, [track: t], th in Thread, as: :thread, on: th.track_id == t.id)
      |> join(:inner, [thread: th], e in Entry, as: :entry, on: e.thread_id == th.id)

    text = dynamic([entry: e], e.text)

    query
    |> matching(text, words)
    |> select([track: t, project: p, thread: th, entry: e], %{
      id: e.id,
      kind: e.kind,
      project_id: p.id,
      project_name: p.name,
      track_id: t.id,
      thread_id: th.id,
      conversation_id: e.conversation_id,
      turn_id: e.turn_id,
      title: th.title,
      excerpt:
        fragment(
          "left(ts_headline('simple', ?, plainto_tsquery('simple', ?), 'StartSel=\"\", StopSel=\"\", MaxWords=40, MinWords=15'), 400)",
          e.text,
          ^words
        ),
      occurred_at: e.occurred_at
    })
  end

  defp prompts(query, words) do
    query =
      join(query, :inner, [track: t], q in Ravix.PromptQueue.Item,
        as: :prompt,
        on: q.track_id == t.id
      )

    text = dynamic([prompt: q], fragment("coalesce(?->>'prompt', '')", q.body))

    query
    |> matching(text, words)
    |> select([track: t, project: p, prompt: q], %{
      id: q.id,
      kind: "queued_prompt",
      project_id: p.id,
      project_name: p.name,
      track_id: t.id,
      thread_id: fragment("coalesce(?, ?)", q.thread_id, t.id),
      conversation_id: fragment("NULL::text"),
      turn_id: fragment("NULL::text"),
      title: t.title,
      excerpt:
        fragment(
          "left(ts_headline('simple', ?, plainto_tsquery('simple', ?), 'StartSel=\"\", StopSel=\"\", MaxWords=40, MinWords=15'), 400)",
          fragment("coalesce(?->>'prompt', '')", q.body),
          ^words
        ),
      occurred_at: q.created_at
    })
  end

  defp matching(query, text, words) do
    match =
      dynamic(fragment("to_tsvector('simple', ?) @@ plainto_tsquery('simple', ?)", ^text, ^words))

    where(query, ^match)
  end
end
