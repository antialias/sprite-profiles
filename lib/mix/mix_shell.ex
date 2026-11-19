defmodule SpriteProfiles.MixShell do
  @moduledoc """
  The `SpriteProfiles.Out` of the Mix tasks: lines through `Mix.shell()`, and bad usage as
  the task's usage line followed by the message. Only the Mix tasks call it; the binary has
  no Mix.
  """

  alias SpriteProfiles.Out

  @doc "An `Out` writing through `Mix.shell()`, with `usage` as the task's usage line."
  def out(usage) do
    %Out{
      info: fn line -> Mix.shell().info(line) end,
      error: fn line -> Mix.shell().error(line) end,
      usage: fn message ->
        Mix.shell().error(usage <> if(message == "", do: "", else: "\n" <> message))
      end
    }
  end

  @doc "Ends the task with `status`: returns for 0, exits `{:shutdown, status}` otherwise."
  def finish(0), do: :ok
  def finish(status), do: exit({:shutdown, status})
end
