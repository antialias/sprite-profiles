defmodule SpriteProfiles.ProfileFormat2Test do
  # Format 2: inputs, custom API connectors and MCP auth = "connector".
  use ExUnit.Case, async: true

  import SpriteProfiles.ProfileHelpers

  @custom """
  [[connectors]]
  provider  = "custom_api"
  base_url  = "https://api.example.com"
  endpoints = ["/v1/*"]
  """

  defp f2(toml), do: "format = 2\n" <> toml

  defp input_profile(spec, env \\ ~s(X = { from = "input", name = "mode" })) do
    f2("[inputs.mode]\n#{spec}\n[env]\n#{env}\n")
  end

  defp errors(name \\ "aa", toml) do
    {:error, errors} = parse(name, toml)
    errors
  end

  describe "inputs" do
    test "a valid input is read, with its default and pattern" do
      p =
        profile!(
          "aa",
          input_profile(~s<summary = "the mode"\ndefault = "fast"\npattern = '^(fast|slow)$'>)
        )

      assert p.format == 2

      assert p.inputs == %{
               "mode" => %{
                 name: "mode",
                 summary: "the mode",
                 default: "fast",
                 pattern: "^(fast|slow)$"
               }
             }

      assert p.env == %{"X" => {:input, "mode"}}
    end

    test "no default means required" do
      p = profile!("aa", input_profile(~s(summary = "the mode")))
      assert p.inputs["mode"].default == nil
    end

    test "shapes that are wrong are bad_field" do
      for {why, toml} <- [
            {"bad name",
             f2(~s([inputs.Mode]\nsummary = "s"\n[env]\nX = { from = "input", name = "Mode" }\n))},
            {"missing summary", input_profile(~s(default = "a"))},
            {"two-line summary", input_profile(~s(summary = "a\\nb"))},
            {"non-string default", input_profile(~s(summary = "s"\ndefault = 8080))},
            {"pattern that does not compile", input_profile(~s<summary = "s"\npattern = '(a'>)},
            {"default failing its pattern",
             input_profile(~s<summary = "s"\ndefault = "x"\npattern = '^(a|b)$'>)},
            {"default too long",
             input_profile(~s(summary = "s"\ndefault = "#{String.duplicate("a", 257)}"))},
            {"unknown field", input_profile(~s(summary = "s"\nsecret = true))}
          ] do
        codes = codes(errors(toml))
        assert codes != [], why

        assert Enum.all?(codes, &(&1 in [:bad_field, :unknown_field])),
               "#{why}: #{inspect(codes)}"
      end
    end

    test "a pattern matches the whole value" do
      toml = input_profile(~s(summary = "s"\ndefault = "xab"\npattern = 'ab'))
      assert [:bad_field] = codes(errors(toml))
    end

    test "an input no env uses is input_unused" do
      assert [:input_unused] =
               codes(errors(f2(~s([inputs.mode]\nsummary = "s"\ndefault = "a"\n))))
    end

    test "env from an undeclared input is env_input_undeclared" do
      assert [:env_input_undeclared] =
               codes(errors(f2(~s([env]\nX = { from = "input", name = "nope" }\n))))
    end
  end

  describe "needs_format" do
    test "[inputs] with format = 1, or with no format, is needs_format" do
      toml =
        ~s([inputs.mode]\nsummary = "s"\ndefault = "a"\n[env]\nX = { from = "input", name = "mode" }\n)

      for text <- ["format = 1\n" <> toml, toml] do
        codes = codes(errors(text))
        assert :needs_format in codes
        refute :unknown_field in codes
      end

      [e | _] = errors(toml)
      assert e.message =~ "uses [inputs], which is format 2, but is format 1; set format = 2."
    end

    test "a custom_api connector or an auth = \"connector\" MCP server with format = 1" do
      assert :needs_format in codes(errors(@custom))

      mcp = """
      [[connectors]]
      provider = "github"
      [env]
      G = { from = "connector", provider = "github" }
      [claude.mcp_servers.gh]
      url  = "${G}/mcp"
      auth = "connector"
      """

      assert [:needs_format] = codes(errors(mcp))
      assert {:ok, _} = parse("aa", f2(mcp))
    end

    test "format = 3 is still one unsupported_format" do
      assert [:unsupported_format] = codes(errors("format = 3\n" <> @custom))
    end
  end

  describe "custom API connectors" do
    test "a full declaration is read, auth defaulting to a Bearer header" do
      p = profile!("aa", f2(@custom <> ~s(test_url = "https://api.example.com/me"\n)))

      assert p.connectors == [
               %{
                 provider: "custom_api",
                 base_url: "https://api.example.com",
                 auth: %{method: "header", field: "prefix", value: "Bearer"},
                 endpoints: ["/v1/*"],
                 test_url: "https://api.example.com/me"
               }
             ]
    end

    test "each auth method, with its companion's default filled in" do
      for {auth, want} <- [
            {~s({ method = "header" }), {"header", "prefix", "Bearer"}},
            {~s({ method = "header", prefix = "" }), {"header", "prefix", ""}},
            {~s({ method = "custom_header" }), {"custom_header", "header", "X-Api-Key"}},
            {~s({ method = "query_param" }), {"query_param", "param", "api_key"}},
            {~s({ method = "url_path", template = "/bot{token}" }),
             {"url_path", "template", "/bot{token}"}}
          ] do
        [c] = profile!("aa", f2(@custom <> "auth = #{auth}\n")).connectors
        {method, field, value} = want
        assert c.auth == %{method: method, field: field, value: value}, auth
      end
    end

    test "bad shapes are bad_field" do
      for {why, toml} <- [
            {"no base_url", ~s([[connectors]]\nprovider = "custom_api"\nendpoints = ["/a"]\n)},
            {"http base_url", String.replace(@custom, "https://", "http://")},
            {"base_url with a query", String.replace(@custom, ".com\"", ".com?a=1\"")},
            {"endpoint without /", String.replace(@custom, "/v1/*", "v1/*")},
            {"wildcard inside", String.replace(@custom, "/v1/*", "/v*/x")},
            {"no endpoints",
             String.replace(@custom, ~s(endpoints = ["/v1/*"]), "endpoints = []")},
            {"unknown method", @custom <> ~s(auth = { method = "basic" }\n)},
            {"url_path without {token}",
             @custom <> ~s(auth = { method = "url_path", template = "/x" }\n)},
            {"url_path without template", @custom <> ~s(auth = { method = "url_path" }\n)},
            {"bad header name",
             @custom <> ~s(auth = { method = "custom_header", header = "a b" }\n)},
            {"field of another method",
             @custom <> ~s(auth = { method = "header", param = "x" }\n)},
            {"auth not a table", @custom <> ~s(auth = "header"\n)},
            {"relative test_url", @custom <> ~s(test_url = "/me"\n)}
          ] do
        codes = codes(errors(f2(toml)))
        assert codes != [], why

        assert Enum.all?(codes, &(&1 in [:bad_field, :unknown_field])),
               "#{why}: #{inspect(codes)}"
      end
    end

    test "url_path takes a relative test_url" do
      toml =
        @custom <>
          ~s(auth = { method = "url_path", template = "/bot{token}" }\ntest_url = "/getMe"\n)

      assert {:ok, _} = parse("aa", f2(toml))
    end

    test "two custom_api connectors are duplicate_connector" do
      assert [:duplicate_connector] = codes(errors(f2(@custom <> @custom)))
    end

    test "a catalogue provider still takes only provider, and env from custom_api works" do
      p =
        profile!(
          "aa",
          f2(@custom <> ~s([env]\nU = { from = "connector", provider = "custom_api" }\n))
        )

      assert p.env == %{"U" => {:connector, "custom_api"}}

      assert [:unknown_field] =
               codes(errors(~s([[connectors]]\nprovider = "github"\nbase_url = "https://x.io"\n)))
    end
  end

  describe "MCP auth = \"connector\"" do
    @env ~s([env]\nU = { from = "connector", provider = "custom_api" }\nT = "text"\n)

    test "is read when the url starts with a connector env" do
      p =
        profile!(
          "aa",
          f2(
            @custom <> @env <> ~s([claude.mcp_servers.x]\nurl = "${U}/mcp/"\nauth = "connector"\n)
          )
        )

      assert [%{auth_connector: true, auth_none: false}] = p.mcp_servers
    end

    test "is bad_field when the url does not start with a connector env" do
      for url <- ["https://x.io/${U}", "${T}/mcp", "${NOPE}/mcp"] do
        toml =
          f2(@custom <> @env <> ~s([claude.mcp_servers.x]\nurl = "#{url}"\nauth = "connector"\n))

        assert [:bad_field] = codes(errors(toml)), url
      end
    end
  end
end
