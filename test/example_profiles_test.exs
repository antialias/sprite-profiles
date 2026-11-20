defmodule SpriteProfiles.ExampleProfilesTest do
  # The example profiles under profiles/ load, and merge in the compositions the README shows.
  use ExUnit.Case, async: true

  alias SpriteProfiles.{Merge, Profile}

  describe "the example profiles in profiles/" do
    test "all load cleanly" do
      {profiles, errors} = Profile.load_all("profiles")
      assert errors == []

      assert Enum.map(profiles, & &1.name) ==
               ~w(anthropic anthropic-key claude-code github github-mcp playwright preview)
    end

    test "no secret appears outside a privileged profile" do
      # Belt and braces over secret_needs_privileged: scan the raw text too.
      for toml <- Path.wildcard("profiles/*/profile.toml") do
        map = toml |> File.read!() |> TomlElixir.decode!()
        secrets? = File.read!(toml) =~ ~r/secret\s*=/

        if secrets?, do: assert(map["privileged"] == true, "#{toml} reads a secret")
      end
    end
  end

  describe "the example compositions" do
    setup do
      {profiles, []} = Profile.load_all("profiles")
      %{by_name: Map.new(profiles, &{&1.name, &1})}
    end

    for set <- [
          ~w(claude-code github),
          ~w(claude-code github playwright),
          ~w(claude-code anthropic-key),
          ~w(claude-code github-mcp),
          ~w(claude-code github github-mcp),
          ~w(preview)
        ] do
      test "#{Enum.join(set, " + ")} merges for a person", %{by_name: by_name} do
        assert {:ok, _} = Merge.merge(Enum.map(unquote(set), &by_name[&1]))
      end
    end

    test "claude-code + anthropic-key is refused for an agent", %{by_name: by_name} do
      {:error, [r]} =
        Merge.merge([by_name["claude-code"], by_name["anthropic-key"]], caller: :agent)

      assert r.code == :not_for_agents
    end
  end
end
