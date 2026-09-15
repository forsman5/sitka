# H1: Household economy inside one settlement

**Next simulation cut.** An opt-in headless scenario, separate from the current pooled valley model. No new terrain, walking AI, intercity trading, or display overhaul.

## Question and first world

Can households in the same settlement produce, retain, exchange, and consume goods with individually explainable outcomes? “The town has food” must not imply that every family can access it.

Start with roughly **30 households**, one settlement, and two productive roles: farming and woodcutting. Reuse **grain and timber**; in this isolated experiment, timber represents household fuel demand. That is an explicit simplifying recipe, not a silent change to the valley's commodity balance. Author varied worker/dependent counts, productive capacity, and starting reserves. Use ordinary daily production initially; seasonality follows once local exchange works.

## State and ownership

- Household: stable ID, workers/dependents, residence ID, assigned workplace, owned goods, exchange balance, and per-good demand/consumption/unmet demand.
- Workplace: owner/operator household ID, recipe, capacity, and assigned worker-days. Output belongs to that household; inputs come from that owner.
- Market: posted quote per commodity, offers, requests, and transaction ledger. It owns no goods or money.
- Settlement: membership and derived summaries. No authoritative duplicate inventory.

One household operates one productive site initially, with no hired labor or wages. Output and transfers have explicit owners. A shared warehouse, if represented, changes storage location rather than ownership. Do not copy the existing city stock into every family.

## Two small implementation passes

**H1a — Ownership and subsistence.** Allocate each household's available labor to its site, produce into its inventory, consume from that inventory, and record its own fulfillment and stress. Two equally sized families with different reserves must experience different shortages. There is no automatic city-wide rationing.

**H1b — Local exchange.** Proposed first mechanism: a simple closed monetary test using abstract accounting units. This is a modeling choice, not a claim about early-medieval currency use. Seed balances once; sales transfer existing balances. No daily allowance, unlimited credit, taxes, merchants, or money creation.

Each day, households offer stock above a protected consumption buffer and request goods needed to reach a short target buffer. Subsistence needs determine requests before affordability caps purchases. Farmer households buy fuel; woodcutting households buy grain, allowing money to circulate in both directions. Production is already paid for through their own labor, so a wage system is unnecessary here.

Use one posted price per good during a day's matching. Reserve buyer balances and seller goods before clearing; buyers cannot spend anticipated same-day sale proceeds. Resolve scarce stock proportionally across funded requests, with deterministic rounding/tie-breaking, rather than letting the lowest household ID always eat first. Reconcile each completed transfer atomically.

Start with fixed positive quotes to prove accounting. Then add bounded, gradual next-day price adjustment from offered supply and affordable requested quantity; freeze the quote during clearing. Report unfunded need separately: inability to pay must not disappear from hunger statistics or be confused with absent goods. Prices with no offers and no funded requests remain unchanged.

## Daily order and feedback

Apply queued assignments → commit labor → produce → prepare and clear local offers/requests → consume owned goods → update household stress/outcomes → publish immutable records and next-day quotes.

Reuse existing stress/mortality logic only with that household's own fulfillment history. Disable relocation in this closed scenario. Expose household inventory, work, transactions, balances, food/fuel fulfillment, and reasons for failed purchases. Summaries include total stocks, offered stocks, price, and counts of households short of goods or funds.

## Acceptance and limits

1. Same seed and commands reproduce state and transactions.
2. Goods reconcile as opening + production − consumption; internal trades net to zero. Money is conserved and balances/stocks cannot go negative.
3. A provisioned subsistence household survives without buying its own output.
4. Complementary specialists sustain exchange after starting buffers run down; compare against exchange disabled.
5. Physical scarcity and unaffordability produce distinguishable household outcomes, even when city averages look healthy.
6. Reducing one household's worker capacity changes its output and access to goods; a controlled restoration permits recovery.

Do not force every fixture to succeed through subsidies or magical redistribution. Tune and document a viable fixture, plus shortage and liquidity-failure fixtures. Defer barter, communal redistribution, credit, hired labor, housing markets, autonomous job search, births, and intercity integration. A later institution can address deprivation explicitly.

**Done means:** we can explain who produced a sack of grain, who owned it, who acquired it, what they exchanged, and which household ultimately consumed it. Then decide how household actors connect to workplaces and trade establishments across five settlements.
