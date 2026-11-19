defmodule SpriteProfiles.Commands.Lock do
  @moduledoc """
  The lock command, shared by `sprite-profiles lock` and `mix profiles.lock`: resolve every
  address and name of a set to a commit, check that the set plans, and write the lock file.
  Returns the exit status: 0, or 1 when the set is refused.

  Options: `:dirs` (the search path), `:output` (the lock file to write), `:shown` (how
  to name that file in the last line; default `:output`), `:inputs` (`%{name => value}`)
  and those of `SpriteProfiles.Resolver.find/3`.
  """

  alias SpriteProfiles.{Lock, Merge, Out, Resolver}

  @doc "The bad-usage message for a lock with no picks."
  def no_picks, do: "name at least one profile"

  @doc "Locks `picks`; returns the exit status."
  @spec run([String.t()], keyword(), Out.t()) :: non_neg_integer()
  def run([], _opts, %Out{} = out), do: Out.usage(out, no_picks())

  def run(picks, opts, %Out{} = out) do
    path = Keyword.fetch!(opts, :output)
    inputs = opts[:inputs] || %{}
    resolve_opts = Keyword.drop(opts, [:dirs, :output, :shown, :inputs])

    with :ok <- Merge.check_picks(picks),
         {:ok, profiles} <- Resolver.find(picks, Keyword.fetch!(opts, :dirs), resolve_opts),
         {:ok, _plan} <- Merge.merge(profiles, inputs: inputs) do
      entries = Lock.entries(profiles)
      kinds = for %{source: %{kind: k}, pick: p} <- profiles, into: %{}, do: {p, k}

      moved =
        case File.exists?(path) and Lock.read(path) do
          {:ok, old} -> Lock.diff(old, entries, kinds)
          _ -> []
        end

      Lock.write(path, profiles, inputs)

      Enum.each(profiles, fn
        %{source: nil, pick: p} ->
          Out.info(out, "  #{p}  (local)")

        %{source: %{version: v} = s, pick: p} when is_binary(v) ->
          Out.info(out, "  #{p}  version #{v}, tag #{s.ref} = #{String.slice(s.sha, 0, 8)}")

        %{source: s, pick: p} ->
          Out.info(out, "  #{p}  #{s.kind} #{s.ref} = #{String.slice(s.sha, 0, 8)}")
      end)

      Enum.each(moved, &Out.info(out, "Moved: #{&1}"))
      Out.info(out, "Locked #{length(profiles)} picks in #{opts[:shown] || path}")
      0
    else
      {:error, problems} -> Out.refused(out, problems)
    end
  end
end
