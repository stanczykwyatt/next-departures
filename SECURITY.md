# Security

Next Departures is the first of these apps that goes online, so it's built to do that as little as possible, to talk only to the transit agencies you choose, and to send nothing about you.

## Reporting a vulnerability

Please report security problems privately through **Security → Report a vulnerability** on this repository, not in a public issue. You'll get a reply within a few days.

## What Next Departures connects to

| | |
|---|---|
| **The feeds you use, and nothing else** | For Metro Transit, `https://svc.metrotransit.org/mtgtfs/gtfs.zip`, `tripupdates.pb` and `alerts.pb`. For a feed you add, the addresses you paste. A feed's addresses are only fetched once you've picked a stop on it, or chosen Download Schedule for it. |
| **When** | The live trip updates and alerts every 30 seconds while the menu or the window is open, less often after errors, and as long as the server asks after a "try later". The moment both are closed, the live check in progress is stopped and no more are made, and nothing runs in the background. The schedule once a day at most, when you open the menu or window, with a request that comes back empty if it hasn't changed; after a failed check, again in an hour, and a first download that fails waits a minute, then longer, up to an hour, unless you click Download Schedule. A schedule download that's already under way finishes even if you close the menu. |
| **What's sent** | An ordinary HTTPS request for the file, with the app's name and version as the user agent, and for the schedule, the tag the server gave last time so it can say "not changed". No cookies, no account, no identifiers, no location, and nothing about which stops you picked. Like any website, the agency's server sees your IP address. |
| **What's kept** | Each feed's schedule zip as published, an index read from it, and the stop times for your stops, in the app's sandbox container under `~/Library/Containers/com.stanczykwyatt.NextDepartures`. Live updates are never written to disk. Removing a feed deletes what was kept for it. |
| **Its own settings** | Your stops, the feeds you added and your options, stored in the app's sandbox container. |

No analytics, crash reporting, update checks or other hosts. Next Departures has no server of its own.

### How that's enforced

- **One place talks to the network.** `Sources/TransitCore/Fetcher.swift` is the only file that uses `URLSession`, and CI fails any build where anything else does, or where any other networking API appears.
- **An allowlist of hosts.** Every request is checked against the hosts of the feed it's for before it's sent. Only `https` is allowed.
- **No redirects elsewhere.** A redirect to another host, or to plain `http`, is refused, so a feed's server can't send the app somewhere you didn't choose.
- **Not your own network.** Pasted addresses must be `https` with a public-looking host: `localhost`, `.local`, `.lan`, `.home` and similar names, and private, loopback, link-local, multicast and IPv4-in-IPv6 addresses are refused, in every form the system accepts, like `127.1` or `0x7f.0.0.1`. This is checked on the address as written: a public name that a network's own DNS points at a private address can't be told apart this way. Addresses with a name and password in them are refused too.
- **Size limits.** A schedule over 250 MB or a live file over 20 MB is stopped as soon as it passes the limit.
- **No cookies, cache or stored credentials.** Requests use an ephemeral session with all three turned off.
- **App Transport Security is left on,** with no exceptions in `Info.plist`.

## What it can't access

- **Your files.** The App Sandbox limits it to its own container. It has no entitlement for files you choose, Documents, Downloads or anything else.
- **Your location, contacts, calendar, camera and microphone.** It has no entitlement for any of them, and never asks.
- **Incoming connections.** It has the client network entitlement only, so it can't listen for connections.
- **Other apps.** No Apple Events, no Accessibility. It never starts another program; CI checks for that.

Check it yourself on any copy of the app:

```bash
codesign -d --entitlements - "/Applications/Next Departures.app"
```

The only entitlements are `com.apple.security.app-sandbox` and `com.apple.security.network.client`. CI checks every build has exactly those two.

## How it handles what feeds send

Everything a feed sends is treated as untrusted: a server could be broken, or someone else's.

- **Its own readers, written for this.** The zip archive, CSV and protocol buffer readers are in `Sources/TransitCore`, with no third-party code. They're tested with real-world and hand-built files, and fuzz tested with thousands of damaged, cut-short, spliced and random inputs, which must be read or refused, never crash.
- **Protocol buffers:** every length is checked against what's left, varints longer than ten bytes are refused, nesting is limited to 16 levels, bytes that aren't UTF-8 become a replacement mark, fields of an unexpected type are skipped, and a feed can hold at most 200,000 entities, 400,000 stop updates in all, 2,000 per trip, and 100,000 alert parts, so a small hostile feed can't grow huge in memory.
- **Zip archives:** every offset and size is checked against the file before it's used. Each file is inflated a piece at a time by macOS's own Compression framework, never all at once, and its length and CRC-32 must match the directory. Encrypted entries and compression methods other than stored and DEFLATE are refused, and so is any file claiming to shrink more than 250 to 1, which no real schedule does, or larger than 2 GB.
- **CSV:** a line longer than a megabyte, usually a quote that never closes, stops the read; a quote in the middle of a field is just a character. There are caps on agencies, stops, routes, trips, services, calendar dates, stops per trip and stop times kept, all far above any real agency's.
- **Text** from a feed, like stop names and alert wording, has control characters, escape codes and invisible formatting marks removed and is cut to a sensible length before it's shown, and before the command line tool prints it, so it can't send your terminal an escape sequence.
- **Times** outside 2000 to 2100 are treated as missing, and live data is shown as the timetable, not as live, once the feed's own timestamp or the time it was fetched is more than five minutes old.
- **Trips the timetable doesn't know** are only shown as extra rides when the feed marks them as added, so a newer timetable's trips don't show twice.
- **Feed IDs** that name folders are checked to be plain lowercase names, so a settings file edited by hand can't point outside the container, and pasted addresses are checked again when settings are read.
- **A broken new schedule** is ignored and the last good one kept, and it isn't downloaded again until the next day.

## The command line tool

`next-departures` runs as you, in your terminal, so it isn't sandboxed. It uses the same code: the same fetcher, the same host allowlist and the same readers. It only connects to the feed you name, keeps schedules in `~/Library/Caches/next-departures`, and writes nothing else.

## The signature

Releases are signed ad hoc, not with a paid Apple Developer ID, with the bundle ID as the designated requirement so macOS recognizes updates as the same app and keeps its settings. Next Departures asks macOS for no permissions, so there's nothing another program could gain by claiming the same ID. A Developer ID signature is planned, and with it a widget.
