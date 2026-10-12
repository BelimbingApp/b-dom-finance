Code.require_file(Path.expand("../../../../web/test/test_helper.exs", __DIR__))

# Every authority call answers from a Req.Test stub; nothing leaves the machine.
Application.put_env(:bilimbi_finance_einvoice, :req_options,
  plug: {Req.Test, Bilimbi.Finance.Einvoice.MyInvois.Client}
)
