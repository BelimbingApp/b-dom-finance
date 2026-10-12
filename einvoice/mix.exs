[discovery_file] =
  Path.wildcard(Path.expand("../../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.Finance.Einvoice.MixProject do
  use Mix.Project

  def project do
    Bilimbi.Base.ModuleRegistry.MixDiscovery.module_project(__DIR__,
      app: :bilimbi_finance_einvoice,
      deps: deps(),
      aliases: aliases()
    )
  end

  def application do
    Bilimbi.Base.ModuleRegistry.MixDiscovery.module_application(__DIR__,
      mod: {Bilimbi.Finance.Einvoice.Application, []},
      extra_applications: [:logger, :crypto, :public_key]
    )
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:decimal, "~> 3.1"},
      {:eqrcode, "~> 0.2.1"},
      {:jason, "~> 1.4"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:postgrex, "~> 0.22"},
      {:req, "~> 0.7"},
      {:plug, "~> 1.20"}
    ]
  end

  defp aliases do
    # Core Company's closure boots Base Queue, which needs its tables first.
    [
      test: [
        "ecto.create --quiet -r Bilimbi.Base.Repo",
        "run --no-start -e Bilimbi.Base.Queue.TestFixtures.ensure_runtime_tables!()",
        "test"
      ]
    ]
  end
end
