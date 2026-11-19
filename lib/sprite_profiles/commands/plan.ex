defmodule SpriteProfiles.Commands.Plan do
  @moduledoc """
  The plan command, shared by `sprite-profiles plan` and `mix profiles.plan`: print the
  merged plan of a set, or why it is refused. Returns the exit status: 0, or 1 when
  refused.

  Options are `SpriteProfiles.Planner.plan/2`'s.
  """

  alias SpriteProfiles.{Out, Plan, Planner}

  @doc "Plans `picks`; returns the exit status."
  @spec run([String.t()], keyword(), Out.t()) :: non_neg_integer()
  def run(picks, opts, %Out{} = out) do
    case Planner.plan(picks, opts) do
      {:ok, plan} ->
        Out.info(out, Plan.format(plan))
        0

      {:error, problems} ->
        Out.refused(out, problems)
    end
  end
end
