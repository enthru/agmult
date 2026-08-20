import SwiftUI

struct SerialHelpView: View {
    var body: some View {
        HelpScroll(title: "Serial Connection Help") {
            HelpSection("What you need") {
                Text("A USB-to-RS-232 adapter, plus a null-modem adapter or cable. The 34401A's serial port is wired as a DTE, exactly like the Mac's adapter, so a straight-through cable connects transmit to transmit and nothing happens.")
                Text("34401A serial port  →  null modem adapter/cable  →  RS-232 cable  →  USB adapter  →  Mac")
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("If the meter is fitted with the pass/fail output on pins 1 and 9, do not use the RS-232 port at the same time — the manual is explicit about that one.")
            }

            HelpSection("Drivers and device names") {
                Text("macOS ships drivers for FTDI and Apple's own CDC-ACM class. Prolific PL2303 and WCH CH340 adapters usually need the vendor's driver. Once the driver is loaded the adapter shows up as a callout device such as /dev/cu.usbserial-1410 — that is what this application connects to.")
                Text("Use the cu.* device, never the matching tty.* one: the tty device waits for carrier detect and will appear to hang.")
            }

            HelpSection("Port settings") {
                Text("Both sides must agree. The meter's factory configuration, and this application's default, is:")
                Text("9600 baud · Even parity · 7 data bits · 2 stop bits · flow control None")
                    .font(.system(size: 12, design: .monospaced))
                Text("Parity and word length are not independent on this meter: None goes with 8 data bits, Even and Odd with 7. The connection window offers only the three combinations it accepts. One start bit and two stop bits are fixed and cannot be changed.")
                Text("Set it from the front panel: Shift ▸ Menu, I/O MENU, then HP-IB/232 ▸ RS-232, BAUD RATE and PARITY.")
            }

            HelpSection("Remote and local") {
                Text("Over RS-232 the meter must be told to go into remote mode before it will behave. This application sends SYSTem:REMote as soon as it connects, and SYSTem:LOCal when it disconnects, so the front panel works again afterwards.")
                Text("While the app is connected the meter's front-panel keys are locked out except LOCAL. Config ▸ Return to Local hands them back without dropping the connection.")
            }

            HelpSection("Handshaking") {
                Text("The 34401A gates its transmitter on DSR, which it expects to see driven from the host's DTR. macOS termios has no DTR/DSR flow-control mode, so this application simply asserts DTR when it opens the port and leaves it asserted — which is what every terminal program does, and what the meter is waiting for. Leave flow control set to None.")
            }

            HelpSection("If nothing answers") {
                Text("Check the null-modem adapter first. Then confirm the I/O menu is set to RS-232 rather than HP-IB, that the baud rate and parity match, and that no other program is holding the port open.")
                Text("If the meter answered once and then stopped, it is probably part way through sending a burst nobody collected: Config ▸ Clear Interface sends the Ctrl-C that clears it.")
                Text("No hardware to hand? Config ▸ Start Built-in Simulator creates a virtual 34401A on a pseudo-terminal, and every part of the application works against it.")
            }
        }
    }
}

