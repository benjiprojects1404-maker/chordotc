# crescent-onramp

A small Cloudflare Worker that lets Crescent (chordotc.com/crescent/) offer **Buy USDC/EURC with a bank transfer
or card**, using Arc's Onramp widget. It holds the Circle API key (as a Cloudflare secret) and mints short-lived
widget sessions. The widget, hosted by Arc, does the identity check and the payment and delivers the stablecoin to
the buyer's own wallet on Arc. This Worker never sees card, bank or ID details, and never holds money.

- `GET /config`: `{ enabled, env, widgetBaseUrl }`, so the page always matches sandbox or production.
- `POST /session`: `{ appUserId, destinationAddress, token, amount }`. Only accepted from `ALLOWED_ORIGIN`;
  checks the address, token (USDC or EURC) and amount (up to 10,000) before calling Circle; about 10 requests
  a minute per IP.

## Deploy (sandbox first)

```bash
cd onramp-worker
npm install
npx wrangler secret put CIRCLE_API_KEY     # paste the sandbox (testnet) key when asked
npx wrangler deploy
```

It deploys to `https://crescent-onramp.<your-subdomain>.workers.dev`, which must match `ONRAMP_API` in
`site/crescent/index.html`.

While `ONRAMP_ENV = "sandbox"`, Crescent only shows the box on payment links with `&onramp=test` added, labelled
"Test mode: no real money". Sandbox moves no real money: card details are fake, any face photo passes the ID check,
and test tokens are sent instead.

## Going live

Bank transfers (US and SEPA) only need the website registered in the Circle Console (Mainnet → App Kits →
Onramp Kit, step 2: `chordotc.com`). Card, Apple Pay and Google Pay also need the business questionnaire (step 3).

1. `npx wrangler secret put CIRCLE_API_KEY` with the **mainnet** key.
2. In `wrangler.toml` set `ONRAMP_ENV = "production"`, keep `ONRAMP_PUBLIC = "false"`, then `npx wrangler deploy`.
   The live widget now shows only on links with `&onramp=test`: make one small real purchase to check it end to end.
3. Set `ONRAMP_PUBLIC = "true"` and `npx wrangler deploy`. Crescent shows the box on every USDC and EURC payment
   link, without the test label.

## Updating the browser bundle

`site/crescent/onramp-kit.js` is `@circle-fin/onramp-kit` bundled for the page. After upgrading the package:
`npm run build:client`.
