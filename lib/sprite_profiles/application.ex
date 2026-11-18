defmodule SpriteProfiles.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SpriteProfilesWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:sprite_profiles, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SpriteProfiles.PubSub},
      # Start a worker by calling: SpriteProfiles.Worker.start_link(arg)
      # {SpriteProfiles.Worker, arg},
      # Start to serve requests, typically the last entry
      SpriteProfilesWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SpriteProfiles.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SpriteProfilesWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
