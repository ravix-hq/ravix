defmodule Ravix.People.Sharing do
  @moduledoc """
  What the Share dialog shows for one track (ADR 0009 phase 5):
  `Ravix.People.sharing/2`'s answer.

  Every control it offers is a question already answered here by the same
  rules the writes enforce, so the dialog never draws a control the server
  would refuse:

    * `set_visibility` -- the creator may choose between the workspace and
      "only people I add"; `private_allowed` is false on a track sharing
      the project machine, which cannot be private (#299).
    * `manage_people` -- whoever may add and remove people, on a private
      track only; a workspace-visible track already reaches everyone.
    * `general_level` -- the level everyone in the workspace reaches a
      workspace-visible track at (the workspace's default, as
      `Ravix.People.workspace_base/2` reports it); nil on a private track,
      which gives nobody anything by general access.
    * `holders` -- the live workspace members it is shared with.
    * `access` -- everyone who reaches the track, with their level and
      where it comes from (RAV-75): `:owner` (the project's owner, or a
      private track's creator), `:direct` (a seat or a share on this
      track), `:project` (the project's own grant) or `:workspace` (its
      default). `Ravix.Accounts.Access.track_people/2` decides it.
    * `consent` -- RAV-17's one-time note to the creator of a track they
      pay for, that collaborators' prompts use their subscription, until
      it has been shown once (`Ravix.Tracks.billing_notice/2`); else nil.

  `url` is the track's own address: the link to share. It admits nobody by
  itself.
  """

  @enforce_keys [
    :track_id,
    :url,
    :workspace,
    :visibility,
    :private_allowed,
    :general_level,
    :set_visibility,
    :manage_people,
    :holders,
    :access,
    :consent
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          track_id: String.t(),
          url: String.t(),
          workspace: String.t(),
          visibility: :project | :private,
          private_allowed: boolean(),
          general_level: Ravix.Accounts.Access.level() | nil,
          set_visibility: boolean(),
          manage_people: boolean(),
          holders: [Ravix.People.Profile.t()],
          access: [
            {Ravix.People.Profile.t(), Ravix.Accounts.Access.level(),
             Ravix.Accounts.Access.track_source()}
          ],
          consent: String.t() | nil
        }
end
