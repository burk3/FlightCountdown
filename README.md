# Flight Countdown

A World of Warcraft: Forever addon that shows a countdown of your remaining
flight time while you're on a flight path.

- **Blue bar**: an exact time, learned from flying the route before (shared across your characters).
- **Amber bar with `~`**: an estimate from the route's distance on the flight map. It improves as you fly.
- Hovering a destination on the flight map shows its flight time in the tooltip.
- Survives `/reload` mid-flight.

## Install

With [CurseBreaker](https://github.com/AcidWeb/CurseBreaker):

```
install gh:burk3/FlightCountdown
```

Or download the zip from [Releases](https://github.com/burk3/FlightCountdown/releases) and extract it into
`World of Warcraft\_forever_\Interface\AddOns`.

## Commands

| Command | |
|---|---|
| `/fc unlock` / `/fc lock` | Move the bar |
| `/fc reset` | Reset bar position |
| `/fc test` | Show a 20-second demo |
| `/fc tooltip` | Toggle the flight map tooltip line |
| `/fc forget` | Erase learned flight times |

## Releasing

Push a tag like `v1.0.1`. The GitHub Action packages the addon with the
[BigWigs packager](https://github.com/BigWigsMods/packager) and publishes a
GitHub release (zip + `release.json`). Pushes to `main` build a zip as a
workflow artifact without releasing.
