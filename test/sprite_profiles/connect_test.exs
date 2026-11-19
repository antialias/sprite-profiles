defmodule SpriteProfiles.ConnectTest do
  # Building and posting a profile's custom API connector, through the stub adapter.
  use ExUnit.Case, async: true

  alias SpriteProfiles.{Connect, FakeSprites}

  @token "dummy-token-in-test"

  test "load finds the profile's custom connector; a profile without one is refused" do
    assert {:ok, profile, c} = Connect.load("github-mcp", dirs: [Path.expand("profiles")])
    assert profile.qualified == "github-mcp"
    assert c.base_url == "https://api.githubcopilot.com"

    assert {:error, [r]} = Connect.load("github", dirs: [Path.expand("profiles")])
    assert r.code == :no_custom_connector
    assert r.message =~ "catalogue connectors (github)"
  end

  test "the body names the connector by the qualified name and grants it to the label" do
    {:ok, p, c} = Connect.load("github-mcp", dirs: [Path.expand("profiles")])
    p = %{p | qualified: "acme.github-mcp", pick: "acme/profiles/github-mcp@v1"}

    assert Connect.body(p, c, @token) == %{
             "name" => "acme.github-mcp",
             "base_api_url" => "https://api.githubcopilot.com",
             "access_token" => @token,
             "auth_method" => "header",
             "auth_header_prefix" => "Bearer",
             "test_url" => "https://api.github.com/user",
             "description" => "sprite-profiles: acme/profiles/github-mcp@v1",
             "access_policy" => %{
               "sprite_labels" => ["profile:acme.github-mcp"],
               "allowed_endpoints" => ["/mcp/"]
             }
           }

    refute Enum.any?(Connect.summary(p, c), &(&1 =~ @token))
  end

  test "each auth method maps to Fly's field" do
    {:ok, p, c} = Connect.load("github-mcp", dirs: [Path.expand("profiles")])

    for {method, field} <- [
          {"custom_header", "auth_custom_header_name"},
          {"query_param", "auth_query_param_name"},
          {"url_path", "auth_url_path_template"}
        ] do
      body = Connect.body(p, %{c | auth: %{method: method, field: "f", value: "v"}}, @token)
      assert body["auth_method"] == method
      assert body[field] == "v"
    end
  end

  test "connect posts once, tests by connection_id, and returns the gateway URL" do
    {:ok, p, _c} = Connect.load("github-mcp", dirs: [Path.expand("profiles")])
    {sprites, log} = FakeSprites.start()

    assert {:ok, result} = Connect.connect(p, @token, sprites)
    assert result.gateway_url == "https://api.sprites.dev/v1/gateway/custom_api/conn_custom"
    assert result.test == %{status: "ok", message: "HTTP 200"}

    assert [{:create_custom_connector, [body]}, {:test_custom_connector, ["conn_custom"]}] =
             FakeSprites.calls(log)

    assert body["access_token"] == @token
    refute inspect(result) =~ @token
  end

  test "an empty token sends nothing" do
    {:ok, p, _c} = Connect.load("github-mcp", dirs: [Path.expand("profiles")])
    {sprites, log} = FakeSprites.start()
    assert {:error, _} = Connect.connect(p, "  ", sprites)
    assert FakeSprites.calls(log) == []
  end
end
