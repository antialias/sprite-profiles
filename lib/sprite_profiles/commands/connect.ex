defmodule SpriteProfiles.Commands.Connect do
  @moduledoc """
  The connect command, shared by `sprite-profiles connect` and `mix profiles.connect`:
  print the custom API connector a profile declares, read a token typed at the terminal
  with echo off, and create or update the connector in the person's org
  (`SpriteProfiles.Connect`). Returns the exit status: 0, 1 (refused, no token, or Fly
  refused the connector or its test) or 2 (bad usage).

  Standard input must be a terminal (whatever stdout is, so `connect … | tee` still
  works); the prompt goes to stderr. The token lives in `read_token/0`'s return value and
  the caller's variable, and nowhere else: it is never printed, logged or written.

  Options: `:dirs` (the search path) and `:adapter` (`"cli"` or `"api"`). `deps` replaces
  the terminal in tests: `:terminal?` (a fun), `:read_token` (a fun) and `:sprites` (a
  handle).
  """

  alias SpriteProfiles.{Connect, Out, Sprites}

  @doc "Connects the profile `pick`; returns the exit status."
  @spec run(String.t(), keyword(), Out.t(), keyword()) :: non_neg_integer()
  def run(pick, opts, %Out{} = out, deps \\ []) do
    case Connect.load(pick, dirs: Keyword.fetch!(opts, :dirs), base: opts[:base]) do
      {:ok, profile, connector} ->
        Out.info(out, Enum.join(Connect.summary(profile, connector), "\n"))
        terminal? = Keyword.get(deps, :terminal?, &terminal?/0)

        if terminal?.() do
          with_sprites(opts, out, deps, fn sprites ->
            case Keyword.get(deps, :read_token, &read_token/0).() do
              {:error, message} ->
                Out.error(out, message)
                1

              "" ->
                Out.error(out, "No token given; nothing was sent.")
                1

              token ->
                report(out, Connect.connect(profile, token, sprites))
            end
          end)
        else
          Out.error(
            out,
            "Refused:\n  [needs_terminal] standard input is not a terminal; the token is typed by a person, with echo off, and never piped or passed in, so run this in a terminal."
          )

          1
        end

      {:error, problems} ->
        Out.refused(out, problems)
    end
  end

  defp with_sprites(opts, out, deps, fun) do
    case Keyword.fetch(deps, :sprites) do
      {:ok, sprites} ->
        fun.(sprites)

      :error ->
        case opts[:adapter] || "cli" do
          "cli" ->
            fun.(Sprites.new(Sprites.Cli, []))

          "api" ->
            case Sprites.Api.from_env() do
              {:ok, cfg, _var} ->
                fun.(Sprites.new(Sprites.Api, cfg))

              {:error, message} ->
                Out.error(out, message)
                2
            end

          other ->
            Out.usage(out, "not understood: --adapter #{other}")
        end
    end
  end

  defp report(out, {:ok, %{connector: c, gateway_url: url, test: test}}) do
    Out.info(out, """
    Connector #{c.name || "(unnamed)"} is in your org.
      id:          #{c.id}
      gateway URL: #{url}\
    """)

    case test do
      nil ->
        0

      %{status: "ok", message: m} ->
        Out.info(out, "  test:        ok (#{m})")
        0

      %{status: s, message: m} ->
        Out.error(out, "  test:        #{s} (#{m}); check the token and its permissions.")
        1
    end
  end

  defp report(out, {:error, message}) do
    Out.error(out, "Not connected: #{message}")
    1
  end

  @doc "True when standard input is a terminal (stdout may be anything)."
  def terminal?, do: Keyword.get(:io.getopts(:standard_io), :stdin, false) == true

  # Echo off at the terminal itself: `stty -echo` on the terminal device of standard input,
  # then one line read through Erlang's standard input, then `stty echo` again. This works
  # whatever stdout is: under the binary, Burrito pipes stdout, and Erlang's own raw mode
  # (io:get_password/0) is then unavailable. A child process has no controlling terminal
  # (the VM starts ports in a new session), so the device is found by name with `ps`.
  # The prompt goes to stderr. The token lives in this function's return value and the
  # caller's variable, and nowhere else.
  defp read_token do
    with {:ok, dev} <- tty_device(),
         :ok <- stty(dev, "-echo") do
      IO.write(:stderr, "Token (input hidden): ")

      try do
        IO.gets(:stdio, "")
      after
        stty(dev, "echo")
        IO.write(:stderr, "\n")
      end
      |> case do
        line when is_binary(line) -> clean(line)
        _ -> {:error, "No line was read; nothing was sent."}
      end
    else
      _ -> {:error, "This terminal cannot read a token with echo off; nothing was sent."}
    end
  end

  defp tty_device do
    with ps when is_binary(ps) <- System.find_executable("ps"),
         {name, 0} <- System.cmd(ps, ["-o", "tty=", "-p", System.pid()]),
         name when name not in ["", "?", "??"] <- String.trim(name),
         dev = if(String.starts_with?(name, "/dev/"), do: name, else: "/dev/" <> name),
         true <- File.exists?(dev) do
      {:ok, dev}
    else
      _ -> :error
    end
  end

  defp stty(dev, mode) do
    with sh when is_binary(sh) <- System.find_executable("sh"),
         {_, 0} <- System.cmd(sh, ["-c", ~S(stty "$1" < "$2"), "sh", mode, dev]) do
      :ok
    else
      _ -> :error
    end
  end

  defp clean(v), do: String.trim(v)
end
