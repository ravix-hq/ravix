defmodule Ravix.QueryCount do
  @moduledoc """
  How many queries something cost, and against which tables.

  For the assertions that are about *cost* rather than about an answer. A
  list that reads correctly but re-reads the same project membership once
  per row is right and still a defect, and it is not one any assertion on
  the returned value can see: only the count grows.

  `count/1` runs `fun`, returns `{result, sources}`, and `sources` is one
  entry per query in the order they ran, named by the table. So a test can
  say a whole list costs a fixed number of queries however many rows it has,
  or that a page's message handling reads `sessions` once rather than four
  times.

      {list, queries} = QueryCount.count(fn -> Tracks.list(user, project.id) end)
      assert length(queries) == 7

  Only one process's queries are counted: the caller's, or the `:from` given
  for work that happens somewhere else, like a LiveView handling a message.
  Concurrent tests share a database but not a pid, so this is what keeps one
  test's count out of another's. The handler is attached and detached around
  `fun` under an id unique to the call.

  `from: {:callers, pid}` widens that to the processes working on `pid`'s
  behalf -- those naming it in `$callers`, as the tasks a sweep hands its
  rows to do -- and is still one test's own: the sandbox and Mimic follow the
  same list, so a process this counts is one the test already owns.
  """

  @event [:ravix, :repo, :query]

  @typedoc """
  `:from` is the process whose queries to count, the caller's by default;
  `{:callers, pid}` also counts every process that lists `pid` in `$callers`.
  """
  @type option :: {:from, pid() | {:callers, pid()}}

  @doc "Run `fun`, counting the queries it makes. Returns `{result, sources}`."
  @spec count((-> result), [option()]) :: {result, [String.t() | nil]} when result: term()
  def count(fun, opts \\ []) when is_function(fun, 0) do
    id = {__MODULE__, self(), System.unique_integer()}
    owner = self()
    watched = Keyword.get(opts, :from, owner)

    :telemetry.attach(
      id,
      @event,
      fn _event, _measure, meta, _config ->
        # The handler runs in whichever process made the query. The sandbox
        # means another test's connection may well be busy on the same table
        # at the same moment, so the pid is the filter, not the table.
        if watched?(watched), do: send(owner, {id, meta[:source]})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(id, [])}
    after
      :telemetry.detach(id)
    end
  end

  @doc "Just the count, for a test that does not need the answer."
  @spec queries((-> term()), [option()]) :: non_neg_integer()
  def queries(fun, opts \\ []), do: fun |> count(opts) |> elem(1) |> length()

  defp watched?(pid) when is_pid(pid), do: self() == pid

  defp watched?({:callers, pid}),
    do: self() == pid or pid in List.wrap(Process.get(:"$callers"))

  defp drain(id, acc) do
    receive do
      {^id, source} -> drain(id, [source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
