# 34401A Multimeter — user guide

[Русская версия](guide.ru.md)

The application drives an HP / Agilent / Keysight **34401A** over RS-232: it
shows the reading, keeps a history, draws graphs and writes logs. This guide is
about using it. How the project is put together, and why it was built the way it
was, is in the [README](../README.md).

---

## Contents

1. [Getting started](#getting-started)
2. [Connecting the meter](#connecting-the-meter)
3. [The main window](#the-main-window)
4. [What it can measure](#what-it-can-measure)
5. [Range, resolution and speed](#range-resolution-and-speed)
6. [Triggering and bursts](#triggering-and-bursts)
7. [The meter's own maths](#the-meters-own-maths)
8. [Graphs and analysis](#graphs-and-analysis)
9. [Logging to file](#logging-to-file)
10. [Speech](#speech)
11. [Watching without the window](#watching-without-the-window)
12. [Keyboard shortcuts](#keyboard-shortcuts)
13. [When something is wrong](#when-something-is-wrong)

---

## Getting started

The instrument is optional. A full 34401A simulator is built in, and everything
works against it without exception — measurement, graphs, statistics, logs,
automation.

**Build and run:**

```sh
swift build                  # build
./Scripts/make-app.sh        # assemble AgilentDMM.app
open build/AgilentDMM.app
```

**Try it without hardware:** **Config ▸ Start Built-in Simulator**. A virtual
meter appears on a pseudo-terminal; press Connect in the connection window. The
same menu steers the simulator: what it is measuring, the modulation shape
(drift, sine, ramp, noise) and how much noise to add.

---

## Connecting the meter

### What you need

- a USB-to-RS-232 adapter;
- **a null-modem adapter or cable**.

The second is not a quibble. The 34401A's serial port is wired as DTE, and so is
the adapter at the computer, so a straight-through cable joins transmitter to
transmitter and nothing whatsoever happens.

If your meter has the pass/fail output fitted on pins 1 and 9, do not use the
RS-232 port at the same time — the instrument manual forbids it outright.

### Setting up the meter

On the front panel: **Shift ▸ Menu**, the **I/O MENU** section, then `HP-IB/232`
→ `RS-232`, followed by `BAUD RATE` and `PARITY`.

The factory settings and this application's defaults agree: **9600 baud, Even
parity, 7 data bits**. Parity and word length are linked on this meter: None goes
with 8 data bits, Even and Odd with 7. The connection window offers only the
three combinations the meter accepts. One start bit and two stop bits are fixed.

Leave flow control at **None**. The meter gates its transmitter on DSR, expecting
DTR from the host; macOS termios has no such mode, so the application simply
raises DTR when it opens the port and holds it — which is exactly what the meter
is waiting for.

### Choosing the port

**⌘O**, or **Config ▸ Select Serial Port…**. The list holds `/dev/cu.*` devices.
Take the `cu.*` one, never the matching `tty.*`: the tty device waits for carrier
detect and will appear to have hung.

Buttons in that window: **Device Info** asks the meter `*IDN?` without taking it
over; **Connect** starts a session. The port that worked last time is offered
again — press Return.

### Remote mode

Over RS-232 the meter ignores everything until it is told to go remote. The
application sends `SYSTem:REMote` on connecting and `SYSTem:LOCal` on
disconnecting, so the front panel works again afterwards.

While a session is running the front-panel keys are locked out except LOCAL.
**Config ▸ Return to Local** gives the panel back without dropping the link.
**Lock Panel** (in the Instrument box, or the menu item) goes further and sends
`SYSTem:RWLock`, disabling every key including LOCAL — for a meter in a rack that
nobody should touch. It can only be undone from here, which is the point of it.

---

## The main window

### The reading

The large number at the top, dressed as the instrument's own display. The SI
prefix comes from the **range** and the number of decimals from the
**resolution**. That is why a 6½-digit reading looks like one, and why a value
hovering around zero does not flicker between µV and mV several times a second.

To the left of the reading are the annunciators: function, range, resolution,
which maths is on, trigger source, burst size (`×20`), high-impedance input
(`HI-Z`), the meter's display switched off. To the right, `REM` (remote) and
`ERR` (something is in the status register).

### Statistics

Beside the reading: maximum, mean, minimum, peak-to-peak and σ. Computed over
everything recorded this session, **including readings that have fallen out of
the history buffer**. Welford's algorithm rather than a sum of squares:
otherwise, with large readings and the spread in the last two digits, σ stops
meaning anything.

Do not confuse it with the meter's own statistics (`Min / Max / Average` in the
Math box): those are computed inside the instrument and keep going even when the
application is not asking for readings. They are two independent counts.

### The status strip

Under the black field: the connection indicator, model, firmware version, port,
line frequency, the last entry from the error queue, and a **Get** button which
drains that queue. Hover the model name and a tooltip shows the calibration count
and the message left by whoever last adjusted the meter.

### The panels

On the left, the function keys and four boxes: **Range and Resolution**,
**Triggering and Rate**, **Math**, **Instrument**. On the right, the graph over
the readings table, with the event list on the neighbouring tab.

---

## What it can measure

Eleven functions:

| Key | What it is | Where the leads go |
| --- | --- | --- |
| DCV | DC voltage | Input HI and LO |
| RATIO | Ratio of two DC voltages | signal on Input, reference on Sense |
| ACV | AC voltage | Input HI and LO |
| DCI | DC current | Input HI and the I terminal |
| ACI | AC current | Input HI and the I terminal |
| 2W Ω | Resistance, two-wire | Input HI and LO |
| 4W Ω | Resistance, four-wire | Input HI/LO plus Sense HI/LO |
| FREQ | Frequency | Input HI and LO |
| PER | Period | Input HI and LO |
| CONT | Continuity | Input HI and LO |
| DIODE | Diode test | Input HI and LO |

**RATIO** is the odd one out. The meter divides the voltage on the Input
terminals by the reference on Sense, so the result is dimensionless — a bare
number. It has no settings of its own: range, integration time and auto zero come
from DC voltage, and the reference on Sense is always auto-ranged. The range
applies to the signal on Input, so an overload is raised on that rather than on
the quotient.

---

## Range, resolution and speed

**Range** — automatic, or set by hand. Continuity and diode run on a fixed range
which cannot be changed.

**Integration time** (PLC, power line cycles) is the main lever:

| PLC | Digits | Speed (specified, over GPIB) |
| --- | --- | --- |
| 0.02 | 4½ | ~1000 rdg/s |
| 0.2 | 5½ | ~300 |
| 1 | 6½ | ~60 |
| 10 | 6½ | ~6 |
| 100 | 6½ | ~0.6 |

From 1 PLC upwards the meter also rejects mains pickup, which is usually worth
more than the extra digit.

**Auto zero** set to On makes the meter measure its own offset before every
reading: half the speed, no drift. Off is faster and drifts with temperature.
Once measures the offset now and holds it.

**High input impedance** applies to the 100 mV, 1 V and 10 V DC ranges: the 10 MΩ
divider is replaced by an input resistance above 10 GΩ, so a high-impedance
source is not loaded down. The other ranges are always 10 MΩ.

**AC filter** (for AC functions) is the filter bandwidth: 3 Hz reads correctly
down to the lowest frequencies but takes seven seconds to settle; 200 Hz is fast
but only good for signals well above 200 Hz.

---

## Triggering and bursts

**Trigger source**: Immediate (free-running), Bus (the application sends `*TRG`),
External (the rear-panel input).

**Readings per burst** is what makes this section worth reading. Every request
over the serial line is one round trip, and at 9600 baud it costs several
milliseconds before the meter has started measuring at all. The way to go fast is
not to ask more often but to ask for more at once: the meter takes the given
number of readings from one trigger and returns them in a single answer.

The ceiling is 512, which is what the meter's internal memory holds. Past that
the following happens: the meter does not timestamp readings within a burst, the
application spreads them evenly across the burst's duration, and with very large
bursts that estimate stops being honest.

Combine it with 0.02 PLC, auto zero off and **the meter's display off** — the
last of those is the largest single speed-up the instrument offers
(**Display Off** in the Instrument box).

The questions are combined too: one polling pass needs the readings, the status
register and, now and then, the whole configuration — all of which goes out as
one compound SCPI message, one exchange instead of six. It can be switched off in
**Settings ▸ Acquisition**, and the loop switches it off by itself if the meter
did not understand it.

> **For stability work, set the burst to 1.** The Allan deviation estimate
> assumes evenly spaced readings, and bursts break that spacing. The Stability
> window says so when the spacing is ragged.

---

## The meter's own maths

Computed inside the instrument, before the reading is sent.

- **Null** subtracts an offset. **Capture** (⇧⌘N) takes the reading right now and
  makes it the offset: that is how lead resistance is compensated.
- **dBm** — power relative to a chosen load resistance.
- **dB** — the reading in dBm minus a reference level, also in dBm.
- **Min / Max / Average** — counted inside the meter, independent of the
  application's history.
- **Limit test** — bounds; leaving them raises bits in the status register, and
  the application logs it, marks it on the graph, and can beep and post a
  notification.

---

## Graphs and analysis

### Graph (⌘1)

A live strip of readings with markers for the mean, the extremes and the limits.
The X axis is the reading number or time. Drag across the field to select a
region and see its statistics; a single click clears the selection. PNG and CSV
export is ⌘S.

The curve is decimated to roughly 1400 points **with minima and maxima
preserved**, so a million-reading history draws quickly and a single spike still
shows. Exports contain every retained reading, undecimated. If you want every
point on screen, **Draw Every Point** in the graph settings — honest, and very
slow.

### Histogram (⌘2)

The distribution of the readings, which is where the last two digits of a
6½-digit reading stop being mush and turn into a shape. The source can be the
measurement or any derived waveform.

### Stability (⌘3)

**Allan deviation**, on logarithmic axes. Ordinary σ answers the wrong question
about a multi-hour record: it grows with the record, because everything drifts.
This answers the right one — how far the *mean* will move if you average for a
second, a minute, an hour.

The shape of the curve names the noise:

- falling as τ^(−½) — white noise, averaging still buys resolution;
- a flat floor — the flicker floor, averaging further is pointless;
- rising as τ — drift, and averaging is now making things worse.

The bottom of the curve is the optimum averaging time, and the window marks it.
Long τ are drawn as hollow points: overlapping differences are not independent,
and the last points of a record rest on a handful of degrees of freedom. That is
a property of the estimate, not of your meter.

Underneath is the drift rate: a least-squares line through the whole record, in
units per hour, with the r² that tells you whether it is a trend or noise. For
records shorter than a minute the hourly rate is not shown: extrapolating twenty
milliseconds to an hour gives a very precise piece of nonsense.

### Math waveforms (⌘4)

Derived series over the recorded readings: scale, moving average, median, low-pass
filter, deviation from the mean, ppm against a reference, difference, derivative,
integral, absolute value, square, reciprocal, decibels, power into a load.

A waveform's source can be the measurement **or another waveform**, so transforms
chain (**Derive From This**).

> A moving average and a median are not the same thing. A single wild reading (a
> relay clicked, a probe twitched) is smeared across the whole window by the
> average and ignored completely by the median.

---

## Logging to file

Readings are written as text or CSV, event-list entries as text. File names are
made from the date, model and port; the default folder is
`~/Documents/AgilentDMM` and can be changed. Overloads are written as `OVLD`
rather than dropped.

Switch it on in **Settings ▸ Logging** or the **Data Logger** menu.

---

## Speech

Speaks the reading on a timer or when a threshold is crossed. More useful than it
sounds: when both hands are holding probes onto a board, hearing the reading is
the only way to take it. The system voice is used. ⇧⌘T speaks the current reading
once.

---

## Watching without the window

### The menu bar

<a id="the-menu-bar"></a>

The application puts an item in the **macOS menu bar** — the one along the top of
the screen. Look for it on the **right**, among the other status items: near the
clock, the battery, Wi-Fi. It is a small waveform icon with the current reading
beside it, for example `4.19187 V`. With no meter connected there is a dash
instead.

It updates twice a second. More often is pointless: at twenty readings a second
the number in a menu bar cannot be read, and the width of the item would twitch
on every digit, dragging its neighbours along with it.

Clicking it opens a menu: the model and current function, the reading, maximum,
mean, minimum, σ, the reading count and rate, and below that the ways back to the
main window and the graph, "speak the reading", and connect or disconnect.

It is switched off in **Settings ▸ General ▸ Menu Bar**.

**Cannot find it?** That happens, and it is not always a fault. This application
has a very long menu bar of its own (Config, Function, Measurement, Math, Graphs,
Data Logger, List, Speech plus the system ones), and on a Mac with a notch macOS
silently hides the status items that no longer fit. Switch to the Finder — its
menus are short, the room appears and so does the item. If you have a lot of
status items in general, utilities such as Ice or Bartender help.

### Notifications

Banners for three events:

| Event | When it arrives |
| --- | --- |
| Limit tripped | The reading left the band set in Math ▸ Limit test |
| Overload | The input went past full scale on the range in use |
| Connection lost | The meter stopped answering; the session has ended |

Each is switched on separately in **Settings ▸ General ▸ Alerts** — they are
different sorts of event. A limit trip is the thing you set up and walked away
from; an overload usually means you are holding a probe somewhere; a lost
connection ends a recording that has been running for hours.

Notifications are **off** by default: permission to interrupt you is earned, not
asked for on first launch. Switching them on is the moment the system asks. Also
by default banners appear only when another application is in front: a banner
over the window that says the same thing in large digits is noise, not news.

An overload notifies **on entering** it rather than every second while it lasts:
a probe on a live board can sit in overload for minutes.

### Shortcuts and automation

The application publishes four actions to Shortcuts, Spotlight and Siri:

| Action | What it gives back |
| --- | --- |
| Take a Reading | The latest reading, as a number |
| Read Statistics | Mean, minimum, maximum, σ, peak-to-peak or count |
| Set Measurement Function | Switches the meter, any of the eleven functions |
| Reset History and Statistics | Starts a run over |

That is how a bench instrument becomes something a script can ask a question of:
read a voltage after each step of a soak test and write it into a spreadsheet;
watch a reference warm up and stop when it settles; take a reading every time a
build finishes.

All four work on the **running** application — the serial port is open in that
one process and cannot be shared — so an action that arrives while the app is
closed launches it, and one that arrives with no meter connected says so honestly
instead of inventing a number.

> The actions only appear in a build made on a machine with a full Xcode.
> Shortcuts finds them through a metadata bundle that `Scripts/make-app.sh`
> generates; without Xcode the script says plainly that it skipped that step.

---

## Keyboard shortcuts

| Shortcut | What it does |
| --- | --- |
| ⌘, | Settings |
| ⌘O | Select serial port |
| ⇧⌘D | Disconnect |
| ⇧⌘R | Reset the meter |
| ⇧⌘N | Capture the Null offset |
| ⌥⌘R | Reset history and statistics |
| ⇧⌘T | Speak the reading |
| ⌘S | Save the front window |
| ⌘K | Clear the event list |
| ⌘0 | Main window |
| ⌘1 / ⌘2 | Graph / histogram |
| ⌘3 / ⌘4 | Stability / new math waveform |
| ⇧⌘/ | General help |
| ⌘W / ⌘M | Close / minimise |
| ⌘Q | Quit |

In the connection window: ⌘R rescans the ports, Return connects, Esc closes it.

---

## When something is wrong

**Nothing answers.** Check the null-modem adapter — it is reason number one.
Then: the I/O menu is set to RS-232 rather than HP-IB; the baud rate and parity
match; no other program is holding the port; you picked `cu.*` and not `tty.*`.

**It was answering and stopped.** Most likely the meter is halfway through a
burst nobody collected. **Config ▸ Clear Interface** sends the Ctrl-C that clears
it.

**Readings come in slowly.** See [bursts](#triggering-and-bursts). The most
effective moves: raise Readings per burst, lower the PLC, switch auto zero off
and switch the meter's display off.

**`OVLD` instead of a number.** The input is past full scale on the range in use.
Turn auto-range on or pick a larger range by hand. Overloads are counted and
logged but kept off the graph: one point of 10³⁷ would flatten everything else
into a line.

**The meter ignores its front panel after the app has run.** It has been left in
remote. **Config ▸ Return to Local**, and if the panel was locked, release it
with **Unlock Panel**.

**An unfamiliar error in the log.** Press **Get** beside the error text: the
queue is read to the end and every entry lands in the event list.

**The menu bar item is missing.** See [above](#the-menu-bar).
