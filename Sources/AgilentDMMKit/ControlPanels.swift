import SwiftUI
import DMMCore

/// Function keys, laid out like the top row of the meter's own front panel.
///
/// A row rather than a column: ten short labels side by side cost sixty points
/// of height, where the same ten stacked in a narrow box cost three hundred and
/// pushed everything below them off the screen.
struct FunctionBar: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 5)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(MeasurementFunction.allCases) { function in
                    Button {
                        controller.setFunction(function)
                    } label: {
                        Text(function.shortTitle)
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(controller.configuration.function == function ? .accentColor : nil)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(controller.configuration.function == function
                                  ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
                    .help(function.title)
                }
            }

            Text("\(controller.configuration.function.title) — leads in \(controller.configuration.function.terminals).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .disabled(!controller.isConnected)
    }
}

/// A row inside a control panel: label on the left, control after it, and the
/// row filling the width it was given.
///
/// Without the fill a `GroupBox` hugs its content and centres it, which on a
/// wide column leaves the controls stranded in the middle with empty margins on
/// both sides — which is exactly how the first attempt at this window looked.
private struct PanelRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A control panel: a titled box whose contents fill it.
private struct PanelBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 7) {
                content
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Range, resolution and the settings that trade speed against noise.
struct RangeBox: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }
    private var function: MeasurementFunction { controller.configuration.function }

    var body: some View {
        PanelBox(title: "Range and Resolution") {
            if function.hasSelectableRange {
                PanelRow(label: "Range") {
                    Picker("", selection: rangeSelection) {
                        Text("Auto").tag(Double(0))
                        ForEach(function.ranges, id: \.self) { range in
                            Text(Format.range(range, unit: function.rangeUnit)).tag(range)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
            } else {
                PanelRow(label: "Range") {
                    Text("Fixed — \(Format.range(function.ranges[0], unit: function.rangeUnit))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if function.usesIntegrationTime {
                PanelRow(label: "Integration") {
                    Picker("", selection: Binding(
                        get: { controller.configuration.integrationTime },
                        set: { controller.setIntegrationTime($0) }
                    )) {
                        ForEach(IntegrationTime.allCases) { time in
                            Text(time.shortTitle).tag(time)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    .help("Longer is quieter and slower. From 1 PLC up the meter also rejects mains hum.")
                }

                PanelRow(label: "Auto zero") {
                    Picker("", selection: Binding(
                        get: { controller.configuration.autoZero },
                        set: { controller.setAutoZero($0) }
                    )) {
                        ForEach(AutoZero.allCases) { mode in
                            Text(mode.shortTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 150)
                    .help("On measures the meter's own offset before every reading, which halves the rate and removes drift. Once takes a zero now and holds it.")
                }
            }

            if function.usesAperture {
                PanelRow(label: "Gate time") {
                    Picker("", selection: Binding(
                        get: { controller.configuration.gateTime },
                        set: { controller.setGateTime($0) }
                    )) {
                        ForEach(GateTime.allCases) { gate in
                            Text(gate.shortTitle).tag(gate)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
            }

            if function.usesBandwidth {
                PanelRow(label: "AC filter") {
                    Picker("", selection: Binding(
                        get: { controller.configuration.bandwidth },
                        set: { controller.setBandwidth($0) }
                    )) {
                        ForEach(ACBandwidth.allCases) { bandwidth in
                            Text(bandwidth.shortTitle).tag(bandwidth)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 150)
                    .help("The slow filter reads correctly down to 3 Hz but settles in seven seconds; the fast one is for signals well above 200 Hz.")
                }
            }

            if function.usesInputImpedance {
                Toggle("High input impedance", isOn: Binding(
                    get: { controller.configuration.highInputImpedance },
                    set: { controller.setHighInputImpedance($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("More than 10 GΩ on the 100 mV, 1 V and 10 V ranges instead of 10 MΩ, so a high-impedance source is not loaded down.")
            }
        }
        .disabled(!controller.isConnected)
    }

    /// Zero stands in for auto-ranging, so one picker covers both.
    private var rangeSelection: Binding<Double> {
        Binding(
            get: { controller.configuration.autoRange ? 0 : controller.configuration.range },
            set: { value in
                if value == 0 {
                    controller.setAutoRange(true)
                } else {
                    controller.setRange(value)
                }
            }
        )
    }
}

/// How readings are triggered and how many arrive per round trip.
struct TriggerBox: View {
    @Environment(AppModel.self) private var model

    @State private var delayText = "0"
    @State private var intervalText = "0"

    private var controller: DMMController { model.controller }

    var body: some View {
        PanelBox(title: "Triggering and Rate") {
            PanelRow(label: "Source") {
                Picker("", selection: Binding(
                    get: { controller.configuration.triggerSource },
                    set: { controller.setTriggerSource($0) }
                )) {
                    ForEach(TriggerSource.allCases) { source in
                        Text(source.shortTitle).tag(source)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .help("Bus means this application sends *TRG; External waits for the rear-panel input.")
            }

            PanelRow(label: "Trigger delay") {
                Toggle("Auto", isOn: Binding(
                    get: { controller.configuration.triggerDelayAuto },
                    set: { controller.setTriggerDelay(auto: $0, seconds: Double(delayText) ?? 0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                TextField("", text: $delayText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .disabled(controller.configuration.triggerDelayAuto)
                    .onSubmit { controller.setTriggerDelay(auto: false, seconds: Double(delayText) ?? 0) }
                Text("s").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            PanelRow(label: "Per burst") {
                Picker("", selection: Binding(
                    get: { controller.configuration.sampleCount },
                    set: { controller.setSampleCount($0) }
                )) {
                    ForEach(MeterConfiguration.sampleCountChoices, id: \.self) { count in
                        Text(String(count)).tag(count)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 80)
                .help("Readings taken on one trigger and returned in one response — the only way to a useful rate over RS-232.")
            }

            PanelRow(label: "Pause") {
                TextField("", text: $intervalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .onSubmit(applyInterval)
                Text("s").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Set", action: applyInterval)
                    .controlSize(.small)
            }
        }
        .disabled(!controller.isConnected)
        .onAppear {
            delayText = SCPI.format(controller.configuration.triggerDelay)
            intervalText = SCPI.format(controller.updateInterval)
        }
    }

    private func applyInterval() {
        guard let value = Double(intervalText), value >= 0, value <= 3600 else {
            controller.message = "Pause must be between 0 and 3600 seconds."
            return
        }
        controller.updateInterval = value
        controller.append("Pause between bursts: \(SCPI.format(value)) s")
    }
}

/// The meter's own maths.
struct MathBox: View {
    @Environment(AppModel.self) private var model

    @State private var nullText = "0"
    @State private var decibelText = "0"
    @State private var lowerText = "0"
    @State private var upperText = "1"

    private var controller: DMMController { model.controller }

    var body: some View {
        PanelBox(title: "Math") {
            PanelRow(label: "Function") {
                Picker("", selection: Binding(
                    get: { controller.math.function },
                    set: { controller.setMathFunction($0) }
                )) {
                    ForEach(MathFunction.allCases) { function in
                        Text(function.title).tag(function)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }

            switch controller.math.function {
            case .null:
                PanelRow(label: "Offset") {
                    TextField("", text: $nullText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { controller.setNullOffset(Double(nullText) ?? 0) }
                    Text(controller.configuration.function.unit)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Set") { controller.setNullOffset(Double(nullText) ?? 0) }
                        .controlSize(.small)
                    Button("Capture") { controller.captureNull() }
                        .controlSize(.small)
                        .help("Take a reading now and make it the offset, as the front-panel Null key does")
                }

            case .decibel:
                PanelRow(label: "Reference") {
                    TextField("", text: $decibelText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { controller.setDecibelReference(Double(decibelText) ?? 0) }
                    Text("dBm").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Set") { controller.setDecibelReference(Double(decibelText) ?? 0) }
                        .controlSize(.small)
                }

            case .dBm:
                PanelRow(label: "Load") {
                    Picker("", selection: Binding(
                        get: { controller.math.dBmReference },
                        set: { controller.setDBmReference($0) }
                    )) {
                        ForEach(MathConfiguration.dBmReferenceChoices, id: \.self) { ohms in
                            Text("\(Int(ohms)) Ω").tag(ohms)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110)
                }

            case .limit:
                PanelRow(label: "Low / high") {
                    TextField("", text: $lowerText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .onSubmit(applyLimits)
                    TextField("", text: $upperText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .onSubmit(applyLimits)
                    Button("Set", action: applyLimits)
                        .controlSize(.small)
                }

            case .statistics:
                instrumentStatistics

            case .none:
                EmptyView()
            }
        }
        .disabled(!controller.isConnected)
        .onAppear {
            nullText = SCPI.format(controller.math.nullOffset)
            decibelText = SCPI.format(controller.math.decibelReference)
            lowerText = SCPI.format(controller.math.lowerLimit)
            upperText = SCPI.format(controller.math.upperLimit)
        }
    }

    /// The meter's own tally, which keeps counting whether or not this
    /// application is asking for readings — not the same numbers as the panel's.
    private var instrumentStatistics: some View {
        let statistics = controller.instrumentStatistics
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 1) {
            GridRow { Text("Meter min"); Text(reading(statistics.minimum)) }
            GridRow { Text("Meter max"); Text(reading(statistics.maximum)) }
            GridRow { Text("Meter mean"); Text(reading(statistics.average)) }
            GridRow { Text("Meter count"); Text(statistics.count.map(String.init) ?? "—") }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private func reading(_ value: Double?) -> String {
        value.map { Format.engineering($0, unit: controller.displayUnit) } ?? "—"
    }

    private func applyLimits() {
        controller.setLimits(lower: Double(lowerText) ?? 0, upper: Double(upperText) ?? 0)
    }
}

/// Front-panel display, beeper, self test and the way out of a wedged interface.
struct UtilityBox: View {
    @Environment(AppModel.self) private var model
    @State private var displayText = "Hello!"
    @State private var beeperIsOn = true

    private var controller: DMMController { model.controller }

    private let buttons = [GridItem(.adaptive(minimum: 82), spacing: 5)]

    var body: some View {
        PanelBox(title: "Instrument") {
            HStack(spacing: 5) {
                TextField("Front panel message", text: $displayText)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { controller.sendDisplayText(displayText) }
                    .controlSize(.small)
                Button("Clear") { controller.clearDisplayText() }
                    .controlSize(.small)
            }

            LazyVGrid(columns: buttons, spacing: 5) {
                Button(controller.frontPanelIsOn ? "Display Off" : "Display On") {
                    controller.toggleFrontPanel()
                }
                .help("Switching the meter's display off is the single biggest speed-up it offers")
                Button("Beep") { controller.beepOnce() }
                Button(beeperIsOn ? "Beeper Off" : "Beeper On") {
                    beeperIsOn.toggle()
                    controller.setInstrumentBeeper(beeperIsOn)
                }
                Button("Self Test") { controller.runSelfTest() }
                Button("Local") { controller.returnToLocal() }
                    .help("Hand the front panel back without disconnecting")
                Button("Clear I/O") { controller.clearInterface() }
                    .help("Ctrl-C — abandons a burst the meter is still sending")
            }
            .controlSize(.small)
        }
        .disabled(!controller.isConnected)
    }
}

/// Connection facts and whatever the app most recently wanted to say, on one
/// line under the readout.
///
/// This was a panel of its own, seven rows tall, sitting in the control column
/// pushing the actual controls off the bottom of the window. None of it was a
/// control — it is all reference, and reference belongs on a strip you glance
/// at, not in a box you scroll past.
struct InstrumentStrip: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)

                Text(controller.identity?.model ?? "No meter")
                    .fontWeight(.medium)

                if let firmware = controller.identity?.firmware, !firmware.isEmpty {
                    Text(firmware).foregroundStyle(.secondary)
                }

                Text(controller.isConnected ? controller.portDisplayName : "not connected")
                    .foregroundStyle(.secondary)

                Text("\(Format.number(controller.lineFrequency, 0)) Hz")
                    .foregroundStyle(.secondary)

                Divider().frame(height: 12)

                Text(controller.errorText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Get") { controller.readError() }
                    .controlSize(.mini)
                    .disabled(!controller.isConnected)

                Spacer()

                if !controller.isConnected {
                    Button("Connect…") { model.isConnectionSheetPresented = true }
                        .controlSize(.small)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            if let banner = banner {
                Text(banner.text)
                    .font(.system(size: 11))
                    .foregroundStyle(banner.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(banner.color.opacity(0.12))
            }
        }
        .background(.bar)
    }

    /// Whatever most needs saying: a lost connection first, then anything the
    /// controller wanted to report.
    private var banner: (text: String, color: Color)? {
        if let error = controller.connectionError, !controller.isConnected {
            return (error, .red)
        }
        if !controller.message.isEmpty {
            return (controller.message, .orange)
        }
        return nil
    }
}
