defmodule Ravix.PromptQueue.DeliveryTimeoutTest do
  use ExUnit.Case, async: true
  alias Ravix.Fountain
  alias Ravix.PromptQueue.{Server, Store}

  defmodule HungPost do
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:post_started, self()})
      receive do: (:release -> Plug.Conn.send_resp(conn, 503, "late"))
    end
  end

  test "the HTTP deadline bounds an unanswered POST well before delivery and recovery limits" do
    default = Fountain.Client.new("http://localhost", "test")
    assert default.http.timeout < Server.delivery_timeout_ms()
    assert Server.delivery_timeout_ms() < Store.claim_timeout_ms()

    server = start_supervised!({Bandit, plug: {HungPost, self()}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    client = Fountain.Client.new("http://127.0.0.1:#{port}", "test", timeout: 200)
    task = Task.async(fn -> Fountain.prompt(client, "conversation", "saved prompt", [], []) end)
    assert_receive {:post_started, handler}, 1000
    assert {:ok, {:error, %Fountain.Error{kind: :connection}}} = Task.yield(task, 1000)
    send(handler, :release)
  end
end
