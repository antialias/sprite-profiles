defmodule SpriteProfiles.MixProject do
  use Mix.Project

  def project do
    [
      app: :sprite_profiles,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {SpriteProfiles.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # The `sprite-profiles` command as one executable: a release with ERTS, wrapped by Burrito.
  # It runs config/cli.exs instead of config/runtime.exs, so only the CLI starts, and carries
  # the example profiles in priv/profiles. Build one target with
  #
  #     MIX_ENV=prod BURRITO_TARGET=macos_arm64 mix release
  #
  # which writes burrito_out/sprite_profiles_macos_arm64. Burrito needs zig and xz on PATH,
  # and downloads a prebuilt ERTS of the host's OTP version; when there is none for that
  # version, SPRITE_PROFILES_ERTS names one (a URL, a .tar.gz or a folder) for the target.
  def releases do
    [
      sprite_profiles: [
        runtime_config_path: "config/cli.exs",
        include_executables_for: [:unix],
        steps: [:assemble, &bundle_profiles/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: burrito_target(os: :darwin, cpu: :aarch64),
            linux_x86_64: burrito_target(os: :linux, cpu: :x86_64),
            linux_arm64: burrito_target(os: :linux, cpu: :aarch64)
          ]
        ]
      ]
    ]
  end

  defp burrito_target(target) do
    case System.get_env("SPRITE_PROFILES_ERTS") do
      erts when erts in [nil, ""] -> target
      erts -> Keyword.put(target, :custom_erts, erts)
    end
  end

  # Copies (not moves) the repository's profiles into the assembled release.
  defp bundle_profiles(release) do
    dest = Path.join([release.path, "lib", "sprite_profiles-#{release.version}", "priv"])
    File.rm_rf!(Path.join(dest, "profiles"))
    File.mkdir_p!(dest)
    File.cp_r!(Path.join(__DIR__, "profiles"), Path.join(dest, "profiles"))
    release
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:toml_elixir, "~> 3.3"},
      {:req, "~> 0.5"},
      {:burrito, "~> 1.6"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind sprite_profiles", "esbuild sprite_profiles"],
      "assets.deploy": [
        "tailwind sprite_profiles --minify",
        "esbuild sprite_profiles --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
