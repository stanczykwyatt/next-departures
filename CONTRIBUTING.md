# Contributing

Thanks for helping out! Bug reports, ideas and pull requests are all welcome.

## Reporting a feed it reads wrong

If a departure is missing, at the wrong time, on the wrong day, or shown as live when it isn't, open a [bug report](https://github.com/stanczykwyatt/next-departures/issues/new?template=bug.yml) with the agency, the stop's number or ID, the route, when you looked, and what the stop's sign or the agency's own app said instead. Stops are public, so naming one is fine. If it's a feed you added, include its addresses unless they have an API key in them.

The command line tool shows what the app sees, which helps the most:

```bash
next-departures departures <stop> --json
```

## Getting started

You need macOS 14 or later and Swift 6 (Xcode 16 or the Command Line Tools).

```bash
swift test                # run the tests
scripts/build-app.sh      # build "Next Departures.app" and next-departures into ./build
open "build/Next Departures.app"
```

Reading feeds and working out departures lives in `Sources/TransitCore`, with tests in `Tests/TransitCoreTests`:

- `Protobuf.swift`, `Zip.swift` and `CSV.swift` read the file formats. Changes here need tests with damaged input as well as good, and must keep the fuzz tests passing.
- `Realtime.swift` reads GTFS-realtime, `Schedule.swift` reads the GTFS schedule, and `Departures.swift` puts them together. A change to how a departure's time is worked out belongs in `Departures.swift`, with a test in `DepartureTests.swift` built on the made-up Lakeside Transit agency in `Fixtures.swift`.
- `Fetcher.swift` is the only file that touches the network.

The menu bar app, the menu and the window are in `Sources/NextDepartures`, tested in `Tests/NextDeparturesTests` with a made-up agency, Northfield Transit, and windows that are never shown. No test goes online, reads your settings or puts anything on screen.

To redraw the art: `swift scripts/make-icon.swift`, `swift scripts/make-art.swift`, and `SCREENSHOT_DIR=docs swift test --filter Window` for the screenshots.

## Ground rules

- **No hosts but the feeds.** Pull requests that add analytics, crash reporting, update checks, fonts, maps or any other host won't be merged. The app only ever talks to the transit feeds you use.
- **Nothing about the rider leaves the Mac.** Not the stops, not the location, not an identifier. Requests stay plain file downloads.
- **Polite polling.** The live feed is only checked while someone's looking, no more than every 30 seconds, with backoff after errors. Never in the background.
- **Least access.** No new entitlements without a very good reason. The app has the sandbox and outgoing connections, and that's all.
- **No new dependencies** without a very good reason. The app has none, including for zip and protocol buffers, which keeps it easy to audit.
- **Presets only for open feeds.** A new preset agency needs feeds published openly, terms that allow apps like this one, and the credit line its terms ask for. Say where you found the terms in the pull request.
- **Made-up agencies** in screenshots, art and tests.
- Run `swift test` before opening a pull request, and add tests for changes to `TransitCore`.
- Keep commits small, with a short message saying what changed and why.

## Security issues

Please don't open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
