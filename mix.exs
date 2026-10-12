# This repository mounts at apps/domains/finance inside a Bilimbi checkout; the
# Platform root is three levels up. See AGENTS.md for the mount instructions.
Code.require_file(Path.expand("../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.Finance.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../..", __DIR__)

  def project do
    [
      app: :finance,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp deps, do: Bilimbi.Base.ModuleRegistry.MixDiscovery.container_dependencies(__DIR__)

  defp aliases do
    [
      setup: ["deps.get"],
      test: Bilimbi.Base.ModuleRegistry.MixDiscovery.container_test_commands(__DIR__),
      "compile.strict":
        Bilimbi.Base.ModuleRegistry.MixDiscovery.container_compile_commands(__DIR__)
    ]
  end
end
