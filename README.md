# FareWatch — Frontier GoWild pass flight tracker

Tracks Frontier (F9) one-way fares on your routes every day, judges each
price against **that route-date's own history**, and renders `dashboard.html`
with two views:

1. **Cash fare timing** — BUY / WATCH / HOLD / SPIKE calls for normal tickets,
   based on where today's price sits in the route-date's observed range.
2. **GoWild window** — for departures inside the 10-day international GoWild
   booking window: **real GoWild pass fares and per-flight seat availability**,
   read straight from Frontier's public booking pages (all-in totals:
   $0.01 fare + taxes/fees). A snapshot, not a hold — pass inventory moves
   fast, so confirm logged in at flyfrontier.com before counting on a seat.

Everything is plain Windows PowerShell 5.1 — no Python, no Node, nothing to
install.

## 1. No API key needed

The default provider is **`frontier`** — it reads fares (cash *and* GoWild)
from flyfrontier.com's own booking pages. No account, no key, no login.
Just run:

```powershell
powershell -ExecutionPolicy Bypass -File .\sweep.ps1
```

Be a polite guest: keep `frontierSleepMs` (800 ms between requests) and the
call budgets as they are, and don't run sweeps in a tight loop. This is
Frontier's public site, not a documented API — if they change their page
format, the sweep records nothing and the dashboard just goes stale until the
parser is updated.

## Optional fallback providers (these need keys)

If the frontier provider ever breaks, `config.json` can switch to
`amadeus` or `serpapi` for cash fares (neither carries GoWild pass fares):

1. Go to <https://developers.amadeus.com> and click **Register**.
2. Confirm your email, sign in, and open **My Self-Service Workspace**.
3. Click **Create New App**, give it any name (e.g. `farewatch`).
4. Copy the **API Key** and **API Secret** it shows you.
5. In this folder, copy `.env.example` to `.env` and paste them in:

   ```
   AMADEUS_CLIENT_ID=your_api_key_here
   AMADEUS_CLIENT_SECRET=your_api_secret_here
   ```

New Amadeus apps start in the **test** environment (free, limited/cached
data; their docs warn some low-cost carriers are missing, so F9 coverage is
not guaranteed). SerpAPI's free tier is ~100 searches/month.

After any provider change, sanity-check it:

```powershell
powershell -ExecutionPolicy Bypass -File .\sweep.ps1 -VerifyCoverage
```

## 2. Try it with fake data first (optional)

```powershell
powershell -ExecutionPolicy Bypass -File .\sweep.ps1 -Demo
```

fills the history with synthetic data and renders `dashboard.html` so you can
see the full dashboard working today. Delete the `data\` folder before your
first real sweep to clear the demo data.

## 3. Daily runs

```powershell
powershell -ExecutionPolicy Bypass -File .\sweep.ps1
```

Each run spends at most `apiCallsPerRun` calls (default 120), prioritizing:
stalest route-dates first, with big boosts for departures inside the GoWild
window, imminent departures, and dates that just entered the window. For the
paid API providers this also draws down the `apiMonthlyBudget` (default 3720),
tracked per calendar month in `data\usage.json`; the free `frontier` provider
scrapes the public site and is capped only by `apiCallsPerRun` and
`frontierSleepMs`.

A route-date is only re-priced once it is at least `minRefreshHours` old
(default 1). Every observation is stamped with the exact time it was priced, so
re-running the sweep during the day actually refreshes prices instead of
skipping anything already seen today — set `minRefreshHours` higher for a
lighter once-a-day cadence.

To automate it, run `register-schedule.ps1` once — it creates a Windows
Scheduled Task ("FareWatch daily sweep", 07:30 local by default) that runs
`run-daily.ps1`: sweep → render → alerts → publish to the website. To refresh
prices through the day, pass `-EveryHours 1` (pairs with `minRefreshHours`):

```powershell
powershell -ExecutionPolicy Bypass -File .\register-schedule.ps1 -EveryHours 1
```

## Trip planner ("get me there under $X")

Tell Claude something like *"get me from ATL to MBJ Tuesday for under
$150"* — or run it yourself:

```powershell
powershell -ExecutionPolicy Bypass -File .\plan.ps1 -From ATL -To MBJ -Date 2026-07-21 -Budget 150
```

It prices the direct flight plus "airport hopping" self-connects through
Frontier hubs (`hubs` in config.json), using the GoWild fare on any leg with
pass seats and cash otherwise. Options: `-Hubs MCO,DEN` to limit the search,
`-MinConnectMinutes 120`, `-NoOvernight`. **Each hop is a separate booking:**
if leg 1 is late, leg 2 does not wait and owes you nothing — leave generous
connections.

## Search bar

The dashboard now has a **Search a route** section: pick From/To (plus an
optional date), and it lists every tracked departure for the pair, cheapest
GoWild fare first, with per-date "live" deep links straight into Frontier's
own booking search. It runs entirely in the browser, so it works on static
hosting too. Each result has a **watch** button that generates the
`watches.json` entry for that route.

## Price-drop alerts (email or text) — GoWild fares only

1. Copy `watches.example.json` to `watches.json` and edit. Each watch:
   - `route`: `"MCO-PUJ"` or `"ANY"`
   - `maxGw`: alert when the GoWild all-in total is at or under this dollar cap
   - `dropPct`: alert when it is this % under the route's own trailing
     average GoWild fare (kicks in once a route has 5+ observations)
   - `to`: emails, and/or texts via carrier gateways —
     `5551234567@vtext.com` (Verizon), `@txt.att.net` (AT&T),
     `@tmomail.net` (T-Mobile)
2. Put SMTP settings in `.env` (see `.env.example`). For Gmail, create an
   **App Password** yourself at <https://myaccount.google.com/apppasswords>
   — never put your real password in a file.
3. Test without sending: `powershell -ExecutionPolicy Bypass -File .\alerts.ps1 -Test`

Alerts run automatically after every real sweep. A ledger
(`data\alerts-sent.json`) stops repeats unless the price drops further.
Cash fares never trigger alerts — GoWild pass totals only.

## Hosting it for everyone (free)

The site is a static page, so **GitHub Pages** hosts it free. Your PC stays
the engine: the scheduled task sweeps fares and pushes the fresh page.

One-time setup (about 5 minutes, needs your GitHub account):

1. Open **GitHub Desktop** → File → *Add local repository* →
   `D:\CLAUDE\farewatch` → **Publish repository** (uncheck "Keep this code
   private" if you want the world to see the code too; the site works either
   way on a free account only if the repo is public).
2. On github.com open the repo → **Settings → Pages** → Source: *Deploy from
   a branch* → Branch: `master`, folder: `/docs` → Save.
3. Your site appears at `https://YOURUSERNAME.github.io/farewatch/` about a
   minute later, and every `run-daily.ps1` run updates it automatically.

