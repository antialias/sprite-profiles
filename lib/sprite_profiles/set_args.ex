defmodule SpriteProfiles.SetArgs do
  @moduledoc """
  The options `mix profiles.plan` and `mix profiles.launch` share for naming a set: either
  `--profile` picks, or `--lock FILE`, never both; and `--offline`.
  """

  alias SpriteProfiles.Lock

  @doc """
  Returns `{:ok, picks, resolve_opts}`, `{:usage, message}` when both `--profile` and
  `--lock` are given, or `{:error, refusals}` when the lock cannot be read.
  """
  def picks(opts) do
    profiles = Keyword.get_values(opts, :profile)
    offline = [offline: opts[:offline] || false]

    case {profiles, opts[:lock]} do
      {[_ | _], lock} when is_binary(lock) ->
        {:usage, "--lock and --profile name the set twice; give one of them"}

      {_, lock} when is_binary(lock) ->
        with {:ok, entries} <- Lock.read(lock) do
          {:ok, Lock.picks(entries), [pins: Lock.pins(entries)] ++ offline}
        end

      {profiles, nil} ->
        {:ok, profiles, offline}
    end
  end
end
