defmodule Ravix.Tracks.Opening do
  @moduledoc """
  Everything a new track is called, decided before anything wakes the box.

  `Ravix.Tracks.open/4` settles the names first --- the slug that must be
  free, the branch derived from it, the title, the origin --- and only then
  makes the two writes that cannot be taken back: the conversation on
  Fountain, and the row that remembers it. Keeping the decisions in one
  value is what lets the naming be tested and read without a machine.

  It was three keys and two of them were maps: `%{origin:, conversation:
  %{...seven keys...}, row: %{...thirteen...}}`. Two problems with that, and
  the second is the one that could have shipped something wrong:

    * `conversation` is `Ravix.Fountain.create_conversation/2`'s argument,
      which is now `Ravix.Fountain.Launch` and enforces the identity rule
      rather than describing it.
    * `row` was `Ravix.Tracks.Track.changeset/2`'s attrs, and `cast/3`
      **silently drops a key it does not recognise**. `origin_base`,
      `origin_number`, `origin_title` and `origin_url` are not in
      `@required`, so a misspelling among them would have stored `nil` and
      passed every validation. The row is built by `track_attrs/2` from
      this struct's own fields now, so the same slip fails where it is
      written.

  `track_attrs/2` takes the conversation id as an argument because that is
  when it is known --- Fountain answers it. It used to arrive as
  `Map.put(row, :conversation_id, id)` onto a map whose type never mentioned
  the key, which is the same thing `Transcript.finish/2` was doing with
  `:acc`.
  """

  alias Ravix.Fountain.Launch
  alias Ravix.Tracks.Origin

  @enforce_keys [
    :id,
    :project_id,
    :rev,
    :slug,
    :title,
    :branch,
    :workdir,
    :created_by_login,
    :origin,
    :conversation
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          project_id: String.t(),
          rev: integer(),
          slug: String.t(),
          title: String.t(),
          branch: String.t(),
          workdir: String.t(),
          created_by_login: String.t(),
          origin: Origin.t(),
          conversation: Launch.t()
        }

  @doc """
  The track row, once Fountain has answered with the conversation it opened.

  Every column a new track has; `Ravix.Tracks.Track.changeset/2` fills in
  `created_at` and leaves `opened_at` and `closed_at` for later.
  """
  @spec track_attrs(t(), String.t()) :: map()
  def track_attrs(%__MODULE__{} = plan, conversation_id) do
    %{
      id: plan.id,
      project_id: plan.project_id,
      conversation_id: conversation_id,
      slug: plan.slug,
      title: plan.title,
      branch: plan.branch,
      # See `Ravix.Tracks` on why a PR's head branch is never reserved.
      branch_reserved: plan.origin.kind != :pr,
      workdir: plan.workdir,
      origin_kind: plan.origin.kind,
      origin_base: plan.origin.base,
      origin_number: plan.origin.number,
      origin_title: plan.origin.title,
      origin_url: plan.origin.url,
      origin_plan_id: plan.origin.plan_id,
      origin_item_id: plan.origin.item_id,
      rev: plan.rev,
      created_by_login: plan.created_by_login
    }
  end
end