Privacy guardrails already in place: `.env` (passwords), `watches.json`
(your email), and `data\` (raw history) are gitignored and never leave this
machine — only the rendered page is published.

**Honest limits of the free setup:** the public page is a snapshot that
updates when your PC sweeps; visitors can browse and search it, and the
watch button hands them a config snippet, but only watches configured on
this machine actually send email/texts. Letting strangers subscribe
themselves needs a small backend (e.g. Cloudflare Workers + a free email
API) — a later upgrade if you want it.

## Files

| File | Purpose |
|---|---|
| `config.json` | Routes, hubs, horizon, thresholds, budgets, provider choice |
| `.env` | Keys + SMTP settings (never committed) |
| `sweep.ps1` | Fetches fares, updates history, renders, fires alerts |
| `render.ps1` | Rebuilds `dashboard.html` (search bar + cheapest-departures board) from history |
| `plan.ps1` | Trip planner: cheapest routing A→B within budget |
| `alerts.ps1` | GoWild price-drop email/text alerts (`-Test` to dry-run) |
| `watches.json` | Your alert rules (gitignored) |
| `publish.ps1` | Copies dashboard to `docs\index.html`, commits, pushes |
| `run-daily.ps1` | sweep → publish; what the scheduled task runs |
| `common.ps1` | Shared helpers incl. the flyfrontier.com fetcher |
| `data\` | History, departures snapshot, usage, alert ledger (gitignored) |
| `docs\index.html` | The published site (GitHub Pages serves this) |

## How the signals work

- A route-date needs `minObservations` (5) sweeps before it graduates from
  **LEARNING**.
- **Percentile** = where today's price sits between the lowest and highest
  price ever observed for that exact route + departure date.
- **BUY** = bottom 15% of its own range *and* at-or-below its median.
- **WATCH** = bottom 35%. **SPIKE** = top 15%. Otherwise **HOLD**.
- GoWild rows show the real cheapest pass total and how many of that day's
  flights had pass seats at sweep time (e.g. `3/15`). Rows the sweep hasn't
  reached yet fall back to a labeled proxy score (soft cash fare + Tue/Wed
  departure + release-window proximity).
- The **Cheapest departures** board flattens every individual GoWild-eligible
  flight from the last sweep across all tracked routes and dates, ranked by
  all-in pass total (toggle low&harr;high, filter by origin / nonstop / in
  window). It reads `data\departures.json`, a latest-snapshot-per-route-date
  store the sweep writes for the `frontier` provider &mdash; the cheapest seats
  bubble to the top so you can see where the cheap hops line up. Cap the row
  count with `departuresTableRows` in config.json.
- Many of these routes don't fly daily — a route-date that returns no
  flights is simply skipped, so gaps in the tables usually mean "no service
  that day", not missing data.
