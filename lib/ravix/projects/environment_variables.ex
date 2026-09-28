defmodule Ravix.Projects.EnvironmentVariables do
  @moduledoc """
  Readable project variables: at most 100 entries, names up to 200 bytes,
  values up to 16 KiB each. Empty values are meaningful; NUL is not an OS
  environment value. Accept maps or key/value rows so duplicate UI names
  are rejected before constructing Fountain's map.
  """

  # Source: managoat/fountain apps/fountain/lib/fountain/inference_credentials.ex,
  # InferenceCredentials.env_aliases/0 at f941a837 (2026-09-28). These override
  # inference billing; ADR 0005 permits that only through explicit secrets.
  @auth_names ~w(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY)
  @key ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  def normalize(raw) when is_map(raw) and not is_struct(raw),
    do: raw |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end) |> normalize()

  def normalize(rows) when is_list(rows) and length(rows) <= 100 do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, vars} ->
      case add(row, vars) do
        {:ok, vars} -> {:cont, {:ok, vars}}
        error -> {:halt, error}
      end
    end)
  end

  def normalize(_), do: error("env_vars_limit", "Use at most 100 environment variables.")

  defp add(%__MODULE__.Row{value: nil}, _vars),
    do: error("bad_env_vars", "Each variable needs a name and a string value.")

  defp add(%__MODULE__.Row{key: key, value: value}, vars),
    do: add(%{"key" => key, "value" => value}, vars)

  defp add(%{"key" => key, "value" => value}, vars) do
    with :ok <- validate_key(key), :ok <- validate_value(value) do
      if Map.has_key?(vars, key),
        do: error("duplicate_env_key", "Environment variable names must be unique."),
        else: {:ok, Map.put(vars, key, value)}
    end
  end

  defp add(_, _), do: error("bad_env_vars", "Each variable needs a name and a string value.")

  defp validate_key(key) do
    cond do
      not is_binary(key) or byte_size(key) > 200 or not Regex.match?(@key, key) ->
        error(
          "bad_env_key",
          "Use a name of at most 200 bytes: letters, digits and underscores, starting with a letter or underscore."
        )

      key == Ravix.Projects.clone_secret_key() ->
        error("reserved_key", "This name is reserved for Ravix's clone token.")

      key in @auth_names ->
        error(
          "provider_auth_env_key",
          "Use a secret if you intend to override billing with a provider auth variable."
        )

      true ->
        :ok
    end
  end

  defp validate_value(value) when is_binary(value) do
    if byte_size(value) <= 16_384 and String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: error("bad_env_value", "Values must be valid text without NUL and at most 16 KiB.")
  end

  defp validate_value(_),
    do: error("bad_env_value", "Environment variable values must be strings.")

  defp error(code, message), do: {:error, {:unprocessable, code, message}}
end
