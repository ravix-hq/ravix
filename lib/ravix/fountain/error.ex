defmodule Ravix.Fountain.Error do
  @moduledoc """
  A Fountain failure, preserving what the caller needs.

  The status and the code are Fountain's own (`sandbox_at_capacity`,
  `conversation_busy`, `sandbox_identity_mismatch`, ...); the message is
  Fountain's `message` when it sent one, else the code, else the SDK's line.
  `kind` is the SDK's classification and is only read for one thing here:
  `:connection` (status 0) is "could not reach Fountain", which is a different
  answer from "Fountain said no".

  `as_http/2` is `asHttpError` from `server/fountain.ts`: the same failure as
  one of ours, in the vocabulary an HTTP status is right for. It returns a map
  rather than a `RavixWeb.Error` so this module does not depend on the web
  layer; the gateway and the controllers wrap it.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          code: String.t() | nil,
          message: String.t(),
          kind: atom(),
          sandbox_status: String.t() | nil,
          grant_reason: String.t() | nil,
          until: DateTime.t() | nil,
          name_taken: boolean()
        }

  @type http :: %{status: pos_integer(), code: String.t(), message: String.t()}

  defstruct status: 0,
            code: nil,
            message: "",
            kind: :api,
            sandbox_status: nil,
            grant_reason: nil,
            until: nil,
            name_taken: false

  # `chatgpt_grant_unusable`'s `reason` (docs/creator-billing.md §4), kept only
  # when it is one Fountain documents, so it can be matched without an atom.
  @grant_reasons ~w(disconnected revoked expired reconnect_required exhausted not_found broker_required owner_ineligible)

  @busy_codes ~w(sandbox_at_capacity conversation_busy)

  @credential_codes ~w(chatgpt_grant_unusable inference_credential_unusable)

  @doc "A refusal of the project owner's inference credentials."
  @spec credential?(term()) :: boolean()
  def credential?(%__MODULE__{code: code}), do: code in @credential_codes
  def credential?(_), do: false

  @doc "Safe persisted explanation for queued messages refused for credentials."
  def credential_message,
    do: "Agent connection unavailable. Reconnect the project owner's agent, then retry."

  @doc "The SDK's error as ours."
  @spec from_sdk(Fountain.Error.t()) :: t()
  def from_sdk(%Fountain.Error{} = error) do
    %__MODULE__{
      status: error.status || 0,
      code: error.code,
      message: message_of(error),
      kind: error.kind || :api,
      sandbox_status: if(is_map(error.body), do: error.body["status"]),
      grant_reason: grant_reason(error.code, error.body),
      until: grant_until(error.code, error.body),
      name_taken: name_error?(error)
    }
  end

  # Fountain's unique index on a record's name surfaces as a changeset error
  # on `name`: a 422 whose `errors` map names the field.
  defp name_error?(%Fountain.Error{status: 422} = error),
    do: Fountain.Error.field_errors(error)["name"] not in [nil, []]

  defp name_error?(_error), do: false

  @doc "Fountain refused a record because another on the account has its name."
  @spec name_taken?(t()) :: boolean()
  def name_taken?(%__MODULE__{name_taken: taken}), do: taken

  defp grant_reason("chatgpt_grant_unusable", %{"reason" => reason})
       when reason in @grant_reasons,
       do: reason

  defp grant_reason(_code, _body), do: nil

  # When the subscription's usage resets: Fountain's `until`, on an exhausted
  # grant only. Anything that is not an ISO 8601 time is no time at all.
  defp grant_until("chatgpt_grant_unusable", %{"reason" => "exhausted", "until" => until})
       when is_binary(until) do
    case DateTime.from_iso8601(until) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp grant_until(_code, _body), do: nil

  @doc """
  A machine already taking a turn.

  Fountain can reject an idle-looking track because another turn took the
  sandbox's capacity meanwhile. The prompt queue treats this as safe to retry
  rather than as a failed delivery.
  """
  @spec busy?(t()) :: boolean()
  def busy?(%__MODULE__{status: status, code: code}),
    do: status in 400..499 and code in @busy_codes

  @doc "A resource-specific confirmation of absence; a generic route 404 is not proof."
  @spec sandbox_gone?(t()) :: boolean()
  def sandbox_gone?(%__MODULE__{status: status, code: code}),
    do: status in [404, 410] and code in ["sandbox_not_found", "sandbox_gone"]

  @doc "A passive disk read refused because the sandbox is suspended."
  @spec sandbox_suspended?(t()) :: boolean()
  def sandbox_suspended?(%__MODULE__{
        status: 409,
        code: "sandbox_not_ready",
        sandbox_status: "suspended"
      }),
      do: true

  def sandbox_suspended?(%__MODULE__{}), do: false

  @doc """
  A 404 from Fountain's router rather than from a resource: Phoenix's own
  body carries no `error` code, while every missing record names one.
  """
  @spec route_missing?(term()) :: boolean()
  def route_missing?(%__MODULE__{status: 404, code: nil}), do: true
  def route_missing?(_), do: false

  @doc "The vault endpoints deliberately conflate malformed, foreign and missing IDs."
  def vault_gone?(%__MODULE__{status: status}), do: status in [404, 410]

  @doc "A mutation may have happened: reconcile before retrying or allocating again."
  @spec unknown_outcome?(t()) :: boolean()
  def unknown_outcome?(%__MODULE__{status: status} = error),
    do: unreachable?(error) or status == 408 or status >= 500

  @doc "Fountain refused the request outright: a 4xx that is not a capacity problem."
  @spec rejected?(t()) :: boolean()
  def rejected?(%__MODULE__{status: status}), do: status in 400..499

  @doc "Fountain could not be reached at all (nothing was sent, or nothing came back)."
  @spec unreachable?(t()) :: boolean()
  def unreachable?(%__MODULE__{status: 0}), do: true
  def unreachable?(%__MODULE__{kind: :connection}), do: true
  def unreachable?(%__MODULE__{}), do: false

  @doc """
  A Fountain failure as one of ours, preserving what the caller needs.

  A rejected key is this deployment's problem, not the person's, so it is a 502
  rather than a 401 that would send them to sign in again. Capacity and identity
  conflicts are 409s with codes the browser knows. Everything else keeps its
  status, except that Fountain's 5xx becomes our 502: it was upstream that failed.

  A deployment with no Fountain at all is not a Fountain failure and is not
  here: that is `{:unconfigured, :fountain}`, and `RavixWeb.Error` holds its
  one sentence beside the other two providers'.
  """
  @spec as_http(t(), String.t()) :: http()
  def as_http(%__MODULE__{code: code, status: status}, _what_for) when code in @credential_codes,
    do: %{
      status: if(status in 400..499, do: status, else: 502),
      code: code,
      message: credential_message()
    }

  def as_http(%__MODULE__{status: status}, _what_for) when status in [401, 403] do
    %{
      status: 502,
      code: "fountain_rejected",
      message:
        "The machine service rejected this deployment’s key. Ask the administrator to restore the connection."
    }
  end

  def as_http(%__MODULE__{code: code}, _what_for) when code in @busy_codes do
    %{
      status: 409,
      code: "machine_busy",
      message: "The machine is busy with other turns. Try again in a moment."
    }
  end

  def as_http(%__MODULE__{code: "sandbox_identity_mismatch"}, _what_for) do
    %{
      status: 409,
      code: "identity_mismatch",
      message:
        "This project's machine no longer matches its identity. Rebuild it in Project settings › Danger zone."
    }
  end

  def as_http(%__MODULE__{} = error, what_for) do
    if unreachable?(error) do
      %{
        status: 502,
        code: "fountain_unreachable",
        message: "Could not reach the machine service to #{what_for}. Try again in a moment."
      }
    else
      %{
        status: if(error.status >= 500, do: 502, else: error.status),
        code: error.code || "fountain_error",
        message: public_message(error.code)
      }
    end
  end

  @doc "Public explanations never echo provider codes or untrusted provider messages."
  def public_message(code) when code in @credential_codes, do: credential_message()

  def public_message(code) when code in @busy_codes,
    do: "The machine is busy with other turns. Try again in a moment."

  def public_message("clone_auth_failed"),
    do:
      "Repository access could not be prepared. Check the project's GitHub App access, then retry setup."

  def public_message("secret_not_copyable"),
    do:
      "A project secret could not be copied securely. Save it again in project settings, then retry setup."

  def public_message("secrets_changed"),
    do:
      "Secrets changed — rebuild to apply. Prompts are paused until this track uses the new secrets."

  def public_message("vault_copy_failed"),
    do:
      "The project's credentials could not be copied for this track. Check project settings and retry setup."

  def public_message("sandbox_outcome_unknown"),
    do:
      "The machine provider has not confirmed whether creation finished. Your prompts are saved. Ask the project owner to check the machine provider; automatic checks continue without creating a second machine."

  def public_message("sandbox_cleanup_pending"),
    do: "Closing… cleaning up this track's machine. Cleanup will retry automatically."

  def public_message("adapter_crashed"), do: "The agent crashed and was restarted."
  def public_message("session_gone"), do: "The agent session ended. Wake the agent to continue."

  def public_message(code) when code in ["request timed out", "request_timeout", "timeout"],
    do: "The agent did not respond in time. Retry your message."

  def public_message(code) when code in ["sandbox_not_found", "sandbox_gone"],
    do: "The machine is no longer available. Rebuild it in Project settings › Danger zone."

  def public_message("conversation_not_found"),
    do: "The agent session is no longer available. Wake the agent to continue."

  def public_message("inference_source_changed"),
    do: "The agent connection changed. Wake the agent to continue."

  # The refusals a machine's wake shares with a prompt's (managoat/fountain#2551).
  def public_message("insufficient_credits"),
    do: "The machine service is out of credits. Ask the administrator to add more."

  def public_message("conversation_terminated"),
    do: "This track's agent session has ended, so it cannot be woken."

  def public_message("sandbox_reset_pending"),
    do: "This track's machine is being torn down or reset. Try again once it finishes."

  def public_message(code)
      when code in ["sandbox_unavailable", "fleet_full", "provisioning"],
      do: "The machine is not available right now. Try again in a moment."

  def public_message(_),
    do: "The machine service could not complete the request. Try again in a moment."

  @doc "Translate a transcript reason while retaining useful human explanations."
  def reason_message(nil), do: ""

  def reason_message("Opening prompt was refused: " <> code),
    do: public_message(String.trim(code))

  def reason_message(""), do: ""

  def reason_message(reason) do
    reason = String.trim(reason)
    # Older machine setup errors wrapped a human service response in an Elixir
    # tuple. Extract only the quoted error sentence; never evaluate provider text.
    reason =
      case Regex.run(~r/%\{"error" => "([^"\n]+)"\}/, reason) do
        [_, message] -> message
        _ -> reason
      end

    if reason in ["request timed out", "timeout"] or
         Regex.match?(
           ~r/^[a-z][a-z0-9]*(?:_[a-z0-9]+)+$|^Opening prompt was refused:|^setup_failed:|Fountain|\{:/,
           reason
         ),
       do: public_message(reason),
       else: reason
  end

  defp message_of(%Fountain.Error{body: %{"message" => message}}) when is_binary(message),
    do: message

  defp message_of(%Fountain.Error{code: code}) when is_binary(code), do: code
  defp message_of(%Fountain.Error{message: message}) when is_binary(message), do: message
  defp message_of(%Fountain.Error{status: status}), do: "HTTP #{status}"
end
