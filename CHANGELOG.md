# Changelog

## 0.1.0 (2026-11-16)

First release.

- **The next departures from the stops you pick,** in the menu bar, with each route's color, where it's headed and the minutes until it leaves.
- **Live where the agency's feed has it,** with how late or early each ride is running, and from the timetable otherwise, clearly marked. Delays carry down the line, as the GTFS-realtime spec describes.
- **Canceled rides, skipped stops and service alerts** for your stops and routes.
- **Metro Transit, ready to go:** METRO light rail and bus rapid transit, regional buses, and the University of Minnesota's campus buses.
- **Any agency's GTFS and GTFS-realtime feeds,** by pasting their addresses.
- **Both sides of the street, or both platforms, as one stop,** and a route filter for each stop.
- **A departure board window** with alerts at the top.
- **The countdown in the menu bar,** off until you turn it on.
- **The `next-departures` command line tool** to find stops and print departures and alerts, as text or JSON.
- **Polite to agencies:** the live feed is checked every 30 seconds only while the menu or window is open, with backoff after errors, and the schedule once a day.
- **Open at login**, on by default and easy to turn off.
- Runs in the App Sandbox with one entitlement, outgoing connections, and connects only to the feeds you use. Its own zip, CSV and protocol buffer readers, fuzz tested, and no dependencies.