struct GeneralHelpView: View {
    var body: some View {
        HelpScroll(title: "General Help") {
            HelpSection("Keyboard shortcuts") {
                ShortcutTable(rows: [
                    .init(keys: "\u{2318},", meaning: "Settings"),
                    .init(keys: "\u{2318}O", meaning: "Select serial port"),
                    .init(keys: "\u{21E7}\u{2318}D", meaning: "Disconnect"),
                    .init(keys: "\u{21E7}\u{2318}R", meaning: "Reset device"),
                    .init(keys: "\u{21E7}\u{2318}N", meaning: "Capture null offset"),
                    .init(keys: "\u{2325}\u{2318}R", meaning: "Reset history and statistics"),
                    .init(keys: "\u{21E7}\u{2318}T", meaning: "Speak the current reading"),
                    .init(keys: "\u{2318}S", meaning: "Save the front window \u{2014} readings, events, a graph or a histogram"),
                    .init(keys: "\u{2318}K", meaning: "Clear the event list"),
                    .init(keys: "\u{2318}0", meaning: "Main window"),
                    .init(keys: "\u{2318}1  \u{2318}2", meaning: "Graph, histogram"),
                    .init(keys: "\u{2318}3  \u{2318}4", meaning: "Stability, new math waveform"),
                    .init(keys: "\u{2318}W  \u{2318}M", meaning: "Close and minimise the front window"),
                    .init(keys: "\u{21E7}\u{2318}/", meaning: "This help"),
                    .init(keys: "\u{2318}Q", meaning: "Quit"),
                ])
                Text("In the connection window: \u{2318}R rescans the ports, Return connects, Esc closes.")
            }

            HelpSection("Getting a useful reading rate") {
                Text("Every query is one serial round trip, and at 9600 baud a round trip costs a few milliseconds before the meter has even started measuring. The way to a high rate is not to ask more often but to ask for more at once.")
                Text("Readings per burst sets SAMPle:COUNt: the meter takes that many readings on one trigger and returns them all in one response. Fifty readings per burst at 0.02 PLC with auto zero off and the meter's display switched off is where the interesting numbers are.")
                Text("The questions themselves are also folded together. A polling pass asks for the readings, the status register and, now and then, the whole configuration; sent as one compound SCPI message that is a single round trip instead of six. It can be switched off in Settings ▸ Acquisition, and the loop switches it off by itself if a meter turns out not to understand it.")
                Text("The readings in a burst are stamped evenly across the time the burst took. The meter does not stamp them itself, so this is an estimate — a good one at a steady rate, and the only honest option.")
            }

            HelpSection("Function, range and resolution") {
                Text("Integration time is the big lever: 0.02 PLC gives 4½ digits and around a thousand readings a second on paper, 100 PLC gives 6½ digits and rather less than one. At 1 PLC and above the meter also rejects mains hum, which is usually worth more than the extra digit.")
                Text("Auto zero on takes a second measurement of the meter's own offset before every reading, which halves the rate and removes drift. Off is faster and drifts with temperature; Once takes a zero now and holds it.")
                Text("High input impedance applies to the 100 mV, 1 V and 10 V DC ranges: it swaps the 10 MΩ divider for more than 10 GΩ, so a high-impedance source is not loaded down. The other ranges are always 10 MΩ.")
            }

            HelpSection("Math") {
                Text("Null subtracts an offset — Capture takes a reading now and uses it, which is how you cancel out lead resistance. dBm is referred to a load resistance; dB is the reading in dBm less a reference level, also in dBm.")
                Text("Min / Max / Average runs inside the meter and keeps counting whether or not this app is asking for readings. The statistics in the readout panel are this app's own, over the history it has collected, and are not the same tally.")
                Text("Limit test flags readings outside a window in the meter's questionable status register; this app logs the failure, marks the graph and can beep.")
            }

            HelpSection("Graphs, histograms and math waveforms") {
                Text("The graph draws the reading history, decimated to about 1400 points with minima and maxima preserved so a one-reading spike still shows. Drag across the plot to select a region and see its statistics; click once to clear.")
                Text("The histogram shows the distribution — which is where the last two digits of a 6½-digit reading stop being a blur and turn into a shape.")
                Text("A math waveform is a transform over the captured readings: moving average, median, low-pass, derivative, integral, dB, power into a load, and a few more. Its source can be the measurement or another waveform, so transforms chain. Derive From This makes the chain one step longer.")
                Text("Moving average and median are not interchangeable. A single wild reading — a relay settling, a probe bouncing — is smeared across the whole window by a mean and ignored entirely by a median.")
            }

            HelpSection("Stability — Allan deviation and drift") {
                Text("The standard deviation in the readout panel answers the wrong question about a record that lasts hours: it grows with the record, because everything drifts. The Stability window answers the right one — how much the average moves if you average for a second, for a minute, for an hour.")
                Text("The shape of the curve names the noise. Falling as τ^(−½) is white noise and averaging is still buying you resolution. Flat is the flicker floor and averaging has stopped helping. Rising as τ is drift, and averaging longer is now making the answer worse. The bottom of the curve is how long it is worth averaging for, and the window marks it.")
                Text("The long averaging times are drawn as hollow points. Overlapping differences are not independent, so only about N/2m of them carry new information: the last point of any record is built from a handful of degrees of freedom and scatters by tens of percent. That is a property of the estimator, not of your instrument.")
                Text("The estimator assumes evenly spaced readings. Readings per burst breaks that assumption — the meter does not stamp them, so they are spread evenly across the burst while the gap between bursts is much larger. For stability work, set readings per burst to 1 and let the interval do the pacing. The window says so when the spacing is ragged.")
                Text("Underneath is the drift rate: a least-squares line through the whole record, in units per hour, with the r² that says whether it is a trend or just noise. Below a minute of record no hourly rate is offered, because extrapolating twenty milliseconds to an hour produces a very precise nonsense.")
            }

            HelpSection("Settings are remembered") {
                Text("Panel colours, graph appearance, the polling plan, the meter and math configuration, history size, logging, speech and the port that worked last time are all saved and restored. Nothing is sent to the meter at launch — the restored configuration goes down when you connect.")
            }

            HelpSection("Data logger") {
                Text("Readings can be written as text or CSV, and every event-list entry as text. Files are named by date, model and port and go to the chosen folder (~/Documents/AgilentDMM by default). Overloads are logged as OVLD rather than dropped.")
            }

            HelpSection("Speech") {
                Text("Spoken readings, on a timer or when a threshold is crossed. More useful than it sounds: when both hands are holding probes onto a board, hearing the reading is the only way to take it.")
            }

            HelpSection("Watching without the window") {
                Text("The menu bar item shows the live reading next to a small waveform icon, at the right-hand end of the menu bar with the other status items — the clock, the battery, Wi-Fi. It updates twice a second, which is as fast as a number in a menu bar can be read, and shows a dash when no meter is connected. Click it for the statistics and the way back here. Settings ▸ General turns it off.")
                Text("If you cannot find it: this application has a long menu bar of its own, and on a Mac with a notch macOS silently hides the status items that no longer fit. Switch to the Finder for a moment — its menus are short — and the item has room to appear.")
                Text("Notification banners cover three events: a limit test tripping, the input going past full scale, and the meter ceasing to answer. Each can be switched on separately in Settings ▸ General, and they are off until asked for. By default they appear only while another application is in front, since a banner over the window that already says the same thing is noise.")
            }

            HelpSection("Shortcuts and automation") {
                Text("Four actions are published to Shortcuts, Spotlight and Siri: Take a Reading, Read Statistics, Set Measurement Function and Reset History. A shortcut can read a voltage after each step of a soak test and write it into a spreadsheet, or watch a reference warm up and stop when it settles.")
                Text("They work on the running application — the serial port is open in this one process and cannot be shared — so an action that arrives while the app is closed launches it, and one that arrives with no meter connected says so rather than inventing a number.")
                Text("The actions appear only in a build made with a full Xcode installed. Shortcuts finds them through a metadata bundle that Scripts/make-app.sh generates; without Xcode the script says it skipped that step.")
            }

            HelpSection("The instrument itself") {
                Text("DC Voltage Ratio is the eleventh function and the odd one out: it divides the signal on the Input terminals by a reference on Sense, so it reads as a bare number with no unit. It has no settings of its own — range, integration time and auto zero are the DC voltage ones, and the reference is always auto-ranged.")
                Text("Lock Panel sends SYSTem:RWLock, which disables every front-panel key including LOCAL. Worth having for a meter in a rack that nobody should touch; it can only be undone from here, which is the point of it.")
                Text("Get, beside the error text, empties the meter's error queue rather than taking one entry off it. The queue is a queue: asking once tells you about the first failure and leaves the rest to surface later attached to something innocent.")
                Text("The calibration count and message are read once per session — hover the model name in the status strip. They say how many times the meter has been adjusted and what the last person to do it wrote down. Read-only: the commands that perform a calibration are deliberately not implemented.")
            }
        }
    }
}

