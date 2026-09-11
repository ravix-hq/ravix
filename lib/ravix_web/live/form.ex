defmodule RavixWeb.Live.Form do
  @moduledoc """
  A form that can carry a refusal on the field it is about.

  Ravix had no forms in the Phoenix sense. Every dialog was a raw
  `<form phx-submit=...>`, its values were kept in a string-keyed map in
  assigns (`@form_data["name"]`), and a refusal became a toast at the top
  of the page. That is how a React app does it, and it is why all four
  clauses of `RavixWeb.CoreComponents.input/1` render
  `<.error :for={msg <- @errors}>` that never had anything to render: no
  caller passed `:errors`, because no caller had a form to get them from.

  So the two halves that were missing:

    * `new/2` builds a **schemaless changeset** (`{%{}, types}`) and hands
      back a `Phoenix.HTML.Form`, so `<.input field={@form[:name]} />`
      names itself, keeps what was typed, and has somewhere to put an
      error.
    * `refuse/2` takes what a context refused with and puts it on a field.

  ## Where the rule lives

  `refuse/2` deliberately does **not** re-implement the context's
  validation in the page. `Ravix.Projects.create/2` is the authority on
  whether a project may be created, because it is also the authority when
  the caller is not this page; a copy of "a name is required" here would be
  a second rule that can disagree with the first, and the one the person
  gets would depend on which ran.

  What the page does instead is put the context's *own sentence* where the
  person was typing. That is what the `code` in
  `{:unprocessable, code, message}` has always been for --- `"no_name"`,
  `"no_title"`, `"bad_key"` name a field --- and until now it was thrown
  away on the way to `RavixWeb.Error`, which has no notion of fields.

  The cost is a round trip: a blank name is refused by the server rather
  than in the browser. That is the same round trip the toast took, so
  nothing got slower; what changed is where the sentence lands.
  """

  import Phoenix.Component, only: [to_form: 2]

  alias Ecto.Changeset

  @typedoc "The form's name in the DOM and in the params it submits."
  @type name ::
          :new_project
          | :new_track
          | :rename_track
          | :preview_config
          | :preview_defaults
          | :secret
          | :settings

  @typedoc """
  A form's shape: the field types to cast, and which field each refusal
  code belongs to. A code with no field here is not about a field, and
  `refuse/2` leaves it for the flash.
  """
  @type shape :: {%{atom() => atom()}, %{String.t() => atom()}}

  # A track's preview configuration and a project's default for it are the
  # same three fields refused by the same `Ravix.Previews.parse_config/1`,
  # so they are one shape under two names. The codes it answers with ---
  # `preview_directory`, `preview_command`, `preview_readiness` --- name
  # their fields exactly, which is why all three sentences were arriving as
  # a single toast that did not say which box was wrong.
  @preview_config {%{directory: :string, command: :string, readiness_path: :string},
                   %{
                     "preview_directory" => :directory,
                     "preview_command" => :command,
                     "preview_readiness" => :readiness_path
                   }}

  @forms %{
    new_project: {%{name: :string, repo: :string}, %{"no_name" => :name}},
    new_track: {%{title: :string, ref: :string}, %{"no_title" => :title}},
    rename_track: {%{title: :string}, %{"no_title" => :title}},
    preview_config: @preview_config,
    preview_defaults: @preview_config,
    settings:
      {%{
         name: :string,
         runtime: :string,
         model: :string,
         instructions: :string,
         setup_script: :string,
         # The three package boxes are one space-separated line each, and
         # `Ravix.Projects.Settings.normalize_packages/1` is what turns them
         # into the map Fountain takes. They are fields here so the form can
         # keep what was typed across a refusal.
         apt: :string,
         pip: :string,
         npm: :string
       }, %{"invalid_runtime" => :runtime, "invalid_model" => :model, "no_name" => :name}},
    secret:
      {%{store: :string, key: :string, value: :string},
       %{
         "bad_key" => :key,
         "reserved_key" => :key,
         # A project with no vault can still hold environment secrets, so
         # the refusal belongs on the store picker rather than the name.
         "no_vault" => :store
       }}
  }

  @doc """
  A form of `name` holding `params`.

  Values survive a re-render, which is what `phx-change="edit"` was
  assigning `form_data` for: a dialog that reloads its repository list must
  not clear the name somebody half-typed.
  """
  @spec new(name(), map()) :: Phoenix.HTML.Form.t()
  def new(name, params \\ %{}) when is_map_key(@forms, name) do
    name |> changeset(params) |> to_form(as: name)
  end

  @doc """
  The same form with `reason` on the field it is about.

  Answers `:error` for a refusal that is not about a field --- a machine
  that could not be reached, a repository that has gone --- which the
  caller should flash as before, because there is no input to attach it to.
  """
  @spec refuse(Phoenix.HTML.Form.t(), term()) :: {:ok, Phoenix.HTML.Form.t()} | :error
  def refuse(%Phoenix.HTML.Form{name: name} = form, {:unprocessable, code, message}) do
    key = String.to_existing_atom(name)
    {_types, codes} = Map.fetch!(@forms, key)

    case Map.fetch(codes, code) do
      {:ok, field} ->
        form =
          key
          |> changeset(form.params)
          |> Changeset.add_error(field, message)
          |> to_form(as: key, action: :validate)

        {:ok, form}

      :error ->
        :error
    end
  end

  def refuse(_form, _reason), do: :error

  # `:validate` is what `Phoenix.Component.used_input?/1` reads to decide
  # whether a field has been touched, and an error on an untouched field is
  # not shown. A refusal is about what was actually submitted, so the whole
  # form counts as used.
  defp changeset(name, params) do
    {types, _codes} = Map.fetch!(@forms, name)
    Changeset.cast({%{}, types}, params, Map.keys(types))
  end
end
