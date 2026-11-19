defmodule SpriteProfiles.Commands.Search do
  @moduledoc """
  `sprite-profiles search WORDS…`: find published profiles with GitHub's repository search
  for `topic:sprite-profile WORDS`, and print one line each:

      @acme/linear  1.1.0  ★12  Linear's MCP server · connector mcp.linear.app /mcp

  A repository `sprite-profile-NAME` gives the profile `@owner/NAME`; a collection,
  `sprite-profiles`, gives one profile for each folder holding a `profile.toml` (`NAME/`
  or `profiles/NAME/`), listed from its tree. For the first 10 profiles the newest
  version is found by name resolution (`SpriteProfiles.Names`, which reads `info/refs`)
  and `profile.toml` is read at that tag from `raw.githubusercontent.com`; a profile with
  no version yet is read at its default branch.

  The search works without a token (GitHub allows 10 searches a minute) and sends
  `GITHUB_TOKEN` when it is set; the token is never printed. A rate limit (403 or 429) is
  reported as such, with when to try again.

  Options: `:token` (instead of `GITHUB_TOKEN`), `:api_url`, `:limit` and the
  `SpriteProfiles.GitHub` options (`:req_options`, ...).
  """

  alias SpriteProfiles.{Commands.Show, GitHub, Names, Out, Pick, Profile}

  @api_url "https://api.github.com"
  @topic "sprite-profile"
  @limit 10

  @doc "Searches for `words`; returns the exit status (0, or 1 when the search failed)."
  @spec run([String.t()], keyword(), Out.t()) :: non_neg_integer()
  def run(words, opts, %Out{} = out) do
    opts = Keyword.put_new_lazy(opts, :token, fn -> System.get_env("GITHUB_TOKEN") end)
    query = Enum.join(["topic:#{@topic}" | words], " ")

    case search(query, opts) do
      {:ok, []} ->
        Out.info(out, nothing_found(words))
        0

      {:ok, repos} ->
        report(repos, words, opts, out)

      {:error, message} ->
        Out.error(out, message)
        1
    end
  end

  defp nothing_found([]),
    do:
      "No profiles are published yet: GitHub shows no repository with the topic #{@topic}. " <>
        "Publish one as a repository sprite-profile-NAME with a vX.Y.Z tag and that topic."

  defp nothing_found(words),
    do:
      "No published profile matches #{inspect(Enum.join(words, " "))}: GitHub shows no repository " <>
        "with the topic #{@topic} and those words. Try fewer words, or none to list them all."

  defp report(repos, words, opts, out) do
    {candidates, skipped} = candidates(repos, opts)
    limit = opts[:limit] || @limit
    {shown, rest} = Enum.split(candidates, limit)

    lines =
      shown
      |> Task.async_stream(&describe(&1, opts),
        max_concurrency: 5,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, line} -> line end)

    if lines == [], do: Out.info(out, nothing_found(words))
    Enum.each(columns(lines), &Out.info(out, &1))

    if rest != [],
      do: Out.info(out, "… and #{length(rest)} more; add words to narrow the search.")

    if skipped != [] do
      Out.info(
        out,
        "Tagged #{@topic} but not named sprite-profile-NAME or sprite-profiles, so not read: " <>
          Enum.join(skipped, ", ")
      )
    end

    if lines != [],
      do: Out.info(out, "See one in full with: sprite-profiles show #{hd(lines).name}")

    0
  end

  ## the search

  defp search(query, opts) do
    params = [q: query, sort: "stars", order: "desc", per_page: 30]

    case api_get("/search/repositories", params, opts) do
      {:ok, %{status: 200, body: %{"items" => items}}} ->
        {:ok, items}

      {:ok, %{status: status} = resp} when status in [403, 429] ->
        {:error, rate_limited(resp, opts)}

      {:ok, %{status: 422, body: body}} ->
        {:error, "GitHub refused the search: #{message(body)}"}

      {:ok, %{status: 401}} ->
        {:error,
         "GitHub refused GITHUB_TOKEN (401); unset it to search without a token, or renew it."}

      {:ok, %{status: status, body: body}} ->
        {:error, "GitHub's search answered #{status}: #{message(body)}; try again."}

      {:error, e} ->
        {:error, "GitHub's search could not be reached: #{error_text(e)}; check the network."}
    end
  end

  defp rate_limited(resp, opts) do
    wait =
      case {header(resp, "retry-after"), header(resp, "x-ratelimit-reset")} do
        {s, _} when is_binary(s) ->
          " Try again in #{s} s."

        {_, reset} when is_binary(reset) ->
          case Integer.parse(reset) do
            {at, _} -> " Try again in #{max(at - System.os_time(:second), 1)} s."
            :error -> ""
          end

        _ ->
          ""
      end

    allowance =
      if opts[:token] in [nil, ""],
        do:
          "GitHub's search is rate limited: it allows 10 searches a minute without a token, and they are used up.#{wait} Setting GITHUB_TOKEN raises the limit.",
        else:
          "GitHub's search is rate limited: the searches allowed for GITHUB_TOKEN are used up.#{wait}"

    allowance
  end

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [v | _] -> v
      [] -> nil
    end
  end

  defp message(%{"message" => m}) when is_binary(m), do: m
  defp message(body) when is_binary(body) and body != "", do: String.slice(body, 0, 200)
  defp message(_), do: "no reason given"

  defp error_text(e) when is_exception(e), do: Exception.message(e)
  defp error_text(e), do: inspect(e)

  ## the profiles in each repository

  # {[%{name:, owner:, repo:, path:, stars:, default_branch:}], skipped}
  defp candidates(repos, opts) do
    {found, skipped} =
      Enum.reduce(repos, {[], []}, fn item, {found, skipped} ->
        owner = get_in(item, ["owner", "login"])
        repo = item["name"]

        base = %{
          owner: owner,
          repo: repo,
          stars: item["stargazers_count"] || 0,
          default_branch: item["default_branch"] || "main"
        }

        case repo do
          "sprite-profile-" <> name ->
            if Profile.valid_name?(name),
              do: {[[Map.merge(base, %{name: name, path: ""})] | found], skipped},
              else: {found, ["#{owner}/#{repo}" | skipped]}

          "sprite-profiles" ->
            folders = collection_folders(base, opts)
            {[Enum.map(folders, &Map.merge(base, &1)) | found], skipped}

          _ ->
            {found, ["#{owner}/#{repo}" | skipped]}
        end
      end)

    # An own repository wins over a collection's folder of the same name, as in resolution.
    profiles =
      found
      |> Enum.reverse()
      |> List.flatten()
      |> Enum.uniq_by(&{String.downcase(&1.owner), &1.name})

    {profiles, Enum.reverse(skipped)}
  end

  # The folders of a collection that hold a profile.toml, from its tree at the default
  # branch; when the tree cannot be read, those with version tags (`NAME/vX.Y.Z`).
  defp collection_folders(c, opts) do
    path = "/repos/#{c.owner}/#{c.repo}/git/trees/#{URI.encode(c.default_branch)}"

    case api_get(path, [recursive: 1], opts) do
      {:ok, %{status: 200, body: %{"tree" => tree}}} ->
        tree
        |> Enum.flat_map(fn %{"path" => p} ->
          case String.split(p, "/") do
            [name, "profile.toml"] -> [%{name: name, path: name}]
            ["profiles", name, "profile.toml"] -> [%{name: name, path: "profiles/#{name}"}]
            _ -> []
          end
        end)
        |> Enum.filter(&Profile.valid_name?(&1.name))
        |> Enum.sort_by(& &1.name)

      _ ->
        case GitHub.refs(c.owner, c.repo, opts) do
          {:ok, refs} ->
            for {"refs/tags/" <> tag, _} <- refs,
                [name, "v" <> _] <- [String.split(tag, "/")],
                Profile.valid_name?(name),
                uniq: true,
                do: %{name: name, path: name}

          _ ->
            []
        end
    end
  end

  # One line's parts: %{name:, version:, stars:, text:}.
  defp describe(c, opts) do
    pick = "@#{c.owner}/#{c.name}"
    {:ok, parsed} = Pick.parse(pick)

    {where, version} =
      case Names.resolve(parsed, pick, opts) do
        {:ok, r} ->
          {{r.address.owner, r.address.repo, r.address.path, r.sha}, r.version || r.address.ref}

        {:error, %{code: :no_versions}} ->
          case GitHub.refs(c.owner, c.repo, opts) do
            {:ok, %{"HEAD" => sha}} ->
              {{c.owner, c.repo, c.path, sha}, "#{c.default_branch} (untagged)"}

            _ ->
              {nil, "?"}
          end

        {:error, r} ->
          {{:error, r.message}, "?"}
      end

    text =
      case where do
        {owner, repo, path, sha} -> summary_line(owner, repo, path, sha, pick, opts)
        {:error, message} -> "(cannot be resolved: #{message})"
        nil -> "(cannot be read)"
      end

    %{name: pick, version: version, stars: c.stars, text: text}
  end

  defp summary_line(owner, repo, path, sha, pick, opts) do
    file = fn name -> if path in [nil, ""], do: name, else: "#{path}/#{name}" end

    with {:ok, text} <- GitHub.read_file(owner, repo, sha, file.("profile.toml"), opts),
         {:ok, map} <- TomlElixir.decode(text, spec: :"1.0.0") do
      setup =
        case GitHub.read_file(owner, repo, sha, file.("setup.sh"), opts) do
          {:ok, _} -> "setup.sh"
          _ -> nil
        end

      case Profile.parse(map, display: pick, setup: setup) do
        {:ok, p} -> "#{p.summary} · #{Show.touches(p)}"
        {:error, [e | _]} -> "(profile.toml is invalid: #{e.message})"
      end
    else
      :missing -> "(no profile.toml at #{String.slice(sha, 0, 8)})"
      {:error, %SpriteProfiles.Refusal{message: m}} -> "(cannot be read: #{m})"
      {:error, e} -> "(profile.toml is not valid TOML: #{error_text(e)})"
    end
  end

  defp columns(lines) do
    width = fn key ->
      lines |> Enum.map(&String.length(to_string(Map.get(&1, key)))) |> Enum.max(fn -> 0 end)
    end

    {wn, wv} = {width.(:name), width.(:version)}
    ws = lines |> Enum.map(&String.length("★#{&1.stars}")) |> Enum.max(fn -> 0 end)

    Enum.map(lines, fn l ->
      String.pad_trailing(l.name, wn) <>
        "  " <>
        String.pad_trailing(l.version, wv) <>
        "  " <> String.pad_trailing("★#{l.stars}", ws) <> "  " <> l.text
    end)
  end

  ## the API

  defp api_get(path, params, opts) do
    app = Application.get_env(:sprite_profiles, GitHub, [])[:req_options] || []

    headers =
      [accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28"] ++
        if opts[:token] in [nil, ""], do: [], else: [authorization: "Bearer #{opts[:token]}"]

    [
      url: (opts[:api_url] || @api_url) <> path,
      params: params,
      headers: headers,
      retry: false,
      receive_timeout: 30_000
    ]
    |> Keyword.merge(app)
    |> Keyword.merge(opts[:req_options] || [])
    |> Req.new()
    |> Req.request()
  end
end
