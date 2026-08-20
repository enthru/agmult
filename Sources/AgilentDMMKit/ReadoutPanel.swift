import SwiftUI
import DMMCore

/// The instrument-style readout across the top of the window: annunciators, the
/// reading itself at the size the meter's own display would show it, and the
/// running statistics underneath.
struct ReadoutPanel: View {
    @Environment(AppModel.self) private var model

    private var controller: DMMController { model.controller }
    private var textColor: Color { model.panelTextColor.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            annunciators

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                if controller.latestReading == nil && !controller.isOverloaded {
                    Text(controller.isConnected ? "waiting for a reading" : "no meter connected")
                        .font(.system(size: 26, weight: .regular, design: .rounded))
                        .foregroundStyle(textColor.opacity(0.4))
                } else {
                    Text(controller.formattedReading)
                        .font(.system(size: 64, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(controller.isOverloaded ? Color.red : textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                }

                Spacer(minLength: 0)

                statisticsBlock
            }
            .frame(height: 72, alignment: .center)

            statusLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.panelBackground.color)
    }

    // MARK: - Annunciators

    private var annunciators: some View {
        HStack(spacing: 8) {
            annunciator(controller.configuration.function.shortTitle, active: true)
            annunciator(rangeLabel, active: true)
            annunciator(resolutionLabel, active: true)

            if let math = controller.math.function.annunciator {
                annunciator(math, active: true)
            }
            if controller.configuration.triggerSource != .immediate {
                annunciator(controller.configuration.triggerSource.rawValue, active: true)
            }
            if controller.configuration.sampleCount > 1 {
                annunciator("×\(controller.configuration.sampleCount)", active: true)
            }
            if controller.configuration.function.usesInputImpedance && controller.configuration.highInputImpedance {
                annunciator("HI-Z", active: true)
            }
            if !controller.frontPanelIsOn {
                annunciator("DISP OFF", active: true)
            }

            Spacer()

            annunciator("REM", active: controller.isConnected)
            annunciator("ERR", active: controller.questionableIsKnown && !controller.questionable.isClear)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
    }

    private func annunciator(_ text: String, active: Bool) -> some View {
        Text(text)
            .foregroundStyle(active ? textColor : textColor.opacity(0.25))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(textColor.opacity(active ? 0.5 : 0.15), lineWidth: 1)
            )
    }

    private var rangeLabel: String {
        let configuration = controller.configuration
        guard configuration.function.hasSelectableRange else { return "FIXED" }
        let range = Format.range(configuration.range, unit: configuration.function.rangeUnit)
        return configuration.autoRange ? "AUTO \(range)" : range
    }

    private var resolutionLabel: String {
        let configuration = controller.configuration
        if configuration.function.usesAperture {
            return "\(Format.number(configuration.gateTime.rawValue * 1000, 0)) ms"
        }
        if configuration.function.usesIntegrationTime {
            let plc = configuration.integrationTime.rawValue
            return plc < 1 ? "\(plc) PLC" : "\(Int(plc)) PLC"
        }
        if configuration.function.usesBandwidth {
            return "\(configuration.bandwidth.rawValue) Hz"
        }
        return "\(configuration.digits)½"
    }

    // MARK: - Statistics

    private var statisticsBlock: some View {
        let statistics = controller.statistics
        return Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 1) {
            GridRow {
                label("Max"); value(statistics.isEmpty ? nil : statistics.maximum)
            }
            GridRow {
                label("Mean"); value(statistics.isEmpty ? nil : statistics.mean)
            }
            GridRow {
                label("Min"); value(statistics.isEmpty ? nil : statistics.minimum)
            }
            GridRow {
                label("Pk-Pk"); value(statistics.isEmpty ? nil : statistics.peakToPeak)
            }
            GridRow {
                label("σ"); value(statistics.isEmpty ? nil : statistics.standardDeviation)
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(textColor.opacity(0.55))
    }

    private func value(_ number: Double?) -> some View {
        Text(number.map { Format.engineering($0, unit: controller.displayUnit) } ?? "—")
            .foregroundStyle(textColor)
            .monospacedDigit()
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 16) {
            Text("\(controller.readingCount) readings")
            Text("\(Format.number(controller.measuredRate, 1)) rdg/s")
            if controller.overloadCount > 0 {
                Text("\(controller.overloadCount) overload\(controller.overloadCount == 1 ? "" : "s")")
                    .foregroundStyle(.red)
            }
            if controller.questionableIsKnown && !controller.questionable.isClear {
                Text(controller.questionable.labels.joined(separator: " · "))
                    .foregroundStyle(.red)
            }
            Spacer()
            if let moment = controller.latestReadingTime {
                Text(DateFormatter.tableTimestamp.string(from: moment))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(textColor.opacity(0.7))
    }
}
