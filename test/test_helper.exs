# Modules that tests stub with Mimic: each must be copied before the suite
# starts. Stub `Ravix.Fountain.client/0` to hand a context a fake-transport
# client; stub `Ravix.Config` readers to change configuration per test.
Mimic.copy(Ravix.Fountain)
Mimic.copy(Ravix.Config)

for mod <- [
      Ravix.GitHub,
      Ravix.Sprites,
      Ravix.Accounts.Access,
      Ravix.Accounts,
      Ravix.Accounts.Inference,
      Ravix.People,
      Ravix.People.Store,
      Ravix.Previews,
      Ravix.Previews.Agent,
      Ravix.Previews.Lifecycle,
      Ravix.Previews.Store,
      Ravix.Tracks,
      Ravix.Projects,
      Ravix.PromptQueue,
      Ravix.PromptQueue.Store,
      Ravix.Terminal,
      Ravix.Vitals,
      Ravix.MachineCache,
      Ravix.Health,
      Ravix.Clock
    ],
    do: Mimic.copy(mod)

# `test/ravix/cluster/distribution_test.exs` boots a second BEAM per test, so
# a plain `mix test` leaves it out; CI and `mix precommit` pass
# `--include distributed`, as a focused run of that file must.
ExUnit.start(exclude: [:distributed])
Ecto.Adapters.SQL.Sandbox.mode(Ravix.Repo, :manual)
