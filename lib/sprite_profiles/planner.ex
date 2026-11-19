defmodule SpriteProfiles.Planner do
  @moduledoc """
  Resolves and merges a set of picks into a plan, without printing anything. Shared by
  `mix profiles.plan` and the `sprite-profiles plan` command.
  """

  alias SpriteProfiles.{Merge, Resolver}

  @doc """
  Checks `picks`, finds them along `opts[:dirs]` (or GitHub, for an address) and merges them
  for `opts[:caller]` with `opts[:inputs]`. Other `opts` go to `Resolver.find/3`. Returns
  `{:ok, plan}` or `{:error, problems}`.
  """
  def plan(picks, opts) do
    with :ok <- Merge.check_picks(picks),
         {:ok, profiles} <- Resolver.find(picks, opts[:dirs], opts) do
      Merge.merge(profiles, caller: opts[:caller], inputs: opts[:inputs] || %{})
    end
  end
end
