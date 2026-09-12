defmodule Ravix.Redact do
  @moduledoc """
  What may leave this application for a third party (ADR 0004).

  There are two such paths and they had better agree: span attributes on their
  way to Honeycomb, and event properties on their way to PostHog. This module is
  the one rule both of them go through --- `Ravix.Trace.sanitize/1` delegates
  here, `Ravix.Analytics` calls it directly --- because a second copy of this
  judgement is a second copy that can drift.

  ## Why it exists at all

  `Ravix.Config` makes a leaked secret hard by giving every credential-bearing
  value a redacting `Inspect`, so a log line, a crash report or a `dbg/1` prints
  `...` instead of the key every machine on this deployment runs on. **Neither of
  these two egress paths goes through `Inspect`.** `OpenTelemetry.Tracer.set_attribute`
  and PostHog's property map both take the term itself, so the one mechanism
  protecting the rest of the application does not protect these, and a
  well-meaning `%{client: client}` would ship the Fountain key to a third party
  on every call.

  ## The rule

  `flat/1` is a whitelist of *shapes* rather than a blacklist of names: a value
  survives only if it is a number, a boolean, an atom or a text binary, which
  means a struct, a map, a list, a pid, a ref, a function and a non-text binary
  can never get out however they were named. On top of that a key that *reads*
  like a credential is dropped even when its value is a plain string, because
  `%{token: "ghs_..."}` is a short binary and would otherwise pass.

  It is **total**: it cannot raise on any map it is given. A telemetry or
  analytics call that crashes the request it was measuring is a worse outcome
  than any missing field, and both callers sit on context boundaries that every
  request goes through.

  ## What it is not

  It is a backstop against a leak nobody noticed, not a licence to pass
  everything through it and let it decide. A prompt body, a file path, a diff and
  a terminal command line are all short text binaries and would all survive;
  keeping them out is the *caller's* judgement, made once per call site.
  `Ravix.Sprites.exec/4` carries an argument count and never the arguments for
  exactly that reason, and `Ravix.Analytics` documents the same rule for event
  properties.
  """

  # Long enough for an id, a branch name, a repository's full name, a provider's
  # error string or a sanitised message; short enough that no single field can
  # carry a file, a diff or a transcript out by accident. A truncated value keeps
  # a marker so a reader knows it is not the whole of it.
  @max_binary 256

  # Dropped whatever the value looks like. `key` catches `api_key`,
  # `private_key` and `secret_key`; `auth` catches `authorization` and
  # `auth_token`. Over-broad on purpose: a dropped field costs a reader one
  # column, and a kept one costs a credential.
  #
  # One case-insensitive regex rather than ten `String.contains?/2` over a
  # downcased copy of the key: this runs per field on every span that records and
  # every event that is captured, and the list form was two thirds of the cost of
  # `Ravix.Trace.span/3`.
  @secretish ~w(token secret key password passwd credential auth pem signature cookie)
  @secretish_pattern ~r/#{Enum.join(@secretish, "|")}/i

  @typedoc "A map on its way out of this application."
  @type fields :: %{optional(atom() | String.t()) => term()}

  @doc """
  The fields of `map` that may leave this application.

  Dropped: any value that is not a number, boolean, atom or text binary (so
  structs, maps, lists, pids, refs and functions never get out), any key whose
  name reads like a credential, and any key that is not an atom or a string.
  Binaries over #{@max_binary} bytes are truncated rather than dropped.

  Cannot raise. A key type this does not recognise is dropped rather than
  examined, because `to_string/1` on a pid raises and that raise would land in
  the middle of whatever was being measured.
  """
  @spec flat(fields()) :: fields()
  def flat(map) when is_map(map) do
    map
    |> Enum.reject(fn {key, _value} -> secretish?(key) end)
    |> Enum.flat_map(fn {key, value} ->
      case value(value) do
        {:ok, safe} -> [{key, safe}]
        :drop -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  A tagged error's reason, as something a third party can hold and a person can
  group by.

  An atom stays an atom and a `{tag, detail}` keeps its tag. Anything else is
  *described* rather than inspected, because `inspect/1` on a struct that carries
  a credential is the leak this module exists to prevent, and a reason is
  sometimes a struct.
  """
  @spec reason(term()) :: atom() | String.t()
  def reason(reason) when is_atom(reason), do: reason
  def reason(reason) when is_binary(reason), do: truncate(reason)
  def reason({tag, _detail}) when is_atom(tag), do: tag
  def reason(%module{}), do: inspect(module)
  def reason(_other), do: :unknown

  # `{:ok, term} | :drop`. The last clause is the one that matters: a shape this
  # does not recognise is dropped rather than guessed at, so a value type nobody
  # thought about here cannot get out by default.
  defp value(v) when is_number(v) or is_boolean(v) or is_atom(v), do: {:ok, v}

  defp value(v) when is_binary(v) do
    # A binary that is not text is a payload, a compiled key or a serialised
    # term. None of those belong in a third party and one of them is a credential.
    if String.valid?(v), do: {:ok, truncate(v)}, else: :drop
  end

  defp value(_other), do: :drop

  defp truncate(text) do
    if byte_size(text) > @max_binary do
      # Sliced by bytes and then repaired, because a UTF-8 sequence cut in half
      # is not a string either exporter can encode -- and an invalid one takes
      # the whole batch with it, not just this field.
      <<head::binary-size(@max_binary), _rest::binary>> = text
      String.replace_invalid(head, "") <> "…"
    else
      text
    end
  end

  # `true` also means "drop", so a key this cannot read is dropped rather than
  # examined. Anything but an atom or a string is not a valid field name in the
  # first place, and `to_string/1` on, say, a pid raises.
  defp secretish?(key) when is_atom(key), do: secretish?(Atom.to_string(key))
  defp secretish?(key) when is_binary(key), do: Regex.match?(@secretish_pattern, key)
  defp secretish?(_key), do: true
end
