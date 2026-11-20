defmodule SpriteProfiles.Commands.Exec do
  @moduledoc """
  `sprite-profiles exec NAME [--] CMD [ARG ...]`: runs a command in a launched Sprite as a
  login shell would (`bash -lc`), so the profiles' env file, sourced from `~/.bashrc`, and
  their shell hooks apply. Each argument is shell-quoted, so it reaches the command as it
  is. The output (stdout and stderr together, as the Sprites adapter gives it) is printed
  as it comes, a line at a time, without the image's harmless warnings, and only them:

      /home/sprite/.bashrc: line 22: bind: warning: line editing not enabled

  Returns the command's exit status. Standard input is not passed on.

  Options: `:adapter` (`"cli"` or `"api"`), and for tests `:sprites` (a handle).
  """

  alias SpriteProfiles.{Launcher, Out, Sprites}
  alias SpriteProfiles.Commands.Launch

  # `bind` in the image's ~/.bashrc, run by a login shell that has no terminal.
  @harmless ~r/^\S*\.bashrc: line \d+: bind: warning: line editing not enabled\r?$/

  @doc "Runs `cmd` in the Sprite `name`; returns its exit status (1 when it could not run)."
  @spec run(String.t(), [String.t()], keyword(), Out.t()) :: non_neg_integer()
  def run(name, cmd, opts, %Out{} = out) do
    case Launch.sprites(opts, out) do
      {:ok, sprites} -> exec(sprites, name, cmd, out)
      {:exit, status} -> status
    end
  end

  @doc "The `bash -lc` script for `cmd`: each argument single-quoted."
  @spec script([String.t()]) :: String.t()
  def script(cmd), do: Enum.map_join(cmd, " ", &Launcher.sh_quote/1)

  @doc "True for a line of the image's harmless `bind` warning, which `exec` drops."
  def harmless?(line), do: Regex.match?(@harmless, line)

  defp exec(sprites, name, cmd, out) do
    {:ok, buffer} = Agent.start_link(fn -> "" end)

    feed = fn chunk ->
      buffer
      |> Agent.get_and_update(fn pending ->
        {lines, [rest]} = (pending <> chunk) |> String.split("\n") |> Enum.split(-1)
        {lines, rest}
      end)
      |> Enum.each(&print(out, &1 <> "\n"))
    end

    result =
      try do
        Sprites.exec(sprites, name, ["bash", "-lc", script(cmd)],
          on_output: feed,
          timeout: :infinity
        )
      after
        case Agent.get(buffer, & &1) do
          "" -> :ok
          rest -> print(out, rest)
        end

        Agent.stop(buffer)
      end

    case result do
      {:ok, %{status: status}} ->
        status

      {:error, message} ->
        Out.error(out, "Could not run the command in #{name}: #{message}")
        1
    end
  end

  defp print(out, text) do
    unless harmless?(String.trim_trailing(text, "\n")), do: Out.write(out, text)
  end
end
