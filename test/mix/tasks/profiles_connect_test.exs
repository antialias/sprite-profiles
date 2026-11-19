defmodule Mix.Tasks.Profiles.ConnectTest do
  # The task with its terminal and adapter replaced: what it prints, what it posts, and that
  # the token never reaches the shell.
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Mix.Tasks.Profiles.Connect
  alias SpriteProfiles.FakeSprites

  @token "dummy-token-in-test"

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, _kind, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  defp deps(sprites, terminal? \\ true),
    do: [terminal?: fn -> terminal? end, read_token: fn -> @token end, sprites: sprites]

  test "prints the connector, posts the derived body, tests it, and never shows the token" do
    {sprites, log} = FakeSprites.start()

    Connect.run(["-p", "github-mcp"], deps(sprites))

    out = output()
    assert out =~ "Connector:  github-mcp  (custom_api)"
    assert out =~ "Policy:     Sprites labelled profile:github-mcp; endpoints /mcp/*"
    assert out =~ "gateway URL: https://api.sprites.dev/v1/gateway/custom_api/conn_custom"
    assert out =~ "test:        ok"
    refute out =~ @token

    [[body]] = FakeSprites.calls(log, :create_custom_connector)
    assert body["name"] == "github-mcp"
    assert body["access_policy"]["sprite_labels"] == ["profile:github-mcp"]
    assert FakeSprites.calls(log, :test_custom_connector) == [["conn_custom"]]
  end

  test "refuses without a terminal, before reading a token or calling anything" do
    {sprites, log} = FakeSprites.start()
    deps = Keyword.put(deps(sprites, false), :read_token, fn -> flunk("read a token") end)

    assert catch_exit(Connect.run(["-p", "github-mcp"], deps)) == {:shutdown, 1}
    assert output() =~ "[needs_terminal]"
    assert FakeSprites.calls(log) == []
  end

  test "a failed credential test exits 1, still without the token" do
    {sprites, _log} =
      FakeSprites.start(fn
        {:test_custom_connector, _} -> {:ok, %{status: "error", message: "HTTP 401"}}
        _ -> :default
      end)

    assert catch_exit(Connect.run(["-p", "github-mcp"], deps(sprites))) == {:shutdown, 1}
    out = output()
    assert out =~ "error (HTTP 401)"
    refute out =~ @token
  end

  test "a profile with no custom connector is no_custom_connector" do
    {sprites, log} = FakeSprites.start()
    assert catch_exit(Connect.run(["-p", "github"], deps(sprites))) == {:shutdown, 1}
    assert output() =~ "[no_custom_connector]"
    assert FakeSprites.calls(log) == []
  end

  test "an empty token aborts with nothing sent" do
    {sprites, log} = FakeSprites.start()
    deps = Keyword.put(deps(sprites), :read_token, fn -> "" end)
    assert catch_exit(Connect.run(["-p", "github-mcp"], deps)) == {:shutdown, 1}
    assert output() =~ "nothing was sent"
    assert FakeSprites.calls(log) == []
  end

  test "takes exactly one profile and no token flag" do
    capture_io(:stderr, fn ->
      assert catch_exit(Connect.run(["-p", "github-mcp", "--token", "x"], [])) == {:shutdown, 2}
      assert catch_exit(Connect.run(["-p", "a", "-p", "b"], [])) == {:shutdown, 2}
      assert catch_exit(Connect.run([], [])) == {:shutdown, 2}
    end)
  end
end
