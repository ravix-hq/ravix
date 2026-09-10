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
      Ravix.People,
      Ravix.People.Store,
      Ravix.Previews,
      Ravix.Previews.Agent,
      Ravix.Tracks,
      Ravix.Projects,
      Ravix.PromptQueue,
      Ravix.PromptQueue.Store,
      Ravix.Terminal,
      Ravix.Vitals,
      Ravix.MachineCache,
      Ravix.Health,
      Ravix.Previews.Clock
    ],
    do: Mimic.copy(mod)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Ravix.Repo, :manual)
