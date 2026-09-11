defmodule Ravix.Vitals do
  @moduledoc """
  How much of the machine is left.

  The rest of the app never asks this, and deliberately: a project is a
  machine, the machine is Fountain's to size, and there is nothing in the UI
  that would be improved by a gauge. But four tracks on one box share one
  CPU allowance, one memory limit and one disk, and when the fourth
  `bun install` of the afternoon starts swapping, the question "is it me or
  is it the box?" has no other way to be answered from here. That is a power
  user's question, so this is a power user's readout: one dim line, in the
  strip that already belongs to the machine.

  It rides on the same path as the terminal, for the same reason: reads of a
  Fountain sandbox cannot see `/proc`, so the only way to a load figure is
  Sprites' exec, which means this panel has exactly the terminal's four
  failure states and shares its answer for them.

  **Everything here is best-effort by design.** The numbers come from files
  that a given kernel, runtime or image may not have: `cpu.max` and
  `cpu.stat` are cgroup v2, `MemAvailable` arrived in Linux 3.14, and `df`
  can be refused outright. So the probe reads whatever is there, reports
  blanks for the rest, and this module's job is to turn that into a shape
  where a number that could not be read is *absent* rather than zero.
  "0% CPU" and "we could not tell" are different claims and only one of them
  is ever true.
  """

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Sprites
  alias Ravix.Tracks

  # The two CPU samples are 0.3s apart, as the script writes it. Short enough
  # that the whole request stays under half a second, long enough that the
  # delta is not dominated by the cost of reading it. The elapsed time is
  # measured rather than assumed (`sleep 0.3` is a GNU nicety that busybox may
  # round to a second), so this is only a target.

  # The probe is three file reads and a `df`; it has no business taking longer.
  @probe_timeout_sec 15

  # The script itself. `st` is user+nice+system+idle+iowait+irq+softirq, then
  # the two idle fields: host wide inside a container, so only ever the
  # fallback. `__WORKDIR__` is replaced, quoted, by `probe/1`.
  @probe ~S"""
  p() { printf '%s=%s\n' "$1" "$2"; }
  clock() { awk '{print $1}' /proc/uptime 2>/dev/null; }
  cg() { awk '/^usage_usec /{print $2}' /sys/fs/cgroup/cpu.stat 2>/dev/null; }
  st() { awk '/^cpu /{print ($2+$3+$4+$5+$6+$7+$8), ($5+$6)}' /proc/stat 2>/dev/null; }
  p t0 "$(clock)"; p cg0 "$(cg)"; p st0 "$(st)"
  sleep 0.3
  p t1 "$(clock)"; p cg1 "$(cg)"; p st1 "$(st)"
  p nproc "$(nproc 2>/dev/null)"
  p cpumax "$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"
  p memcur "$(cat /sys/fs/cgroup/memory.current 2>/dev/null)"
  p memmax "$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
  p meminfo "$(awk '/^MemTotal:|^MemAvailable:/{printf "%s ", $2}' /proc/meminfo 2>/dev/null)"
  p df "$({ df -kP __WORKDIR__ 2>/dev/null || df -kP / 2>/dev/null; } | awk 'NR==2{print $2, $3, $6}')"
  """

  @typedoc "Why a machine cannot be reached over Sprites, when it cannot."
  @type unreachable :: :no_token | :no_machine | :no_sprite | :unreachable

  defmodule Readings do
    @moduledoc """
    CPU, memory and disk on the machine a track's worktree is on. Every field
    is nullable and independently so -- a kernel missing one file must not
    take the other six figures down with it. These are the *machine's*
    figures, not the track's: four tracks on one project share a box.

    `rows/1` exists because the dock used to render this by iterating the
    map, which put the row order at the mercy of Erlang's term ordering
    rather than anybody's decision. The order is here, once, and reads
    processor, then memory, then disk.
    """

    @enforce_keys [
      :cpu_cores,
      :cpu_busy,
      :mem_used_bytes,
      :mem_total_bytes,
      :disk_used_bytes,
      :disk_total_bytes,
      :disk_mount
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            cpu_cores: number() | nil,
            cpu_busy: number() | nil,
            mem_used_bytes: number() | nil,
            mem_total_bytes: number() | nil,
            disk_used_bytes: number() | nil,
            disk_total_bytes: number() | nil,
            disk_mount: String.t() | nil
          }

    @labels [
      cpu_cores: "Processors",
      cpu_busy: "CPU in use",
      mem_used_bytes: "Memory used",
      mem_total_bytes: "Memory total",
      disk_used_bytes: "Disk used",
      disk_total_bytes: "Disk total",
      disk_mount: "Disk mount"
    ]

    @doc "The readings worth drawing, labelled, in the order the dock shows them."
    @spec rows(t()) :: [{String.t(), term()}]
    def rows(%__MODULE__{} = readings) do
      for {field, label} <- @labels,
          value = Map.fetch!(readings, field),
          not is_nil(value),
          do: {label, value}
    end
  end

  defmodule Report do
    @moduledoc """
    `GET /api/tracks/:id/vitals`: the same four answers the terminal gives.

    Reachable but illegible is its own answer -- `readings: nil` with
    `available: true` -- and the dock renders nothing rather than a row of
    dashes, because dashes read as a fault and this is a machine that is
    working fine and merely quiet about it.
    """

    @enforce_keys [:available, :why, :readings]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            available: boolean(),
            why: Ravix.Vitals.unreachable() | nil,
            readings: Readings.t() | nil
          }
  end

  @doc """
  The readout for a track's machine.

  A machine that is asleep is the common case here, and it is not an error:
  it wakes on the next turn. The readout simply goes away. Reachable but
  illegible is its own answer: `vitals: nil` with `available: true`, and the
  readout renders nothing rather than a row of dashes, because a line of
  dashes reads as a fault and this is a machine that is working fine and
  merely private about it.
  """
  @spec report(User.t(), String.t()) :: {:ok, Report.t()} | {:error, :not_found}
  def report(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      {:ok, read(Sprites.config(), track, project)}
    end
  end

  defp read(nil, _track, _project), do: out(:no_token)

  defp read(sprites, track, project) do
    with {:ok, %{sandbox_id: sandbox_id}} <- machine(project),
         sprite when is_binary(sprite) <- Tracks.sprite_for(sandbox_id) || :no_sprite,
         {:ok, raw} <-
           Sprites.exec(sprites, sprite, ["sh", "-lc", probe(track.workdir)], @probe_timeout_sec) do
      %Report{available: true, why: nil, readings: parse_vitals(raw.stdout)}
    else
      :no_machine -> out(:no_machine)
      :no_sprite -> out(:no_sprite)
      {:error, _} -> out(:unreachable)
    end
  end

  defp machine(project) do
    case Tracks.machine_of(project) do
      {:ok, %{sandbox_id: _} = machine} -> {:ok, machine}
      _ -> :no_machine
    end
  end

  defp out(why), do: %Report{available: false, why: why, readings: nil}

  @doc """
  The script, which prints `key=value` lines and never fails.

  Every read is guarded, because a probe that exits non-zero on a kernel
  missing one file would take the other five figures down with it. The two
  CPU samples bracket a sleep and each carry a clock reading, so the server
  divides by the interval that actually elapsed.

  `df` prints its mount point along with its numbers so the readout can name
  the filesystem it measured rather than the directory it asked about, which
  differ the moment a worktree is on a volume of its own.
  """
  @spec probe(String.t()) :: String.t()
  def probe(workdir) do
    String.replace(String.trim_trailing(@probe, "\n"), "__WORKDIR__", Sprites.shq(workdir))
  end

  @doc """
  The probe's output, as numbers.

  Pure, so the tests can hold it against the output of real kernels (a
  cgroup v2 container, a v1 one, and a box where half of it is missing),
  which is the only way to be confident about a parser whose whole job is
  tolerating absence. Nothing legible at all is nil rather than a reading
  with six holes in it: the readout wants to know the difference so it can
  render nothing.
  """
  @spec parse_vitals(String.t()) :: Readings.t() | nil
  def parse_vitals(stdout) do
    f = fields(stdout)

    # The allowance the CPU figure is a fraction *of*. A quota is the honest
    # denominator where there is one; without it, every core the box can see.
    cpu_cores = quota_cores(f["cpumax"]) || num(f["nproc"])
    cpu_busy = cpu_busy(f, cpu_cores)
    {mem_used, mem_total} = memory(f)

    [df_total, df_used, mount] =
      f["df"] |> words() |> Enum.concat([nil, nil, nil]) |> Enum.take(3)

    v = %Readings{
      cpu_cores: cpu_cores,
      cpu_busy: cpu_busy,
      mem_used_bytes: mem_used,
      mem_total_bytes: mem_total,
      disk_used_bytes: kb(df_used),
      disk_total_bytes: kb(df_total),
      disk_mount: mount
    }

    if is_nil(cpu_cores) and is_nil(cpu_busy) and is_nil(mem_total) and is_nil(v.disk_total_bytes),
      do: nil,
      else: v
  end

  defp cpu_busy(f, cpu_cores) do
    usec = delta(f["cg0"], f["cg1"])
    elapsed = delta(f["t0"], f["t1"])

    if usec != nil and elapsed != nil and elapsed > 0 and cpu_cores not in [nil, 0] do
      clamp(usec / 1.0e6 / elapsed / cpu_cores)
    else
      # No cgroup v2 accounting. `/proc/stat` inside a container is the
      # host's, which overstates a quiet neighbour and understates a busy one,
      # but it is the difference between a rough answer and none.
      with [a_total, a_idle] <- pair(f["st0"]),
           [b_total, b_idle] <- pair(f["st1"]),
           true <- b_total > a_total do
        clamp((b_total - a_total - (b_idle - a_idle)) / (b_total - a_total))
      else
        _ -> nil
      end
    end
  end

  # Two pairs, and they are not mixed unless they have to be: the cgroup's
  # current-against-limit describes this container, `/proc/meminfo`'s
  # total-against-available describes the box, and one number from each would
  # describe neither.
  defp memory(f) do
    cg_used = num(f["memcur"])
    cg_total = if f["memmax"] == "max", do: nil, else: num(f["memmax"])

    [total_kb, avail_kb] =
      f["meminfo"] |> words() |> Enum.map(&num/1) |> Enum.concat([nil, nil]) |> Enum.take(2)

    cond do
      cg_used != nil and cg_total != nil -> {cg_used, cg_total}
      total_kb != nil and avail_kb != nil -> {(total_kb - avail_kb) * 1024, total_kb * 1024}
      # An uncapped cgroup on a kernel too old for `MemAvailable`. What this
      # container is using, against what the box has: the two halves come
      # from different places, and it is still the useful comparison.
      total_kb != nil -> {cg_used, total_kb * 1024}
      true -> {nil, nil}
    end
  end

  defp fields(stdout) do
    stdout
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] when key != "" -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp words(nil), do: []
  defp words(text), do: text |> String.split(~r/\s+/) |> Enum.reject(&(&1 == ""))

  # A decimal, or nil for anything that is not one, including "", "max" and "N".
  defp num(nil), do: nil
  defp num(""), do: nil

  defp num(text) do
    case Integer.parse(text) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(text) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp kb(text) do
    case num(text) do
      nil -> nil
      n -> n * 1024
    end
  end

  # Two counters, later minus earlier. Nil if either is missing or it went backwards.
  defp delta(a, b) do
    from = num(a)
    to = num(b)
    if from == nil or to == nil or to < from, do: nil, else: to - from
  end

  # `"<total> <idle>"`, both numbers or nothing.
  defp pair(text) do
    case text |> words() |> Enum.map(&num/1) do
      [total, idle] when total != nil and idle != nil -> [total, idle]
      _ -> nil
    end
  end

  @doc """
  `cpu.max` as a core count: `"200000 100000"` is two cores, `"max 100000"`
  is no quota at all, which is nil here rather than zero, so the caller falls
  through to `nproc`.
  """
  @spec quota_cores(String.t() | nil) :: number() | nil
  def quota_cores(text) do
    case text |> words() |> Enum.map(&num/1) do
      [q, p | _] when is_number(q) and is_number(p) and q > 0 and p > 0 -> q / p
      _ -> nil
    end
  end

  # Sampling error and a rounded clock can put this a hair outside 0..1.
  defp clamp(n) when is_number(n), do: n |> min(1) |> max(0)
end
