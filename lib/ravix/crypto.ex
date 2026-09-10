defmodule Ravix.Crypto do
  @moduledoc """
  Fountain keys and GitHub tokens at rest.

  A credential is encrypted with AES-256-GCM under a key derived from
  `RAVIX_SECRET`, so a copy of the database alone is not a copy of everyone's
  GitHub access. Session tokens are stored only as SHA-256 hashes, for the
  same reason. The wire format is the TypeScript server's, `v1.<iv>.<ct>` in
  base64url, so a row written by either reads in the other.

  Ravix needs this where a single-user app would not, and the reason is
  structural: sandbox identity includes the user, so a guest's turn can only
  run on the owner's key. Sharing a machine and holding a credential are the
  same decision.
  """

  @doc "The AES key for a secret: SHA-256 of it. Raises under sixteen characters."
  @spec key(String.t()) :: binary()
  def key(secret) when is_binary(secret) do
    if String.length(secret) < 16,
      do: raise(ArgumentError, "RAVIX_SECRET must be at least 16 characters")

    :crypto.hash(:sha256, secret)
  end

  @doc "`v1.<iv>.<ciphertext+tag>`, both base64url without padding."
  @spec encrypt(String.t(), String.t()) :: String.t()
  def encrypt(plain, secret \\ Ravix.Config.secret()) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(secret), iv, plain, <<>>, 16, true)
    "v1." <> b64(iv) <> "." <> b64(ct <> tag)
  end

  @doc "The plaintext, or an error for a ciphertext this secret did not write."
  @spec decrypt(String.t(), String.t()) :: {:ok, String.t()} | {:error, :unrecognised | :invalid}
  def decrypt(stored, secret \\ Ravix.Config.secret()) do
    with ["v1", iv_b, ct_b] <- String.split(stored, "."),
         {:ok, iv} <- unb64(iv_b),
         {:ok, blob} when byte_size(blob) >= 16 <- unb64(ct_b) do
      size = byte_size(blob) - 16
      <<ct::binary-size(size), tag::binary-size(16)>> = blob

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key(secret), iv, ct, <<>>, tag, false) do
        :error -> {:error, :invalid}
        plain -> {:ok, plain}
      end
    else
      _ -> {:error, :unrecognised}
    end
  end

  @doc "`decrypt/2`, raising."
  @spec decrypt!(String.t(), String.t()) :: String.t()
  def decrypt!(stored, secret \\ Ravix.Config.secret()) do
    case decrypt(stored, secret) do
      {:ok, plain} -> plain
      {:error, reason} -> raise ArgumentError, "cannot decrypt stored value: #{reason}"
    end
  end

  @doc "Random bytes as base64url; a session token, a link, a ticket."
  @spec random_token(pos_integer()) :: String.t()
  def random_token(bytes \\ 32), do: b64(:crypto.strong_rand_bytes(bytes))

  @doc "SHA-256 of a string, base64url. How tokens are stored and looked up."
  @spec sha256(String.t()) :: String.t()
  def sha256(s), do: b64(:crypto.hash(:sha256, s))

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
  defp unb64(s), do: Base.url_decode64(s, padding: false)
end
