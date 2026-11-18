defmodule SpriteProfiles.ClaudeSettings do
  @moduledoc """
  The Claude Code settings rules that `SpriteProfiles.Merge` and the launcher share.

  Most settings are scalar leaves: two profiles may set one only to the same value. A few
  are lists that Claude Code itself reads as "every entry applies": the `hooks` arrays (one
  per event) and `permissions.allow` / `permissions.deny`. Those **combine**: entries are
  appended in pick order, each entry kept whole, and an identical entry is kept once.
  """

  @doc "True when the setting at `path` is a list whose entries combine instead of colliding."
  @spec combinable?([String.t()]) :: boolean()
  def combinable?(["hooks", _event]), do: true
  def combinable?(["permissions", list]) when list in ["allow", "deny"], do: true
  def combinable?(_), do: false

  @doc "Appends `more` to `list`, keeping each entry whole and dropping exact duplicates."
  @spec combine(list(), list()) :: list()
  def combine(list, more), do: Enum.uniq(list ++ more)

  @doc """
  Lays a profile's settings `fragment` over the `base` settings already on a Sprite.

  Combinable lists append (deduplicated); tables merge; any other leaf in the fragment
  replaces the base's. The base is the image's own file, not a profile, so it does not
  refuse: the profiles were already checked against each other by `SpriteProfiles.Merge`.
  """
  @spec overlay(map(), map()) :: map()
  def overlay(base, fragment), do: overlay(base, fragment, [])

  defp overlay(base, fragment, path) do
    Enum.reduce(fragment, base, fn {key, value}, acc ->
      here = path ++ [key]

      merged =
        case {Map.get(acc, key), value} do
          {old, new} when is_list(old) and is_list(new) ->
            if combinable?(here), do: combine(old, new), else: new

          {old, new} when is_map(old) and is_map(new) ->
            overlay(old, new, here)

          {_, new} ->
            new
        end

      Map.put(acc, key, merged)
    end)
  end
end
