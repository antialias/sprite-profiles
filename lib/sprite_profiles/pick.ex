defmodule SpriteProfiles.Pick do
  @moduledoc """
  What a pick is, told apart by its first characters:

    * a **name**, `@[HOST/]NS/NAME[@V]`, starts with `@`: a published profile found by
      convention (`SpriteProfiles.Names`);
    * an **address**, `owner/repo[/path]@ref`, holds a `/` or an `@`
      (`SpriteProfiles.Address`);
    * anything else is **local**, a profile name on the search path.

  In a name, `HOST` is `host` or `host:port` and is told by a `.` or `:` in the first
  segment; `github.com`, or no host, is GitHub. On GitHub `NS` is one segment in the owner
  alphabet; on another host it is one or more segments of `[A-Za-z0-9._-]`. `NAME` uses
  the profile name alphabet. `V` is a version prefix (`1`, `1.2`, `1.2.3`) or, written any
  other way, a ref (a branch, a tag or a 40-hex commit, which is a ref even when all its
  digits are decimal). The namespace and host are kept lowercase.
  """

  alias SpriteProfiles.Profile

  @enforce_keys [:host, :ns, :name, :version]
  defstruct [:host, :ns, :name, :version]

  @typedoc "`nil` is the newest version; `{:prefix, [major | ...]}`; `{:ref, ref}`."
  @type version :: nil | {:prefix, [non_neg_integer()]} | {:ref, String.t()}

  @type t :: %__MODULE__{
          host: String.t(),
          ns: [String.t()],
          name: String.t(),
          version: version()
        }

  @github "github.com"
  @owner_re ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/
  @segment_re ~r/^[A-Za-z0-9._-]+$/
  @host_re ~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]{1,5})?$/
  @prefix_re ~r/^\d+(?:\.\d+){0,2}$/
  @ref_re ~r/^[A-Za-z0-9._\/-]+$/
  @sha_re ~r/^[0-9a-fA-F]{40}$/

  @doc "The host GitHub names are on."
  def github, do: @github

  @doc """
  The kind of pick: `:name` when it starts with `@`; otherwise `:address` when it holds a
  `/` or an `@`; otherwise `:local`.
  """
  @spec kind(String.t()) :: :local | :name | :address
  def kind("@" <> _), do: :name

  def kind(pick) when is_binary(pick),
    do: if(String.contains?(pick, ["/", "@"]), do: :address, else: :local)

  @doc """
  Parses a name pick. Returns `{:ok, pick}` or `{:error, :bad_name}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :bad_name}
  def parse("@" <> rest) do
    {where, version} =
      case String.split(rest, "@", parts: 2) do
        [where, v] -> {where, v}
        [where] -> {where, nil}
      end

    with {:ok, host, ns, name} <- parse_where(String.split(where, "/")),
         {:ok, version} <- parse_version(version) do
      {:ok, %__MODULE__{host: host, ns: ns, name: name, version: version}}
    end
  end

  def parse(_), do: {:error, :bad_name}

  defp parse_where([first | rest] = segments) do
    if String.contains?(first, [".", ":"]),
      do: parse_host(String.downcase(first), rest),
      else: parse_ns(@github, segments)
  end

  defp parse_host(host, rest) do
    cond do
      not Regex.match?(@host_re, host) -> {:error, :bad_name}
      host == @github -> parse_ns(@github, rest)
      true -> parse_ns(host, rest)
    end
  end

  defp parse_ns(@github, [owner, name]) do
    if Regex.match?(@owner_re, owner) and Profile.valid_name?(name),
      do: {:ok, @github, [String.downcase(owner)], name},
      else: {:error, :bad_name}
  end

  defp parse_ns(@github, _), do: {:error, :bad_name}

  defp parse_ns(host, [_ | _] = segments) when length(segments) >= 2 do
    {ns, [name]} = Enum.split(segments, -1)

    if Enum.all?(ns, &good_segment?/1) and Profile.valid_name?(name),
      do: {:ok, host, Enum.map(ns, &String.downcase/1), name},
      else: {:error, :bad_name}
  end

  defp parse_ns(_host, _), do: {:error, :bad_name}

  defp good_segment?(s), do: s not in [".", ".."] and Regex.match?(@segment_re, s)

  defp parse_version(nil), do: {:ok, nil}

  defp parse_version(v) do
    cond do
      # A commit is a ref even when its 40 hex digits are all decimal.
      Regex.match?(@sha_re, v) ->
        {:ok, {:ref, v}}

      Regex.match?(@prefix_re, v) ->
        {:ok, {:prefix, v |> String.split(".") |> Enum.map(&String.to_integer/1)}}

      Regex.match?(@ref_re, v) and Enum.all?(String.split(v, "/"), &(&1 not in ["", ".", ".."])) ->
        {:ok, {:ref, v}}

      true ->
        {:error, :bad_name}
    end
  end

  @doc "The namespace as written in a pick: its segments joined by `/`."
  def ns(%__MODULE__{ns: ns}), do: Enum.join(ns, "/")

  @doc """
  What makes two name picks the same profile, ignoring the version:
  `@HOST/NS/NAME`, lowercased. It never equals an address's identity.
  """
  def identity(%__MODULE__{} = p), do: "@#{p.host}/#{ns(p)}/#{p.name}"

  @doc "The pick without its version, as a person writes it: `@NS/NAME` on GitHub."
  def base(%__MODULE__{host: @github} = p), do: "@#{ns(p)}/#{p.name}"
  def base(%__MODULE__{} = p), do: "@#{p.host}/#{ns(p)}/#{p.name}"

  @doc "True when `version` (`\"1.2.3\"`) matches the pick's prefix."
  def matches?(%__MODULE__{version: {:prefix, prefix}}, version) when is_binary(version) do
    case semver(version) do
      {:ok, parts} -> Enum.take(parts, length(prefix)) == prefix
      :error -> false
    end
  end

  def matches?(_, _), do: false

  @doc "Parses `MAJOR.MINOR.PATCH` (no pre-release) into a list of three integers."
  def semver(v) when is_binary(v) do
    case Regex.run(~r/^(\d+)\.(\d+)\.(\d+)$/, v) do
      [_ | parts] -> {:ok, Enum.map(parts, &String.to_integer/1)}
      _ -> :error
    end
  end

  def semver(_), do: :error
end
