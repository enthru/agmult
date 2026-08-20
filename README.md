# 34401A Multimeter — macOS

A native macOS application for controlling and logging from the HP / Agilent /
Keysight **34401A** 6½-digit multimeter over RS-232.

Written from scratch in Swift and SwiftUI. It takes its feature set from
[Nirav Patel's Windows application](https://github.com/Niravk1997/HP-Agilent-Keysight-34401A-Control-and-Data-Logging-Software)
(C#), which served as the basis and inspiration for what this kind of tool
should do — see [CREDITS.md](CREDITS.md). No code was carried over: the serial
layer, threading model, graphing, simulator and tests are all original.

![The main window: readout and annunciators across the top, function keys and the
measurement panels on the left, readings and the event list on the
right](screen.jpg)

Companion project: [agpsu](../agpsu), the same treatment for the 663x / 661x
system DC power supplies.

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 6)
- A USB-to-RS-232 adapter **and a null-modem adapter or cable** — or nothing at
  all, if you use the built-in simulator

## Build and run

```sh
swift build                  # build everything
swift test                   # 192 tests, including a full loop against the simulator
./Scripts/make-app.sh        # assemble build/AgilentDMM.app
open build/AgilentDMM.app
```

`swift run AgilentDMM` also works, but the assembled bundle gets a proper Dock
icon and menu bar.

## Trying it without hardware

The package ships a SCPI-speaking simulator of a 34401A. It models all ten
functions, the ranges and auto-ranging with a real 120% overrange point,
integration time and its effect on noise, triggering and multi-reading bursts,
the CALC maths, the questionable status register, the error queue and the front
panel — and it presents itself on a pseudo-terminal, so the application talks to
it through the same termios serial path it would use for a real meter.

In the app: **Config ▸ Start Built-in Simulator**, then **Connect**. Once it is
running, **Config ▸ Simulated Signal** steers what it is pretending to measure.

Standalone, for scripting or for pointing other software at it:

```sh
swift run agmult-sim --volts 4.19 --shape sine --period 20
# Simulated HP34401A ready.
#   Device path : /dev/ttys004
```

## Connecting real hardware

1. Wire it up: meter's serial port → null-modem adapter → RS-232 cable → USB
   adapter → Mac. A straight-through cable will not work: the meter is a DTE and
   so is your adapter.
2. On the meter: `Shift ▸ Menu`, `I/O MENU`, set `HP-IB/232` to `RS-232`, then
   check `BAUD RATE` and `PARITY`.
3. In the app: **Config ▸ Select Serial Port…**, pick the `/dev/cu.*` device,
   leave the defaults at 9600 / Even / 7 / 2, and press **Connect**.

Use the `cu.*` device, never the matching `tty.*` one — the latter waits for
carrier detect and appears to hang. macOS has built-in drivers for FTDI and
CDC-ACM adapters; PL2303 and CH340 clones need the vendor driver installed
before they show up.

Do not use the RS-232 port if the meter is wired to output pass/fail signals on
pins 1 and 9; the manual is explicit about that one.

## The window

The readout across the top, then a one-line strip with the meter, the port and
the error queue. Below that a split: the function keys as a row with the
remaining controls in a grid beneath them — two columns as soon as there is
width for two, one when there is not — and on the right the live trace over the
readings that produced it, in a split you can drag or collapse.

Drag across the trace to select a region; its statistics appear under the chart
without leaving the window. The separate Graph window (⌘1) is still there for
when you want the trace on its own screen.

## What it does

- **Live readout** — the reading at instrument size, with annunciators for
  function, range, resolution, maths, trigger source, burst size and remote
  state, and the running statistics beside it. The SI prefix comes from the *range* and the decimals from the
  *resolution*, so a 6½-digit reading looks like one and a value drifting around
  zero does not flip between µV and mV several times a second.
- **All eleven functions** — DC and AC volts, DC and AC current, 2- and 4-wire
  resistance, frequency, period, continuity, diode test, and the dc:dc ratio,
  which divides the signal on the Input terminals by a reference on Sense and so
  reads as a bare number with no unit at all.
- **Range and resolution** — auto or manual range, integration time from 0.02 to
  100 PLC, counter gate time, AC filter bandwidth, auto zero, and the >10 GΩ
  input on the low DC voltage ranges.
- **Triggering** — immediate, bus or external, with trigger delay and a burst
  size up to 512, which is the real lever on throughput.
- **Meter maths** — null with a one-key capture, dB, dBm against a chosen load,
  the meter's own min/max/average, and limit testing with logging and a beep.
- **Statistics** — count, minimum, maximum, mean, standard deviation and
  peak-to-peak, accumulated with Welford's algorithm so the spread survives
  six-and-a-half digits of large readings, and kept over everything recorded
  even after old readings scroll out of the buffer.
- **Graph** — a live strip chart with mean, min/max and limit markers,
  sample-number or time axis, per-graph colours and themes, drag-to-select
  regions with their own statistics, and PNG / CSV export.
- **Histogram** — the distribution of the readings or of any math waveform, with
  mean and ±σ markers.
- **Stability** — overlapping Allan deviation on log-log axes, which is what a
  long capture is actually for: how much the *average* moves if you average for
  a second, a minute, an hour, and where averaging stops helping. The window
  names the noise from the slope, marks the optimum averaging time, draws the
  under-determined long taus hollow, and reports the drift rate underneath as a
  least-squares line with its r².
- **Math waveforms** — derived series over the captured readings: scale, moving
  average, median, low-pass, deviation from mean, ppm against a reference,
  difference, derivative, integral, absolute value, square, reciprocal, decibels
  and power into a load. A waveform's source can be the measurement *or another
  waveform*, so transforms chain.
- **Measurement table** — every reading with its index and timestamp, exportable.
- **Logging** — readings to text or CSV and every event-list entry to text,
  named `date-model-port-…`, written to `~/Documents/AgilentDMM` or a folder you
  choose. Overloads are logged as `OVLD` rather than dropped.
- **Speech** — spoken readings on a timer or when a threshold is crossed. More
  useful than it sounds: when both hands are holding probes onto a board,
  hearing the reading is the only way to take it.
- **Settings are remembered** — panel colours, graph and histogram appearance,
  math waveform definitions and their chains, the polling plan, the meter and
  math configuration, history size, logging, speech, and the port that worked
  last time. Nothing is sent to the meter at launch: the restored configuration
  goes down when you connect.

## Getting a useful reading rate

Every query is one serial round trip, and at 9600 baud a round trip costs
several milliseconds before the meter has even started measuring. The way to a
high rate is not to ask more often but to ask for more at once.

**Readings per burst** sets `SAMPle:COUNt`: the meter takes that many readings on
one trigger and returns them all in one response. Combine it with 0.02 PLC, auto
zero off and the meter's own display switched off — that last one is the single
biggest speed-up the instrument offers.

The picker stops at 512. `SAMPle:COUNt` itself accepts 50,000, but 512 is what
the meter's internal memory holds, and past that the burst takes long enough that
the even spacing this app stamps across it stops being a fair estimate of when
each reading was actually taken.

The questions themselves are folded together too. A polling pass wants the
readings, the status register and, now and then, the whole configuration; sent as
one compound SCPI message that is a single round trip instead of six. It can be
switched off in Settings ▸ Acquisition, and the loop switches it off by itself if
a meter turns out not to understand it.

The readings in a burst are stamped evenly across the time the burst took. The
meter does not stamp them itself, so this is an estimate: a good one at a steady
rate, and the only honest option. It is also why stability work wants readings
per burst set to 1 — the Stability window says so when the spacing is ragged.

## Keyboard shortcuts

| Shortcut | What it does |
| --- | --- |
| ⌘, | Settings — panel colours, the polling plan, graph appearance, logging, speech |
| ⌘O | Select serial port |
| ⇧⌘D | Disconnect |
| ⇧⌘R | Reset device |
| ⇧⌘N | Capture null offset |
| ⌥⌘R | Reset history and statistics |
| ⇧⌘T | Speak the current reading |
| ⌘S | Save the front window — readings, events, a graph or a histogram |
| ⌘K | Clear the event list |
| ⌘0 | Main window |
| ⌘1 ⌘2 | Graph, histogram |
| ⌘3 ⌘4 | Stability, new math waveform |
| ⌘W ⌘M | Close and minimise, as everywhere |
| ⇧⌘/ | General Help, which lists these too |
| ⌘Q | Quit |

In the connection window ⌘R rescans the ports, Return connects and Esc closes
it. Text fields keep the standard editing shortcuts.

The Settings window and the menus drive the same state — whichever you reach
for, the other follows.

## How it is put together

| Target | What it is |
| --- | --- |
| `DMMCore` | Serial port (POSIX termios), port enumeration (IOKit), the 34401A SCPI protocol, polling worker, controller, statistics, Allan deviation and drift, math waveforms, logging, speech. No UI. |
| `DMMSimulator` | Pseudo-terminal plus a simulated instrument. |
| `AgilentDMMKit` | All SwiftUI views, the Settings window and the menu bar. |
| `AgilentDMM` | The executable — one line, calls into the kit. |
| `agmult-sim` | Command-line simulator. |

Serial I/O never touches the main thread. The worker owns the port, runs one
polling pass per interval and hands the main actor a finished snapshot; commands
from the UI go the other way through a queue.

Two details worth knowing about the serial layer, because both are the kind of
thing that turns into a hung application:

- The port is left **non-blocking**, and `readLine` and `write` each keep their
  own deadline. `tcdrain` is never called on a live port — on a pseudo-terminal,
  or on a port whose peer has stopped listening, it blocks with no timeout at
  all. Closing uses a bounded `TIOCOUTQ` poll instead.
- A meter that has been unplugged, switched to HP-IB or claimed by another
  program does not close the port; it just stops answering. Two consecutive
  passes in which nothing at all replies, spanning at least ten seconds, end the
  session with an error rather than spinning forever while the app still calls
  itself connected.

## Notes on the instrument

- **`SYSTem:REMote` is not optional.** Over RS-232 the meter ignores the
  interface until it is told to go remote, and the manual warns that traffic in
  local mode "can cause unpredictable results". The app sends it on connect and
  `SYSTem:LOCal` on disconnect, so the front panel works again afterwards.
- **Parity and word length are coupled**: None with 8 data bits, Even or Odd with
  7. One start bit and two stop bits are fixed. The connection window offers only
  the three combinations the meter accepts.
- **Handshaking is DTR/DSR**, which Darwin's termios cannot gate on. The app
  asserts DTR when it opens the port and leaves it asserted, which is what every
  terminal program does and what the meter is waiting for. Leave flow control at
  None.
- **Overload is `+9.90000000E+37`**, not a reading. It is counted and shown as
  `OVLD`, and deliberately kept out of the graph — one point at 10³⁷ would
  flatten everything else to a line.
- The meter answers `"VOLT"` to `FUNCtion?` for DC volts, even though you select
  it with `"VOLTage:DC"`. The asymmetry is real and is handled in one place. The
  ratio is the awkward case: the manual gives the string to *send* but says only
  that the query "returns a quoted string", so every plausible abbreviation of it
  is accepted rather than one being guessed at. The ratio also has no settings of
  its own — range, integration time and auto zero are the `VOLTage:DC` ones, since
  that is the node the meter keeps them under.
- **The error queue is a queue.** One `SYSTem:ERRor?` takes one entry off it, so
  asking once after something went wrong tells you about the first failure and
  leaves the rest to surface later attached to something innocent. The app reads
  until the meter says `+0,"No error"`, and every entry goes to the event list.
- **`SYSTem:RWLock` locks the front panel properly.** Plain remote mode leaves
  the LOCAL key working, so anybody walking past can take the meter back
  mid-capture. Lockout disables every key including that one — Config ▸ Lock Out
  Front Panel, and the same button on the instrument panel. It can only be undone
  from here, which is the point of it and also the reason it is not the default.
- **Calibration count and message** are read once per session and shown on the
  model name in the status strip: how many times the meter has been adjusted and
  whatever the last person to do it typed in. Read-only — the commands that
  perform a calibration are deliberately not implemented.

## Differences from the Windows application

- **RS-232 only.** No GPIB, with or without an adapter. On this meter GPIB is
  roughly five times faster, so if you have the hardware the Windows program
  will out-run this one.
- Ports are `/dev/cu.*` device paths, not COM numbers.
- Graphs use Swift Charts rather than ScottPlot. Long histories are decimated for
  drawing with the minima and maxima preserved, so a two-million-reading graph
  stays responsive and a one-reading spike still shows; exports contain every
  retained sample. "Draw Every Point" turns the decimation off for anyone who
  would rather wait.
- Statistics use Welford's algorithm rather than a running sum of squares, which
  is what keeps the standard deviation meaningful when the readings are large and
  the spread between them is in the last two digits.
- Allan deviation and the drift fit are not in the original. Neither is the
  median filter, or the histogram source picker that lets a distribution be
  taken of a derived waveform rather than only of the raw readings.
- Log files default to `~/Documents/AgilentDMM` rather than the working
  directory.
- Speech uses AVFoundation, so it speaks in whichever system voice is selected.

## Tests

```sh
swift test
```

The suite covers SCPI spelling and parsing, status decoding, display formatting,
the sample buffer and its decimation, the statistics accumulator, the histogram,
every math-waveform transform, and the settings file — including what happens
when it was written by an older build.

Allan deviation and the drift fit are checked against series whose answers are
known in closed form: a pure linear drift gives σ(τ) = D·τ/√2 exactly, and white
noise averages down as τ^(−½) with a log-log slope of −½.

Over a real serial connection to the simulator: identification and remote mode,
all eleven functions, auto-ranging and overload, bursts up to the meter's full
512-reading memory and each trigger source,
compound messages and the read-back that retries when it was aimed at the wrong
subsystem, the CALC maths, the error queue drained to the bottom, the
calibration read-back, the front-panel lockout and reset. The ratio gets its own
set: that its range and integration time are the DC voltage ones, that it
overloads on the Input signal rather than on the quotient, and that a read-back
still tells it apart from plain DC volts. Controller tests run the whole polling loop
on the main actor, including a front-panel change being adopted, a limit trip
being logged once rather than every pass, the data logger writing to disk, a
meter that stops answering ending the session, and a direct count of the round
trips saved by combining queries.

Interface tests render the views off-screen against live simulator data; set
`AGMULT_RENDER_DIR` to write the images out:

```sh
AGMULT_RENDER_DIR=/tmp/render swift test --filter InterfaceRenderTests
```

`ImageRenderer` cannot draw AppKit-backed controls (`List`, `Form`, `TextField`,
`HSplitView`), so the main, connection and Settings windows come out partly
blank — those tests exist to evaluate every view body and binding, not to check
pixels. The readout panel, graphs, histogram, stability and help windows render
fully.

## Licence

MIT — see [LICENSE](LICENSE). Attribution for the design this project builds on
is in [CREDITS.md](CREDITS.md).
