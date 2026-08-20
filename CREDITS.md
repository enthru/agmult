# Credits

## Basis and inspiration

This application was built on the groundwork of

> **HP Agilent Keysight 34401A Control and Data Logging Software** by Nirav
> Patel (Niravk1997) —
> <https://github.com/Niravk1997/HP-Agilent-Keysight-34401A-Control-and-Data-Logging-Software>

a Windows application in C#. It served as the reference for what a good control
program for this meter should do: the measurement table, the interactive
graphing module with statistics over a selected region, math waveforms built
from captured samples and from other math waveforms, histograms, the organised
data logger, and the speech synthesiser that reads measurements out loud.
Credit for that design is his, and it is the reason this project had a clear
target to aim at from the first line.

## What this project is

An independent macOS implementation, written from scratch in Swift and SwiftUI.
No source code from the original was copied or translated — the two programs
share no lines, no types and no architecture. The serial layer, port
enumeration, threading model, graphing, instrument simulator, test suite and
application packaging are all original work here.

The instrument protocol is public: SCPI is an open standard (SCPI-1994,
IEEE 488.2), and the command set, status-register bit assignments and response
formats used here are documented in the *Agilent 34401A User's Guide*. Nothing
about talking to this meter is proprietary to any one implementation.

## Differences in scope

The Windows original also speaks GPIB, through an AR488 Arduino adapter or a
VISA-based interface such as the Keysight 82357B. This application is RS-232
only. That is a real limitation and worth stating plainly: GPIB is roughly five
times faster on this meter, and if you have the hardware for it, the Windows
program will out-run this one.

## Libraries

The Windows original drew its graphs with
[ScottPlot](https://github.com/swharden/scottplot) by Scott Harden. This project
uses Apple's Swift Charts and does not bundle or link ScottPlot.

This package has no third-party dependencies. The serial layer is built directly
on POSIX `termios` and IOKit; speech uses AVFoundation.

## Instrument

Supports the HP / Agilent / Keysight 34401A 6½-digit multimeter over its RS-232
interface.
