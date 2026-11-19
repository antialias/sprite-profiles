defmodule SpriteProfiles.Sprites.ApiTest do
  # The REST adapter against Req's test plug: the requests it makes and how it reads the
  # answers. No network and no real token.
  use ExUnit.Case, async: true

  alias SpriteProfiles.Sprites.Api

  @token "test-token-not-real"

  defp cfg(stub), do: [token: @token, req_options: [plug: {Req.Test, stub}]]

  defp stub(name, fun) do
    Req.Test.stub(name, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
      fun.(conn)
    end)

    cfg(name)
  end

  defp body(conn) do
    {:ok, body, _} = Plug.Conn.read_body(conn)
    body
  end

  test "from_env prefers SPRITES_TOKEN, accepts SPRITE_TOKEN, and names which" do
    assert {:ok, [token: "a"], "SPRITES_TOKEN"} =
             Api.from_env(%{"SPRITES_TOKEN" => "a", "SPRITE_TOKEN" => "b"})

    assert {:ok, [token: "b"], "SPRITE_TOKEN"} = Api.from_env(%{"SPRITE_TOKEN" => "b"})
    assert {:error, message} = Api.from_env(%{})
    assert message =~ "SPRITES_TOKEN"
  end

  test "create posts the name and labels and reads the Sprite back" do
    cfg =
      stub(:api_create, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/sprites"
        assert Jason.decode!(body(conn)) == %{"name" => "demo-1", "labels" => ["profile:a"]}

        Req.Test.json(conn, %{
          "name" => "demo-1",
          "labels" => ["profile:a"],
          "url" => "https://example.test"
        })
      end)

    assert {:ok, %{name: "demo-1", labels: ["profile:a"], url: "https://example.test"}} =
             Api.create(cfg, "demo-1", ["profile:a"])
  end

  test "set_labels puts the whole list" do
    cfg =
      stub(:api_labels, fn conn ->
        assert {conn.method, conn.request_path} == {"PUT", "/v1/sprites/demo-1"}
        assert Jason.decode!(body(conn)) == %{"labels" => ["x", "y"]}
        Req.Test.json(conn, %{"name" => "demo-1", "labels" => ["x", "y"]})
      end)

    assert {:ok, %{labels: ["x", "y"]}} = Api.set_labels(cfg, "demo-1", ["x", "y"])
  end

  test "list_connectors normalizes the access policy" do
    cfg =
      stub(:api_connectors, fn conn ->
        assert conn.request_path == "/v1/oauth/connections"

        Req.Test.json(conn, %{
          "connections" => [
            %{
              "id" => "conn_1",
              "provider" => "github",
              "access_policy" => %{"sprite_labels" => ["profile:github"], "name_prefix" => ""}
            },
            %{"id" => "conn_2", "provider" => "slack", "access_policy" => %{"allow_all" => true}}
          ]
        })
      end)

    assert {:ok,
            [
              %{
                id: "conn_1",
                provider: "github",
                allow_all: false,
                sprite_labels: ["profile:github"],
                name_prefix: nil
              },
              %{id: "conn_2", provider: "slack", allow_all: true, sprite_labels: []}
            ]} = Api.list_connectors(cfg)
  end

  test "set_policy posts the rules and accepts an empty answer" do
    cfg =
      stub(:api_policy, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/v1/sprites/demo-1/policy/network"}
        assert Jason.decode!(body(conn)) == %{"rules" => [%{"include" => "defaults"}]}
        Plug.Conn.send_resp(conn, 200, "")
      end)

    assert :ok = Api.set_policy(cfg, "demo-1", %{"rules" => [%{"include" => "defaults"}]})
  end

  test "put_service sends the service and reads its NDJSON progress" do
    cfg =
      stub(:api_service, fn conn ->
        assert {conn.method, conn.request_path} == {"PUT", "/v1/sprites/demo-1/services/web"}

        assert Jason.decode!(body(conn)) == %{
                 "cmd" => "python3",
                 "args" => ["-m", "http.server"],
                 "needs" => [],
                 "http_port" => 8080,
                 "dir" => "/home/sprite/site"
               }

        Plug.Conn.send_resp(conn, 200, ~s({"type":"started"}\n{"type":"complete"}\n))
      end)

    spec = %{
      name: "web",
      cmd: "python3",
      args: ["-m", "http.server"],
      http_port: 8080,
      dir: "/home/sprite/site"
    }

    assert :ok = Api.put_service(cfg, "demo-1", "web", spec)

    cfg =
      stub(:api_service_error, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"type":"error","data":"no such binary"}\n))
      end)

    assert {:error, "service 'web' did not start: no such binary"} =
             Api.put_service(cfg, "demo-1", "web", spec)
  end

  test "write_file puts raw bytes with the mode and mkdir" do
    cfg =
      stub(:api_write, fn conn ->
        assert {conn.method, conn.request_path} == {"PUT", "/v1/sprites/demo-1/fs/write"}

        assert URI.decode_query(conn.query_string) == %{
                 "path" => "/home/sprite/a b.txt",
                 "mkdir" => "true",
                 "mode" => "0600"
               }

        assert body(conn) == "secret-free"
        Req.Test.json(conn, %{})
      end)

    assert :ok = Api.write_file(cfg, "demo-1", "/home/sprite/a b.txt", "secret-free", 0o600)
  end

  test "exec repeats cmd per argument and decodes the framed answer" do
    cfg =
      stub(:api_exec, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/v1/sprites/demo-1/exec"}
        assert conn.query_string == "cmd=bash&cmd=-c&cmd=echo+out%3B+exit+2"
        Plug.Conn.send_resp(conn, 200, <<2, "err\n", 1, "out\n", 3, 2>>)
      end)

    assert {:ok, %{status: 2, output: "err\nout\n"}} =
             Api.exec(cfg, "demo-1", ["bash", "-c", "echo out; exit 2"], [])
  end

  test "checkpoint reads the id from the complete event" do
    cfg =
      stub(:api_checkpoint, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/v1/sprites/demo-1/checkpoint"}
        assert Jason.decode!(body(conn)) == %{"comment" => "profiled: a+b"}

        Plug.Conn.send_resp(
          conn,
          200,
          ~s({"type":"info","data":"Creating checkpoint..."}\n{"type":"complete","data":"Checkpoint v8 created"}\n)
        )
      end)

    assert {:ok, "v8"} = Api.checkpoint(cfg, "demo-1", "profiled: a+b")
  end

  test "an error answer becomes a sentence without the token" do
    cfg =
      stub(:api_error, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end)

    assert {:error, message} = Api.destroy(cfg, "demo-1")
    assert message =~ "answered 404 to DELETE /v1/sprites/demo-1"
    refute message =~ @token
  end

  test "list_connectors keeps a custom connector's name, endpoint lists and base URL" do
    cfg =
      stub(:api_custom_list, fn conn ->
        Req.Test.json(conn, %{
          "connections" => [
            %{
              "id" => "conn_3",
              "provider" => "custom_api",
              "provider_account_name" => "acme.mcp",
              "provider_info" => %{"base_api_url" => "https://api.example.com"},
              "access_policy" => %{
                "sprite_labels" => ["profile:acme.mcp"],
                "allowed_endpoints" => ["/mcp/*"],
                "blocked_endpoints" => ["/mcp/admin*"]
              }
            }
          ]
        })
      end)

    assert {:ok,
            [
              %{
                name: "acme.mcp",
                allowed_endpoints: ["/mcp/*"],
                blocked_endpoints: ["/mcp/admin*"],
                base_url: "https://api.example.com"
              }
            ]} = Api.list_connectors(cfg)
  end

  test "create_custom_connector posts the body; test_custom_connector sends the id" do
    cfg =
      stub(:api_custom_create, fn conn ->
        case conn.request_path do
          "/v1/oauth/connections/custom_api" ->
            assert Jason.decode!(body(conn))["name"] == "acme.mcp"

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"connection" => %{"id" => "conn_4", "provider" => "custom_api"}})

          "/v1/oauth/connections/custom_api/test" ->
            assert Jason.decode!(body(conn)) == %{"connection_id" => "conn_4"}
            Req.Test.json(conn, %{"result" => %{"status" => "error", "message" => "HTTP 401"}})
        end
      end)

    assert {:ok, %{id: "conn_4"}} =
             Api.create_custom_connector(cfg, %{"name" => "acme.mcp", "access_token" => "x"})

    assert {:ok, %{status: "error", message: "HTTP 401"}} =
             Api.test_custom_connector(cfg, "conn_4")
  end
end
