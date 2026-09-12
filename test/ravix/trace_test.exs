defmodule Ravix.TraceTest do
  @moduledoc """
  `sanitize/1` is the security-relevant half of `Ravix.Trace` and is tested
  directly and hard: a span attribute is the one path out of this application
  that the redacting `Inspect` on every credential-bearing struct does not
  cover, so "a token cannot become an attribute" has to be a property somebody
  can break a build against rather than a convention.

  These need no span and no exporter, so they stay async. The tests that read
  spans back are in `Ravix.TraceSpanTest`.
  """
  use ExUnit.Case, async: true

  alias Ravix.Trace

  describe "sanitize/1 keeps what a trace can hold" do
    test "numbers, booleans, atoms and short strings survive" do
      attributes = %{
        "ravix.turns" => 12,
        "ravix.busy" => 0.42,
        "ravix.fresh" => true,
        "ravix.state" => :running,
        "ravix.track_id" => "trk_123"
      }

      assert Trace.sanitize(attributes) == attributes
    end

    test "string keys and atom keys are both kept" do
      assert Trace.sanitize(%{:count => 1, "name" => "x"}) == %{:count => 1, "name" => "x"}
    end

    test "nil is an atom and survives, because 'we could not tell' is a reading" do
      # `Ravix.Vitals` exists on the distinction between a figure that is zero
      # and one that could not be read. A trace should be able to say the same.
      assert Trace.sanitize(%{"ravix.cpu_busy" => nil}) == %{"ravix.cpu_busy" => nil}
    end
  end

  describe "sanitize/1 drops anything that is not a flat value" do
    test "a struct cannot become an attribute" do
      # The failure this prevents: `Ravix.Config.sprites/0` answers a struct
      # holding the token every exec on this deployment runs on. Its `Inspect`
      # is redacted; a span attribute does not go through `Inspect`.
      sprites = %Ravix.Config.Sprites{token: "spr_live_secret", base_url: "https://x"}

      assert Trace.sanitize(%{"ravix.sprites" => sprites}) == %{}
    end

    test "a bare map cannot become an attribute" do
      assert Trace.sanitize(%{"ravix.params" => %{"password" => "hunter2"}}) == %{}
    end

    test "a list, a pid, a ref and a function cannot become attributes" do
      attributes = %{
        "a" => [1, 2, 3],
        "b" => self(),
        "c" => make_ref(),
        "d" => fn -> :ok end,
        "e" => {:tuple, :of, :things}
      }

      assert Trace.sanitize(attributes) == %{}
    end

    test "a binary that is not text is dropped rather than truncated" do
      # A compiled key, a protobuf frame or a serialised term. All three are
      # binaries; none is a string and one of them is a credential.
      assert Trace.sanitize(%{"ravix.blob" => <<0, 255, 128, 3>>}) == %{}
    end
  end

  describe "sanitize/1 drops keys that read like a credential" do
    test "the obvious spellings, whatever the value" do
      for key <- ~w(token api_token secret client_secret api_key private_key password
                    credential authorization auth_token private_key_pem signature
                    cookie session_cookie) do
        assert Trace.sanitize(%{key => "a-plain-string"}) == %{},
               "#{key} must not reach a span"
      end
    end

    test "case and prefix do not get around it" do
      assert Trace.sanitize(%{"GitHub.Client_SECRET" => "x"}) == %{}
      assert Trace.sanitize(%{:RAVIX_SECRET => "x"}) == %{}
      assert Trace.sanitize(%{"ravix.github.installation_token" => "ghs_x"}) == %{}
    end

    test "a key that merely contains a secretish word is still dropped" do
      # `keyboard` and `monkey` are collateral. That is the intended trade:
      # a dropped attribute costs a reader one field.
      assert Trace.sanitize(%{"keystrokes" => 3}) == %{}
    end

    test "ordinary keys next to a secretish one still survive" do
      assert Trace.sanitize(%{"ravix.track_id" => "trk_1", "token" => "t"}) ==
               %{"ravix.track_id" => "trk_1"}
    end
  end

  describe "sanitize/1 truncates" do
    test "a long string is cut and marked, not dropped" do
      long = String.duplicate("a", 400)
      %{"ravix.message" => kept} = Trace.sanitize(%{"ravix.message" => long})

      assert String.ends_with?(kept, "…")
      assert byte_size(kept) < byte_size(long)
      assert String.valid?(kept)
    end

    test "a multibyte string cut mid-character is still valid UTF-8" do
      # 256 bytes is not 256 characters. Slicing by bytes lands inside a
      # sequence, and an invalid UTF-8 attribute is one the exporter cannot
      # encode -- it would take the whole batch with it, not just this span.
      long = String.duplicate("é", 400)
      %{"ravix.message" => kept} = Trace.sanitize(%{"ravix.message" => long})

      assert String.valid?(kept)
    end

    test "a string at the limit is untouched" do
      exact = String.duplicate("a", 256)
      assert Trace.sanitize(%{"m" => exact}) == %{"m" => exact}
    end
  end

  describe "link/1" do
    test "runs the function and returns its value" do
      assert Trace.link(fn -> {:ok, 41 + 1} end).() == {:ok, 42}
    end

    test "does not leave the captured context attached to the calling process" do
      # The failure this prevents is not a missing trace but a wrong one: a
      # supervised task process that keeps a finished request's context files
      # its next, unrelated job as a child of it.
      wrapped = Trace.link(fn -> :ok end)
      before = OpenTelemetry.Ctx.get_current()

      assert wrapped.() == :ok
      assert OpenTelemetry.Ctx.get_current() == before
    end

    test "re-raises rather than swallowing, and still detaches" do
      wrapped = Trace.link(fn -> raise "boom" end)
      before = OpenTelemetry.Ctx.get_current()

      assert_raise RuntimeError, "boom", wrapped
      assert OpenTelemetry.Ctx.get_current() == before
    end
  end
end