struct CreditsView: View {
    var body: some View {
        HelpScroll(title: "Credits") {
            HelpSection("This macOS version") {
                Text("A native SwiftUI application for macOS, with a serial layer built directly on POSIX termios and graphs drawn with Swift Charts. No third-party dependencies.")
            }
            HelpSection("Original Windows application") {
                Text("HP Agilent Keysight 34401A Control and Data Logging Software by Nirav Patel (Niravk1997), which set out what a program of this kind should do: the measurement table, the interactive graphs, math waveforms and histograms, the data logger and the speech synthesiser.")
                Link("github.com/Niravk1997/HP-Agilent-Keysight-34401A-Control-and-Data-Logging-Software",
                     destination: URL(string: "https://github.com/Niravk1997/HP-Agilent-Keysight-34401A-Control-and-Data-Logging-Software")!)
            }
            HelpSection("Graphing") {
                Text("The Windows original drew its graphs with the ScottPlot library by Scott Harden. This application uses Apple's Swift Charts instead, so ScottPlot is not bundled — but the graphs it inspired are.")
            }
            HelpSection("Protocol") {
                Text("SCPI is an open standard. The command set, status-register bits and response formats used here are documented in the Agilent 34401A User's Guide.")
            }
        }
    }
}

// MARK: - Layout helpers

private struct HelpScroll<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2).bold()
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 580, minHeight: 480)
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ShortcutTable: View {
    struct Row: Identifiable {
        let keys: String
        let meaning: String
        var id: String { keys }
    }

    let rows: [Row]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.keys)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 110, alignment: .leading)
                    Text(row.meaning)
                }
            }
        }
    }
}
