defmodule SpriteProfiles.ProfileHelpers do
  @moduledoc "Builds profiles from TOML text in tests, without touching the disk."

  alias SpriteProfiles.Profile

  @doc "Parses `toml` (which need not repeat the name) into a profile, or raises."
  def profile!(name, toml \\ "", opts \\ []) do
    case parse(name, toml, opts) do
      {:ok, p} -> p
      {:error, errors} -> raise "invalid test profile #{name}: #{inspect(errors)}"
    end
  end

  @doc "Parses `toml` into `{:ok, profile}` or `{:error, errors}`."
  def parse(name, toml, opts \\ []) do
    map = TomlElixir.decode!(toml, spec: :"1.0.0")

    map =
      map
      |> Map.put_new("name", name)
      |> Map.put_new("summary", "test profile #{name}")

    Profile.parse(map, Keyword.put_new(opts, :folder, name))
  end

  @doc "The codes of a list of errors or refusals."
  def codes(list), do: Enum.map(list, & &1.code)
end
