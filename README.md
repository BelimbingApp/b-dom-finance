# b-dom-finance

Finance Domain for [Bilimbi](https://github.com/BelimbingApp/bilimbi): a
company's bookkeeping. It is one optional, independently versioned repository
that an adopter mounts into a Bilimbi checkout; it does not build on its own.

| Module | Descriptor ID | Owns |
| --- | --- | --- |
| [`ledger/`](ledger/docs/README.md) | `finance/ledger` | each company's book and currency, chart of accounts, balanced and immutable journal entries, fiscal years and period closing, year-end close, trial balance, and posting notices |
| [`payables/`](payables/docs/README.md) | `finance/payables` | bills and debit notes from parties, approval and posting, the three-way match of a bill against the purchase order and goods receipts behind it when Supply Chain is mounted, payments allocated to bills, and aged payables |
| [`einvoice/`](einvoice/docs/README.md) | `finance/einvoice` | fiscal documents cleared by a tax authority (first, Malaysia's MyInvois): immutable documents and notes, self-billed documents, monthly consolidated documents, submissions and status events, the submit and poll jobs, the authority's code lists, each company's credentials and certificate, the printable document, and the ledger bridge |
| [`fixed_assets/`](fixed_assets/docs/README.md) | `finance/fixed_assets` | permanent asset register, immutable category defaults, monthly book depreciation that skips and reports assets whose acquisition was reversed, disposals, voided acquisitions and reversals, and reproducible register/schedule reports reconciled with the ledger |
| [`reports/`](reports/docs/README.md) | `finance/reports` | profit and loss, balance sheet, cash position, and headline figures read live from the ledger, with the entries behind each figure |
| [`receivables/`](receivables/docs/README.md) | `finance/receivables` | customers, numbered and immutable invoices and credit notes, payments received and their allocation, and aged receivables |
| [`reconciliation/`](reconciliation/docs/README.md) | `finance/reconciliation` | bank accounts mapped to ledger accounts, immutable imported bank statements, matches between statement lines and ledger entries with their append-only events, and reconciliations finalised at zero difference and kept with their figures |
| [`payroll/`](payroll/docs/README.md) | `finance/payroll` | each company's mapping of payroll components and claim categories to ledger accounts with its change history, one balanced entry per finalised payroll run and per approved staff claim posted once through the ledger, reversals with reasons, and the append-only record of every attempt; the runs and claims come from the People Domain when it is mounted |
| [`sst/`](sst/docs/README.md) | `finance/sst` | Malaysia's Sales and Service Tax return (SST-02): the registration and tax code mappings as numbered versions, and returns per tax and taxable period computed from posted documents, reconciled with the tax accounts, finalised into immutable snapshots, and amended by new versions |

The ledger is the first module. Other Finance modules, such as receivables,
payables, e-invoicing, and reports, sit beside it as sibling module folders
and post or read through its public API; other Domains post through the same
API. The ledger and receivables expose their APIs with no pages, menu
entries, or agent operations; payables has pages for its bills and the ones
the three-way match holds. E-invoicing issues documents through its
own facade, posts validated ones through the ledger's, and has pages for its
documents, its reconciliation, and its setup. Reports reads the ledger's
figures and has the financial reports pages. Bank reconciliation imports
bank statements, matches their lines to the ledger's postings, posts bank
charges and interest through the ledger's facade, and has pages for its
bank accounts, statements, matching, and reconciliations. Payroll posting
reads finalised payroll runs and approved claims from the People Domain
through a seam that finds it at run time, posts them through the ledger's
facade, and has pages for its postings and its account mappings. Fixed assets
has pages for categories, the register, asset schedules and depreciation runs,
and posts charges and disposals through the ledger facade. SST returns
read receivables' and payables' document tax and the tax accounts' postings
through their facades, and have pages to prepare, review, finalise, amend,
and export each return and to set up the registration and tax code
mappings. Each module's "Standards addressed" section says which bookkeeping
and audit standards it meets.

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
revision to build against a newer Platform. The job's last step runs
[`missing_dependency.sh`](.github/scripts/missing_dependency.sh), which proves a
mounted dependent without Finance fails composition.

## License

[MIT](LICENSE).
