defmodule SpriteProfiles.ClaudeSettingsTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.ClaudeSettings

  test "combinable lists are hooks arrays and permissions.allow/deny" do
    assert ClaudeSettings.combinable?(["hooks", "Stop"])
    assert ClaudeSettings.combinable?(["permissions", "allow"])
    assert ClaudeSettings.combinable?(["permissions", "deny"])
    refute ClaudeSettings.combinable?(["permissions", "additionalDirectories"])
    refute ClaudeSettings.combinable?(["hooks"])
    refute ClaudeSettings.combinable?(["env", "X"])
  end

  test "overlay appends a profile's hooks after the image's and keeps the rest" do
    base = %{
      "permissions" => %{"defaultMode" => "bypassPermissions"},
      "hooks" => %{"PreToolUse" => [%{"matcher" => "x", "hooks" => []}]}
    }

    fragment = %{
      "env" => %{"A" => "1"},
      "hooks" => %{
        "PreToolUse" => [%{"hooks" => [%{"command" => "hold"}]}],
        "Stop" => [%{"hooks" => [%{"command" => "release"}]}]
      }
    }

    assert ClaudeSettings.overlay(base, fragment) == %{
             "permissions" => %{"defaultMode" => "bypassPermissions"},
             "env" => %{"A" => "1"},
             "hooks" => %{
               "PreToolUse" => [
                 %{"matcher" => "x", "hooks" => []},
                 %{"hooks" => [%{"command" => "hold"}]}
               ],
               "Stop" => [%{"hooks" => [%{"command" => "release"}]}]
             }
           }
  end

  test "overlay is idempotent: applying the same fragment twice adds nothing" do
    fragment = %{"hooks" => %{"Stop" => [%{"hooks" => [%{"command" => "release"}]}]}}
    once = ClaudeSettings.overlay(%{}, fragment)
    assert ClaudeSettings.overlay(once, fragment) == once
  end
end
