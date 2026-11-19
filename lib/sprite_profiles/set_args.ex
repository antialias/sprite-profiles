defmodule SpriteProfiles.SetArgs do
  @moduledoc """
  The options `mix profiles.plan`, `mix profiles.launch` and `mix profiles.lock` share for
  naming a set: either `--profile` picks, or `--lock FILE`, never both; `--input name=value`
  (`-i`) values for the set's inputs, which a lock holds itself; and `--offline`.
  """

  alias SpriteProfiles.Lock

  @no_picks "name at least one profile, or give --lock FILE"

  @doc "The bad-usage message for a set with no picks and no lock, the same everywhere."
  def no_picks, do: @no_picks

  @doc """
  Returns `{:ok, picks, resolve_opts}` (with `:inputs`, `:offline` and, from a lock,
  `:pins`), `{:usage, message}` when neither `--profile` nor `--lock` is given, both are,
  `--lock` comes with `-i`, or an `-i` is not `name=value`; or `{:error, refusals}` when
  the lock cannot be read.
  """
  def picks(opts) do
    profiles = Keyword.get_values(opts, :profile)
    given = Keyword.get_values(opts, :input)
    offline = [offline: opts[:offline] || false]

    case {profiles, opts[:lock], given} do
      {[], nil, _} ->
        {:usage, @no_picks}

      {[_ | _], lock, _} when is_binary(lock) ->
        {:usage, "--lock and --profile name the set twice; give one of them"}

      {_, lock, [_ | _]} when is_binary(lock) ->
        {:usage,
         "--lock holds the set's inputs; to change one, lock the set again with mix profiles.lock -i"}

      {_, lock, _} when is_binary(lock) ->
        with {:ok, %{picks: entries, inputs: inputs}} <- Lock.load(lock) do
          {:ok, Lock.picks(entries), [pins: Lock.pins(entries), inputs: inputs] ++ offline}
        end

      {profiles, nil, given} ->
        with {:ok, inputs} <- inputs(given), do: {:ok, profiles, [inputs: inputs] ++ offline}
    end
  end

  @doc """
  Parses `-i` values (`name=value`, split at the first `=`) into a map, or
  `{:usage, message}` for one without `=` or a name given twice.
  """
  def inputs(given) do
    Enum.reduce_while(given, {:ok, %{}}, fn arg, {:ok, acc} ->
      case String.split(arg, "=", parts: 2) do
        [name, value] when name != "" ->
          if Map.has_key?(acc, name),
            do: {:halt, {:usage, "input #{name} is given twice; give it once"}},
            else: {:cont, {:ok, Map.put(acc, name, value)}}

        _ ->
          {:halt, {:usage, "-i takes name=value, and #{inspect(arg)} is not"}}
      end
    end)
  end
end
