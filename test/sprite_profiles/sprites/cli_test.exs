defmodule SpriteProfiles.Sprites.CliTest do
  # The CLI adapter with its runner replaced: the commands it would run, and how it reads
  # what they print.
  use ExUnit.Case, async: true

  alias SpriteProfiles.Sprites.Cli

  defp cfg(answer) do
    test = self()

    runner = fn bin, args, stderr ->
      send(test, {:ran, bin, args, stderr})
      answer.(args)
    end

    [runner: runner]
  end

  test "REST calls go through sprite api with the status appended, stderr discarded" do
    cfg = cfg(fn _ -> {~s({"name":"demo-1","labels":["a"]}\n200), 0} end)
    assert {:ok, %{name: "demo-1", labels: ["a"]}} = Cli.create(cfg, "demo-1", ["a"])

    assert_received {:ran, "sprite", args, :discard}

    assert args == [
             "api",
             "/v1/sprites",
             "--",
             "-sS",
             "-X",
             "POST",
             "-w",
             "\n%{http_code}",
             "-H",
             "Content-Type: application/json",
             "-d",
             ~s({"labels":["a"],"name":"demo-1"})
           ]
  end

  test "a non-2xx answer is an error naming the status; an HTML page is not pasted" do
    cfg = cfg(fn _ -> {"<!DOCTYPE html><html>...</html>\n404", 0} end)
    assert {:error, message} = Cli.get(cfg, "nope")
    assert message == "the Sprites API answered 404 to GET /v1/sprites/nope: (an HTML page)"
  end

  test "an empty 200 (set policy) is fine" do
    cfg = cfg(fn _ -> {"\n200", 0} end)
    assert :ok = Cli.set_policy(cfg, "demo-1", %{"rules" => []})
  end

  test "exec passes the argv after -- with no stdin, and returns the exit status" do
    cfg = cfg(fn _ -> {"boom\n", 3} end)

    assert {:ok, %{status: 3, output: "boom\n"}} =
             Cli.exec(cfg, "demo-1", ["bash", "-c", "x"], [])

    assert_received {:ran, "sprite",
                     ["exec", "-s", "demo-1", "--no-stdin", "--", "bash", "-c", "x"], :merge}
  end

  test "write_file pushes a private temp copy with -p and the mode" do
    test = self()

    cfg =
      cfg(fn ["file", "push", "-p", "-s", "demo-1", local, "/home/sprite/x/env.sh"] ->
        send(test, {:local, local, File.read!(local), File.stat!(local).mode})
        {"", 0}
      end)

    assert :ok = Cli.write_file(cfg, "demo-1", "/home/sprite/x/env.sh", "A=1\n", 0o600)
    assert_received {:local, local, "A=1\n", mode}
    assert Bitwise.band(mode, 0o777) == 0o600
    refute File.exists?(local)
  end

  test "checkpoint reads the version the CLI prints" do
    cfg = cfg(fn _ -> {"● Creating checkpoint...\n✓ Checkpoint v2 created\n", 0} end)
    assert {:ok, "v2"} = Cli.checkpoint(cfg, "demo-1", "profiled: a")

    assert_received {:ran, "sprite",
                     ["checkpoint", "create", "-s", "demo-1", "--comment", "profiled: a"], :merge}
  end

  test "destroy forces, so it never waits on a prompt" do
    cfg = cfg(fn _ -> {"destroyed", 0} end)
    assert :ok = Cli.destroy(cfg, "demo-1")
    assert_received {:ran, "sprite", ["destroy", "--force", "demo-1"], :merge}
  end

  test "a custom connector's body goes on standard input, never in the arguments" do
    answer =
      ~s({"connection":{"id":"conn_1","provider":"custom_api","provider_account_name":"echo","provider_info":{"base_api_url":"https://x.io"}}}\n201)

    cfg = cfg(fn _ -> {answer, 0} end)
    body = %{"name" => "echo", "access_token" => "dummy-token-in-test"}

    assert {:ok, %{id: "conn_1", name: "echo", base_url: "https://x.io"}} =
             Cli.create_custom_connector(cfg, body)

    assert_received {:ran, "sprite", args, {:stdin, data}}
    assert Jason.decode!(data) == body
    refute Enum.any?(args, &(&1 =~ "dummy-token-in-test"))

    assert args == [
             "api",
             "/v1/oauth/connections/custom_api",
             "--",
             "-sS",
             "-X",
             "POST",
             "-w",
             "\n%{http_code}",
             "-H",
             "Content-Type: application/json",
             "--data-binary",
             "@-"
           ]
  end

  test "the default runner passes standard input through and ends it" do
    assert {"hello", 0} = Cli.default_runner("cat", [], {:stdin, "hello"})
  end

  test "an error answer does not echo the request" do
    cfg = cfg(fn _ -> {~s({"error":"bad base url"}\n422), 0} end)
    body = %{"name" => "echo", "access_token" => "dummy-token-in-test"}
    assert {:error, message} = Cli.create_custom_connector(cfg, body)
    assert message =~ "422"
    refute message =~ "dummy-token-in-test"
  end

  test "test_custom_connector sends the id alone and reads the result" do
    cfg = cfg(fn _ -> {~s({"result":{"status":"ok","message":"HTTP 200"}}\n200), 0} end)
    assert {:ok, %{status: "ok", message: "HTTP 200"}} = Cli.test_custom_connector(cfg, "conn_1")
    assert_received {:ran, "sprite", args, :discard}
    assert List.last(args) == ~s({"connection_id":"conn_1"})
    assert "/v1/oauth/connections/custom_api/test" in args
  end
end
