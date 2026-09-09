defmodule Ravix.CryptoTest do
  use ExUnit.Case, async: true

  alias Ravix.Crypto

  @secret "a-secret-of-at-least-sixteen-characters"

  describe "encrypt/2 and decrypt/2" do
    test "round trip" do
      stored = Crypto.encrypt("ghs_token", @secret)
      assert {:ok, "ghs_token"} = Crypto.decrypt(stored, @secret)
      assert Crypto.decrypt!(stored, @secret) == "ghs_token"
    end

    test "the wire format is v1.<iv>.<ciphertext+tag> in unpadded base64url" do
      stored = Crypto.encrypt("hello", @secret)
      assert ["v1", iv, blob] = String.split(stored, ".")
      assert {:ok, <<_::binary-size(12)>>} = Base.url_decode64(iv, padding: false)
      # Five bytes of ciphertext and a sixteen-byte tag.
      assert {:ok, <<_::binary-size(21)>>} = Base.url_decode64(blob, padding: false)
      refute stored =~ "="
    end

    test "every encryption uses a fresh IV, so equal plaintexts differ at rest" do
      assert Crypto.encrypt("same", @secret) != Crypto.encrypt("same", @secret)
    end

    test "the wrong secret fails" do
      stored = Crypto.encrypt("ghs_token", @secret)
      assert {:error, :invalid} = Crypto.decrypt(stored, "another-secret-long-enough-too")

      assert_raise ArgumentError, ~r/cannot decrypt/, fn ->
        Crypto.decrypt!(stored, "another-secret-long-enough-too")
      end
    end

    test "a tampered ciphertext fails" do
      ["v1", iv, blob] = Crypto.encrypt("ghs_token", @secret) |> String.split(".")
      {:ok, bytes} = Base.url_decode64(blob, padding: false)
      <<first, rest::binary>> = bytes
      flipped = Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
      assert {:error, :invalid} = Crypto.decrypt("v1.#{iv}.#{flipped}", @secret)
    end

    test "an unrecognised format is told apart from a bad key" do
      assert {:error, :unrecognised} = Crypto.decrypt("plaintext", @secret)
      assert {:error, :unrecognised} = Crypto.decrypt("v2.a.b", @secret)
      assert {:error, :unrecognised} = Crypto.decrypt("v1.not*base64.x", @secret)
      # Too short to even hold a tag.
      assert {:error, :unrecognised} =
               Crypto.decrypt(
                 "v1.#{Base.url_encode64(<<1, 2, 3>>, padding: false)}.AAAA",
                 @secret
               )
    end

    test "the empty string round-trips" do
      assert {:ok, ""} = Crypto.encrypt("", @secret) |> Crypto.decrypt(@secret)
    end

    test "the default secret is the configured one" do
      stored = Crypto.encrypt("x")
      assert {:ok, "x"} = Crypto.decrypt(stored)
      assert {:ok, "x"} = Crypto.decrypt(stored, Ravix.Config.secret())
    end
  end

  describe "key/1" do
    test "is SHA-256 of the secret, and refuses a short one" do
      assert Crypto.key(@secret) == :crypto.hash(:sha256, @secret)
      assert_raise ArgumentError, ~r/16 characters/, fn -> Crypto.key("too-short") end
      assert_raise ArgumentError, fn -> Crypto.encrypt("x", "short") end
    end
  end

  describe "sha256/1 and random_token/1" do
    test "sha256 is base64url without padding and stable" do
      assert Crypto.sha256("abc") ==
               Base.url_encode64(:crypto.hash(:sha256, "abc"), padding: false)

      assert Crypto.sha256("abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
      assert String.length(Crypto.sha256("abc")) == 43
    end

    test "random_token is 32 fresh bytes as base64url by default" do
      token = Crypto.random_token()
      assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(token, padding: false)
      assert String.length(token) == 43
      assert token != Crypto.random_token()

      assert {:ok, <<_::binary-size(8)>>} =
               Base.url_decode64(Crypto.random_token(8), padding: false)

      refute token =~ ~r/[+\/=]/
    end
  end
end
