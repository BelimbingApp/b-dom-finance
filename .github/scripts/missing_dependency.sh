#!/usr/bin/env bash
# Proves a missing Finance dependency fails composition.
#
# Run from a Bilimbi root with Finance mounted at apps/domains/finance and the
# workspace already compiled. The script mounts a throwaway Extension whose one
# module depends on finance/ledger, moves Finance out of apps/, and requires
# discovery to refuse the graph with the missing-dependency error. It then
# remounts Finance and requires the same graph to compile. The fixture is
# written here and removed on exit; it is never a real Extension.
set -euo pipefail

root=$(pwd -P)
finance="$root/apps/domains/finance"
parked="$root/.scratchpad/finance-parked"
fixture="$root/apps/extensions/finance_probe"
expected="module finance_probe/probe declares missing dependency finance/ledger"

[ -f "$root/apps/domains/AGENTS.md" ] || { echo "run from a Bilimbi root" >&2; exit 2; }
[ -d "$finance" ] || { echo "Finance is not mounted at $finance" >&2; exit 2; }
[ ! -e "$fixture" ] || { echo "$fixture already exists" >&2; exit 2; }
[ ! -e "$parked" ] || { echo "$parked already exists" >&2; exit 2; }

build="$root/_build/${MIX_ENV:-dev}/lib"

restore() {
  if [ -d "$parked" ] && [ ! -e "$finance" ]; then mv "$parked" "$finance"; fi
  rm -rf "$fixture" "$build/finance_probe" "$build/bilimbi_finance_probe_probe"
}
trap restore EXIT

mkdir -p "$fixture/probe/lib"

cat > "$fixture/bilimbi.container.exs" <<'EOF'
[id: "finance_probe", kind: :container, layer: :extension]
EOF

cat > "$fixture/mix.exs" <<'EOF'
Code.require_file(Path.expand("../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.FinanceProbe.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../..", __DIR__)

  def project do
    [
      app: :finance_probe,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      deps: Bilimbi.Base.ModuleRegistry.MixDiscovery.container_dependencies(__DIR__)
    ]
  end
end
EOF

cat > "$fixture/probe/bilimbi.module.exs" <<'EOF'
[
  id: "finance_probe/probe",
  kind: :module,
  layer: :extension,
  required: false,
  otp_app: :bilimbi_finance_probe_probe,
  namespace: Bilimbi.FinanceProbe.Probe,
  dependencies: ["finance/ledger"],
  migrations: nil,
  web: nil,
  schema_contract: nil,
  contribution_provider: nil,
  dev_seed: nil
]
EOF

cat > "$fixture/probe/mix.exs" <<'EOF'
Code.require_file(Path.expand("../../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.FinanceProbe.Probe.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../../..", __DIR__)

  def project do
    [
      app: :bilimbi_finance_probe_probe,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      deps: Bilimbi.Base.ModuleRegistry.MixDiscovery.module_dependencies(__DIR__)
    ]
  end

  def application do
    [env: Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__)]
  end
end
EOF

cat > "$fixture/probe/lib/probe.ex" <<'EOF'
defmodule Bilimbi.FinanceProbe.Probe do
  @moduledoc false

  def ledger, do: Bilimbi.Finance.Ledger
end
EOF

# Finance absent while a mounted dependent requires it: composition refuses.
mv "$finance" "$parked"
set +e
output=$(mix compile 2>&1)
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "$output"
  echo "composition accepted finance_probe/probe without Finance mounted" >&2
  exit 1
fi

if ! grep -qF "$expected" <<<"$output"; then
  echo "$output"
  echo "composition failed without the expected error: $expected" >&2
  exit 1
fi

echo "without Finance: $expected"

# Finance mounted again: the same graph composes and compiles.
mv "$parked" "$finance"
mix compile

if [ ! -f "$build/bilimbi_finance_probe_probe/ebin/Elixir.Bilimbi.FinanceProbe.Probe.beam" ]; then
  echo "finance_probe/probe did not compile with Finance mounted" >&2
  exit 1
fi

echo "with Finance: finance_probe/probe composes and compiles"
