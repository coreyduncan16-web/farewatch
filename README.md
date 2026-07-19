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

Each run spends at most `apiCallsPerRun` calls (default 120) from the
`apiMonthlyBudget` (default 3720), prioritizing: stalest route-dates first,
with big boosts for departures inside the GoWild window, imminent departures,
and dates that just entered the window. Usage is tracked per calendar month in
`data\usage.json` and shown in the dashboard header.

To automate it, run `register-schedule.ps1` once — it creates a Windows
Scheduled Task ("FareWatch daily sweep", 07:30 local by default).

## Files

| File | Purpose |
|---|---|
| `config.json` | Routes, horizon, thresholds, budgets, provider choice |
| `.env` | Your API keys (never commit; gitignored) |
| `sweep.ps1` | Fetches fares, updates history, then renders |
| `render.ps1` | Rebuilds `dashboard.html` from history (safe to run alone) |
| `common.ps1` | Shared helpers |
| `data\history.json` | Price observations per route-date |
| `data\usage.json` | This month's API call count |
| `dashboard.html` | The output — open it in any browser |

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
- Many of these routes don't fly daily — a route-date that returns no
  flights is simply skipped, so gaps in the tables usually mean "no service
  that day", not missing data.
