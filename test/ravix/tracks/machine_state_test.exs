defmodule Ravix.Tracks.MachineStateTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.{MachineState, Origin, View}

  @now ~U[2026-09-28 12:00:00Z]
  @asleep ~U[2026-09-28 11:00:00Z]

  # A presented track as the rail and the page hold it: open, set up, idle.
  defp view(overrides) do
    struct!(
      %View{
        id: "t1",
        project_id: "p1",
        owner_login: "owner",
        conversation_id: "c1",
        slug: "slug",
        title: "Title",
        branch: "branch",
        workdir: "/work/slug",
        origin: %Origin{kind: :blank, base: nil, number: nil, title: nil, url: nil},
        status: :ready,
        stale: false,
        opened_at: @now,
        last_active_at: nil,
        turn_count: 0,
        created_at: @now,
        created_by_login: "owner",
        people: [],
        role: :owner,
        unread: false,
        model: nil,
        setup_state: "ready",
        setup_attempts: 0,
        setup_error: nil,
        setup_retry_at: nil,
        repo_full_name: "ravix-hq/ravix"
      },
      overrides
    )
  end

  @dedicated [sandbox_layout: :dedicated, sandbox_state: :ready, sandbox_stage: "ready"]

  # {name, view overrides, options, state, detail}
  @table [
    {"a fresh dedicated open is Starting while it creates",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :provisioning,
       sandbox_action: :open,
       sandbox_stage: "creating",
       setup_state: "pending",
       status: :opening
     ], [], :starting, "Creating this track's machine…"},
    {"Starting names the repository while it clones",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :provisioning,
       sandbox_action: :open,
       sandbox_stage: "cloning",
       setup_state: "running",
       status: :opening
     ], [], :starting, "Cloning ravix-hq/ravix…"},
    {"Starting says so while setup runs",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :provisioning,
       sandbox_action: :open,
       sandbox_stage: "setup",
       setup_state: "running",
       status: :opening
     ], [], :starting, "Running setup…"},
    {"Starting waits for capacity in setup's words",
     [
       setup_state: "retry",
       setup_error_code: "sandbox_at_capacity",
       status: :opening
     ], [], :starting, "Waiting for capacity"},
    {"Starting counts a retry down",
     [
       setup_state: "retry",
       setup_attempts: 1,
       setup_retry_at: ~U[2026-09-28 12:00:30Z],
       status: :opening
     ], [], :starting, "Retrying (attempt 2 of 3, next in 30s)"},
    {"a rebuild is Restarting, not Starting",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :provisioning,
       sandbox_action: :rebuild,
       sandbox_stage: "creating",
       setup_state: "pending",
       status: :opening
     ], [], :restarting, "Creating this track's machine…"},
    {"a rebuild stays Restarting through setup until the sandbox is ready",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :provisioning,
       sandbox_action: :rebuild,
       sandbox_stage: "setup",
       setup_state: "running",
       status: :opening
     ], [], :restarting, "Running setup…"},
    {"a retried rebuild is still Restarting",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :provisioning,
       sandbox_action: :rebuild,
       sandbox_stage: "creating",
       setup_state: "pending"
     ], [running: true], :restarting, "Creating this track's machine…"},
    {"a finished rebuild is Idle again", @dedicated ++ [sandbox_action: :rebuild], [], :idle,
     nil},
    {"an old writer's provisioning row, with no action, reads as Starting",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :provisioning,
       sandbox_action: nil,
       sandbox_stage: "creating",
       setup_state: "pending",
       status: :opening
     ], [], :starting, "Creating this track's machine…"},
    {"a set-up row whose opening turn never reported back is Starting", [status: :opening], [],
     :starting, "Setting up…"},
    {"Working while any thread takes a turn", [status: :running], [], :working,
     "The agent is taking a turn."},
    {"Working when a sibling thread runs and the shown one is idle",
     [threads: [%{id: "a", status: :ready}, %{id: "b", status: :running}]], [], :working,
     "The agent is taking a turn."},
    {"a page's fresher per-thread states override the view", [status: :running], [running: false],
     :idle, nil},
    {"Idle when awake with nothing running", @dedicated, [], :idle, nil},
    {"Asleep once Fountain said the dedicated sandbox suspended",
     @dedicated ++ [sandbox_suspended_at: @asleep], [], :asleep, "Your next message wakes it."},
    {"Starting while a turn wakes an asleep sandbox",
     @dedicated ++ [sandbox_suspended_at: @asleep], [running: true], :starting,
     "Waking this track's machine…"},
    {"a legacy shared track never invents Asleep",
     [sandbox_layout: :shared, sandbox_state: nil, sandbox_suspended_at: @asleep], [], :idle,
     nil},
    {"a shared track whose setup parked on a refused read is Asleep, in setup's words",
     [
       sandbox_layout: :shared,
       sandbox_state: nil,
       setup_state: "running",
       setup_error_code: "sandbox_suspended",
       setup_error: "The project's machine is asleep. Send a prompt or wake it to finish setup.",
       status: :opening
     ], [], :asleep,
     "The project's machine is asleep. Send a prompt or wake it to finish setup."},
    {"a prompt on a parked shared track is Starting while it wakes",
     [
       sandbox_layout: :shared,
       sandbox_state: nil,
       setup_state: "running",
       setup_error_code: "sandbox_suspended",
       status: :opening
     ], [running: true], :starting, "Waking the project's machine…"},
    {"a legacy shared track reads Working while its turn runs",
     [sandbox_layout: :shared, sandbox_state: nil, status: :running], [], :working,
     "The agent is taking a turn."},
    {"a legacy shared track is Starting while it sets up",
     [sandbox_layout: :shared, sandbox_state: nil, setup_state: "pending", status: :opening], [],
     :starting, "Setting up…"},
    {"Error carries the setup failure's reason",
     [
       setup_state: "failed",
       status: :setup_failed,
       setup_error: "The opening turn finished without creating its worktree."
     ], [], :error, "The opening turn finished without creating its worktree."},
    {"Error when the dedicated sandbox failed",
     [
       sandbox_layout: :dedicated,
       sandbox_state: :failed,
       setup_error: "Fountain refused the sandbox."
     ], [], :error, "Fountain refused the sandbox."},
    {"a failed turn is no alarm: Idle, saying so", [status: :failed], [], :idle,
     "The last turn failed. Your next message carries on."},
    {"a turn that failed because the machine slept reads Asleep",
     @dedicated ++ [status: :failed, sandbox_suspended_at: @asleep], [], :asleep,
     "Your next message wakes it."},
    {"an error outranks a running turn",
     [setup_state: "failed", status: :setup_failed, setup_error: nil], [running: true], :error,
     "Setup failed"},
    {"Closing while the machine is cleaned up",
     [sandbox_layout: :dedicated, sandbox_state: :closing, sandbox_stage: "closing"],
     [running: true], :closing, "Closing… cleaning up this track's machine"},
    {"a closed track is Closing", [status: :closed], [], :closing, "Closed"}
  ]

  for {name, overrides, opts, state, detail} <- @table do
    @overrides overrides
    @opts opts
    @state state
    @detail detail
    test name do
      assert MachineState.of(view(@overrides), Keyword.put_new(@opts, :now, @now)) ==
               %{state: @state, detail: @detail}
    end
  end

  test "every state has its word" do
    states = Enum.map(@table, &elem(&1, 3)) |> Enum.uniq() |> Enum.sort()
    assert states == Enum.sort(~w(starting restarting working idle asleep closing error)a)

    assert Enum.map(states, &MachineState.label/1) |> Enum.sort() ==
             ~w(Asleep Closing Error Idle Restarting Starting Working)
  end

  describe "marker/2, the sidebar's dot" do
    for {state, unread, marker} <- [
          {:idle, false, nil},
          {:idle, true, :unread},
          {:asleep, false, :asleep},
          {:asleep, true, :unread},
          {:working, true, :working},
          {:starting, true, :starting},
          {:restarting, false, :restarting},
          {:error, true, :error},
          {:closing, true, :closing}
        ] do
      @state state
      @unread unread
      @marker marker
      test "#{state}, unread: #{unread}" do
        assert MachineState.marker(%{state: @state, detail: nil}, @unread) == @marker
      end
    end
  end
end
