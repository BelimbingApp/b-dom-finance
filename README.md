# b-dom-finance

Finance Domain for [Bilimbi](https://github.com/BelimbingApp/bilimbi): a
company's bookkeeping. It is one optional, independently versioned repository
that an adopter mounts into a Bilimbi checkout; it does not build on its own.

| Module | Descriptor ID | Owns |
| --- | --- | --- |
| [`ledger/`](ledger/docs/README.md) | `finance/ledger` | each company's book and currency, chart of accounts, balanced and immutable journal entries, trial balance, and posting notices |
| [`einvoice/`](einvoice/docs/README.md) | `finance/einvoice` | fiscal documents cleared by a tax authority (first, Malaysia's MyInvois): immutable documents, signed submissions and status events, the authority's code lists, and each company's credentials and certificate |
| [`reports/`](reports/docs/README.md) | `finance/reports` | profit and loss, balance sheet, cash position, and headline figures read live from the ledger, with the entries behind each figure |

The ledger is the first module. Other Finance modules, such as receivables,
payables, tax, and bank reconciliation, sit beside it as sibling module
folders and post or read through its public API; other Domains post through
the same API. The ledger exposes that API with no pages, menu entries, or
agent operations. E-invoicing issues documents through its own facade and
has one page, its setup. Reports reads the ledger's figures and has the
financial reports pages. Each module's "Standards addressed" section says
which bookkeeping and audit standards it meets.

## Mount

Clone this repository into a Bilimbi checkout at `apps/domains/finance`, then
work from the Bilimbi root:

```sh
git clone https://github.com/BelimbingApp/b-dom-finance.git apps/domains/finance
mix deps.get
mix bilimbi.migrate
mix precommit
```

Bilimbi discovers the mounted container from `bilimbi.container.exs`; no list
names it. Removing the directory removes Finance's code from the next build
and keeps its data. The composition rules, including the shared composition
lock, are in Bilimbi's
[composition model](https://github.com/BelimbingApp/bilimbi/blob/main/docs/architecture/0010_composition-model.md).

## Naming

Optional Bilimbi repositories are named `b-<role>-<id>`: `b-` for Bilimbi,
`dom-` for a Domain. The mount folder is the container ID, with hyphens as
underscores, so `b-dom-finance` mounts at `apps/domains/finance`.

## CI

CI checks out Bilimbi at the revision in
[`.github/bilimbi-revision`](.github/bilimbi-revision), mounts this
repository, and runs Bilimbi's precommit over the composed workspace. Bump that
revision to build against a newer Platform. A second job runs the same
precommit with Finance absent, and
[`missing_dependency.sh`](.github/scripts/missing_dependency.sh) proves a
mounted dependent without Finance fails composition.

## License

[MIT](LICENSE).
