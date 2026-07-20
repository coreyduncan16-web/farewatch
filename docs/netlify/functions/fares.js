// FareWatch live-fare function: fetches one route+date from Frontier's own
// booking page at request time and returns the flights as compact JSON.
// Called by the site's Search button:  /.netlify/functions/fares?o=ATL&d=TPA&date=2026-07-20
// Responses are CDN-cached for 4 minutes per route+date to stay polite.

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

exports.handler = async (event) => {
  const q = event.queryStringParameters || {};
  const o = (q.o || '').toUpperCase();
  const d = (q.d || '').toUpperCase();
  const date = q.date || '';
  if (!/^[A-Z]{3}$/.test(o) || !/^[A-Z]{3}$/.test(d) || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return { statusCode: 400, body: JSON.stringify({ error: 'bad params' }) };
  }
  const [y, mo, da] = date.split('-');
  const dd = encodeURIComponent(`${MONTHS[+mo - 1]} ${+da}, ${y}`);
  const url = `https://booking.flyfrontier.com/Flight/InternalSelect?s=true&o1=${o}&d1=${d}&dd1=${dd}&ADT=1&mon=true`;
  try {
    const r = await fetch(url, {
      headers: {
        'User-Agent': UA,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9'
      }
    });
    const raw = await r.text();
    const t = raw.replace(/&quot;/g, '"').replace(/&amp;/g, '&');
    const m = t.match(/FlightData = '([\s\S]+?)';/);
    if (!m) {
      const diag = q.debug
        ? { status: r.status, bytes: raw.length, hasMarker: raw.indexOf('FlightData') >= 0, head: raw.slice(0, 300) }
        : undefined;
      // Frontier's bot protection serves cloud IPs a small stub page.
      const blocked = raw.length < 200000;
      return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=60' },
        body: JSON.stringify({ flights: [], blocked, note: blocked ? 'live check blocked for cloud servers' : 'no flights that day', diag })
      };
    }
    const fd = JSON.parse(m[1].replace(/\\'/g, "'"));
    const list = (fd.journeys && fd.journeys[0] && fd.journeys[0].flights) || [];
    const flights = [];
    for (const f of list) {
      try {
        const legs = f.legs || [];
        if (!legs.length) continue;
        flights.push({
          dep: legs[0].departureDate,
          arr: legs[legs.length - 1].arrivalDate,
          stops: legs.length - 1,
          fn: legs.map(l => 'F9 ' + String(l.flightNumber).trim()).join(' / '),
          cash: f.standardFare,
          gw: f.goWildFare,
          gwOn: !!f.isGoWildFareEnabled
        });
      } catch (e) { /* skip malformed flight */ }
    }
    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=240' },
      body: JSON.stringify({ flights, fetched: new Date().toISOString() })
    };
  } catch (e) {
    return { statusCode: 502, body: JSON.stringify({ error: String(e && e.message || e) }) };
  }
};
