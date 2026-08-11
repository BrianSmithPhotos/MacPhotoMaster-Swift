import SwiftUI
import MacPhotoMasterCore

/// The in-camera look drawn over the preview's trailing edge (docs/SPEC.md "Ideas, not started").
///
/// The camera shows its creative-dial state graphically — a hue wheel with the dialled values around
/// it — and `CameraLookParsing` already recovers every reading. This draws them, so a look is
/// readable at a glance instead of parsed out of a sentence.
///
/// Groups follow the SPEC's own six: identity, the mutually-exclusive colour-rendering graphic (the
/// hero), tonal response, sliders, finish, and provenance. Which graphic to draw is
/// `CameraLookRendering`'s decision, not this view's.
struct CameraLookStripView: View {
    let look: CameraLook?

    /// Suppresses the look outright, and is not merely an empty-state hint.
    ///
    /// A RAW is not simply missing the look — it carries most of it, and drawing that would be a
    /// lie. Measured on a real pair (H1071885.JPG / .ORF, 2026-08-09): the two files differ in
    /// exactly one tag. `PictureMode` reverts to `"Natural"` in the ORF, which is the camera keeping
    /// the RAW at the neutral mode-dial value, but every *parameter* tag rides along unchanged —
    /// `ColorCreatorEffect` reads `"Color 0; 0; 29; Strength -1; -4; 3"` byte-for-byte in both. So
    /// `CameraLookParsing` legitimately returns a look for an ORF, with the readings of a rendering
    /// that file never received; Apple's pipeline does not read Olympus maker notes, which is
    /// exactly why an ORF develops as Natural.
    let isRawFile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isRawFile {
                rawState
            } else if let look {
                Text(look.mode)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                CameraLookRingView(rendering: CameraLookRendering.rendering(for: look))
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)

                readings(for: look)
            } else {
                emptyState
            }
        }
        .padding(12)
        .frame(width: 220)
        .background {
            // The material alone does not read as translucent on macOS 27: vibrancy over in-window
            // content is broken OS-wide in this beta (panes render opaque to anything sliding under
            // them), and the preview image is exactly that. `.opacity` composites with real alpha
            // rather than going through vibrancy, so the photo shows through today, and the blur
            // comes back on its own once the OS is fixed.
            RoundedRectangle(cornerRadius: 10)
                .fill(.thinMaterial)
                .opacity(0.72)
        }
        .accessibilityIdentifier("cameraLookStrip")
    }

    private var rawState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Neutral rendered RAW")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "The camera holds the RAW at the neutral mode-dial value, and Apple's engine does not read Olympus maker notes. The sibling JPEG carries the look."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No camera look")
                .font(.headline)
            Text("Shot with nothing dialled in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Groups 3-5. Group 3 is a graphic where there is a curve to draw and rows where there is not.
    @ViewBuilder
    private func readings(for look: CameraLook) -> some View {
        let curve = CameraLookToneComposite.curve(for: look)
        let tonal = tonalRows(look, hasCurve: curve != nil)
        let sliders = sliderRows(look, hasCurve: curve != nil)
        let finish = finishRows(look)

        if let curve {
            group("Tone", tonal) {
                CameraLookCurveView(curve: curve, values: curveValues(look))
            }
        } else if !tonal.isEmpty {
            group("Tone", tonal)
        }
        if !sliders.isEmpty { group("Sliders", sliders) }
        if !finish.isEmpty { group("Finish", finish) }
    }

    private func group<Content: View>(
        _ title: String,
        _ rows: [(String, String)],
        @ViewBuilder content: () -> Content = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(row.1)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    /// The tonal readings the curve cannot carry. With a curve drawn that is only what it does not
    /// express — the dialled values move onto the curve itself, revealed on hover (docs/SPEC.md
    /// group 3: "the curve is the result; the values are what you dial").
    private func tonalRows(_ look: CameraLook, hasCurve: Bool) -> [(String, String)] {
        var rows: [(String, String)] = []
        if !hasCurve {
            for level in look.toneLevels { rows.append((toneName(level.code), signed(level.value))) }
            if let gradation = look.gradation { rows.append(("Gradation", gradation)) }
        }
        if look.gradationIsAuto { rows.append(("Gradation", "auto-override")) }
        if let effect = look.pictureModeEffect { rows.append(("Effect", effect)) }
        return rows
    }

    /// Contrast is missing here whenever the curve carries it: it was measured as a stage of the
    /// tone rendering, not a slider alongside it, so it moved into group 3 (docs/SPEC.md). It comes
    /// back only when the camera ignored it, where the point is that the number in the file is not
    /// what the photograph got.
    private func sliderRows(_ look: CameraLook, hasCurve: Bool) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let contrast = look.contrast {
            if CameraLookToneComposite.contrastIsSuppressed(look) {
                rows.append(("Contrast", "\(signed(contrast)) unused"))
            } else if !hasCurve {
                rows.append(("Contrast", signed(contrast)))
            }
        }
        if let sharpness = look.sharpness { rows.append(("Sharpness", signed(sharpness))) }
        if let saturation = look.saturation { rows.append(("Saturation", signed(saturation))) }
        return rows
    }

    /// What to set on the camera to get this curve again, in the camera's own menu order.
    ///
    /// Every control that feeds the curve is listed, including the ones sitting at zero. Showing only
    /// what moved would make this a description of the curve, and it is meant to be a dial-in list:
    /// reproducing a look means knowing the settings that have to be *left* alone as much as the ones
    /// that have to be changed.
    ///
    /// The zeros have to be reconstructed here rather than read off the look, because the parser
    /// drops them — a `CameraLook` carries what the photographer *changed*, which is what every other
    /// row in this strip wants. Listing all four unconditionally is safe rather than a guess: all 154
    /// distinct maker-note signatures in `CameraLookFixture.json` carry all three tone dials and a
    /// contrast field, so there is no Picture Mode here that lacks one.
    private func curveValues(_ look: CameraLook) -> [(String, String)] {
        var values: [(String, String)] = []
        for code in ["HL", "Mid", "SH"] {
            let level = look.toneLevels.first(where: { $0.code == code })?.value ?? 0
            values.append((toneName(code), signed(level)))
        }
        if let gradation = look.gradation { values.append(("Gradation", gradation)) }
        if !CameraLookToneComposite.contrastIsSuppressed(look) {
            values.append(("Contrast", signed(look.contrast ?? 0)))
        }
        return values
    }

    private func finishRows(_ look: CameraLook) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let grain = look.grain { rows.append(("Grain", grain)) }
        if let shading = look.shading { rows.append(("Shading", signed(shading))) }
        for case .effect(let name) in look.artEffects { rows.append((name, "on")) }
        return rows
    }

    private func toneName(_ code: String) -> String {
        switch code {
        case "HL": return "Highlights"
        case "SH": return "Shadows"
        case "Mid": return "Midtones"
        default: return code
        }
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}

/// Group 3: the tone response the frame was actually rendered with, drawn as one curve.
///
/// One composite curve rather than the camera's own two-control split, because that split shows what
/// was dialled in and this overlay is for what came out (docs/SPEC.md group 3). The dialled values
/// are the other half of the question — wanting this look again means needing the numbers — so they
/// ride along on hover rather than being printed permanently over a 196pt square.
///
/// Every level plotted is measured; `CameraLookToneComposite` has the provenance and the composition
/// rules. The curve is drawn against the identity diagonal, which is what makes a bend legible at
/// this size: without it a 30-level lift near white is just a slightly bent line.
private struct CameraLookCurveView: View {
    let curve: [Double]
    let values: [(String, String)]

    @State private var showsValues = false

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        // Half the plot's width, centred. The list is short rows of a word and a number, so at full
        // width it reads as a gap with text at either edge; pulling it in makes it one block and
        // leaves more of the curve visible either side of it.
        .overlay {
            if showsValues && !values.isEmpty {
                GeometryReader { proxy in
                    valueList
                        .frame(width: proxy.size.width / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { showsValues = $0 }
        // Hover does not exist on iPad, so one tap is the same reveal. A single recognizer over the
        // whole square, because stacked ones here would fight each other for the same hit area.
        .onTapGesture { showsValues.toggle() }
        .accessibilityIdentifier("cameraLookCurve")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)

        context.stroke(
            Path(roundedRect: plot, cornerRadius: 3), with: .color(.secondary.opacity(0.35)),
            lineWidth: 1)

        for fraction in [0.25, 0.5, 0.75] {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX + plot.width * fraction, y: plot.minY))
            line.addLine(to: CGPoint(x: plot.minX + plot.width * fraction, y: plot.maxY))
            line.move(to: CGPoint(x: plot.minX, y: plot.minY + plot.height * fraction))
            line.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + plot.height * fraction))
            context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
        }

        var identity = Path()
        identity.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        identity.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        context.stroke(
            identity, with: .color(.secondary.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // Shading the gap to the diagonal is what shows the *direction* of the bend at a glance —
        // a lift and a drop of the same size are otherwise near-identical shapes at this scale.
        var area = Path()
        area.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for input in 0...255 { area.addLine(to: point(input, plot)) }
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        area.closeSubpath()
        context.fill(area, with: .color(.accentColor.opacity(0.18)))

        var line = Path()
        line.move(to: point(0, plot))
        for input in 1...255 { line.addLine(to: point(input, plot)) }
        context.stroke(line, with: .color(.accentColor), lineWidth: 1.8)
    }

    /// Level space is 0-255 on both axes, with output growing upwards.
    private func point(_ input: Int, _ plot: CGRect) -> CGPoint {
        CGPoint(
            x: plot.minX + plot.width * CGFloat(input) / 255,
            y: plot.maxY - plot.height * CGFloat(curve[input]) / 255)
    }

    private var valueList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(values, id: \.0) { value in
                HStack(spacing: 6) {
                    Text(value.0).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(value.1).monospacedDigit()
                }
            }
        }
        .font(.caption2)
        .padding(6)
        // Translucent so the curve stays readable underneath — the values answer "what do I dial",
        // and losing sight of the shape they produced while reading them defeats the point. Material
        // plus `.opacity` rather than material alone, for the same reason as the strip's own
        // background: on macOS 27 beta vibrancy does not composite against in-window content.
        .background(RoundedRectangle(cornerRadius: 5).fill(.thinMaterial).opacity(0.78))
    }
}

/// The hero graphic: one hue circle, with the measured stop positions marked.
///
/// All three rings share this geometry — that is what makes them one component rather than three —
/// but they do *not* share arity, and that is what the switch below is for. The Colour Profile
/// wheel is twelve simultaneous magnitudes, one per spoke; Partial Color and Colour Creator are each
/// a single selected stop. So the circle takes one of two value renderers rather than being
/// parameterised by stop count alone.
///
/// Angles are `CameraLookGeometry`'s measured hues, drawn with hue 0 at 3 o'clock and increasing
/// anticlockwise — the standard colour-wheel convention, and the one the measurements were taken in.
private struct CameraLookRingView: View {
    let rendering: CameraLookRendering

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The margin holds the spoke labels, which sit outside the ring so they clear the bars.
            let outer = min(size.width, size.height) / 2 - 16

            switch rendering {
            case .profileSpokes(let sliders):
                let readings = CameraLookGeometry.spokeReadings(sliders)
                let area = profileAreaPath(center: center, outer: outer, readings: readings)
                drawProfileDisc(context, center: center, outer: outer, readings: readings, area: area)
                drawProfileArea(context, center: center, outer: outer, readings: readings, area: area)

            case .colorCreator(let creator):
                drawWheel(context, center: center, outer: outer, chroma: { _ in 0.35 })
                drawColorCreator(context, center: center, outer: outer, creator: creator)

            case .partialColor(_, _, let band):
                drawWheel(
                    context, center: center, outer: outer,
                    chroma: { CameraLookGeometry.retainedChroma(band, at: $0) })
                drawBandMarker(context, center: center, outer: outer, band: band)

            case .monochrome(let mono):
                drawMonochrome(context, center: center, outer: outer, mono: mono)

            case .none:
                drawWheel(context, center: center, outer: outer, chroma: { _ in 0.15 })
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - The shared wheel

    private var ringWidth: CGFloat { 22 }

    /// The background annulus, drawn as short arcs so each can carry its own chroma — which is what
    /// lets Partial Color show the rest of the wheel collapsing while the kept band stays saturated.
    private func drawWheel(
        _ context: GraphicsContext, center: CGPoint, outer: CGFloat,
        chroma: (Double) -> Double
    ) {
        let step = 2.0
        var hue = 0.0
        while hue < 360 {
            var path = Path()
            path.addArc(
                center: center, radius: outer - ringWidth / 2,
                startAngle: .degrees(-(hue + step)), endAngle: .degrees(-hue),
                clockwise: false)
            context.stroke(
                path,
                with: .color(
                    Color(hue: hue / 360, saturation: chroma(hue), brightness: 0.95)),
                lineWidth: ringWidth)
            hue += step
        }
    }

    // MARK: - Twelve simultaneous magnitudes

    /// The whole disc, not a ring, because a hue slider *is* a saturation control for its band. The
    /// value has a direct visual consequence, so the disc can show what the setting does rather than
    /// only what it reads: saturation climbs from near-grey at the centre to the dialled level at
    /// the rim, and a cut band stays visibly pale the whole way out.
    ///
    /// This replaced a radial bar per spoke. A bar drawn from zero to a negative value has no
    /// meaning to point at — nothing in the image corresponds to the run between them — where a
    /// desaturated wedge is the effect itself.
    private func drawProfileDisc(
        _ context: GraphicsContext, center: CGPoint, outer: CGFloat,
        readings: [CameraLookGeometry.SpokeReading], area: Path
    ) {
        var disc = Path()
        disc.addEllipse(
            in: CGRect(
                x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))

        // Inside the figure, the colour the look renders. Clipping to the area is what makes the
        // graphic claim something: every saturated pixel is inside the balance that was dialled.
        context.drawLayer { layer in
            layer.clip(to: area)
            drawWedges(layer, center: center, outer: outer, readings: readings, muted: false)
        }

        // Outside it, the same hues a fifth weaker. Even-odd fill turns the disc and the area into
        // the ring between them, so this pass is only ever the part the look gives up.
        var beyond = disc
        beyond.addPath(area)
        context.drawLayer { layer in
            layer.clip(to: beyond, style: FillStyle(eoFill: true))
            drawWedges(layer, center: center, outer: outer, readings: readings, muted: true)
        }
    }

    /// The disc as 2-degree wedges, each carrying its own interpolated value.
    private func drawWedges(
        _ context: GraphicsContext, center: CGPoint, outer: CGFloat,
        readings: [CameraLookGeometry.SpokeReading], muted: Bool
    ) {
        let step = 2.0
        var hue = 0.0
        while hue < 360 {
            // Sampled mid-wedge so a wedge is coloured by the hue through its middle rather than
            // its leading edge, which would bias the whole disc half a step round.
            let midpoint = hue + step / 2
            let value = CameraLookGeometry.interpolatedSpokeValue(at: midpoint, readings: readings)

            var wedge = Path()
            wedge.move(to: center)
            wedge.addArc(
                center: center, radius: outer,
                startAngle: .degrees(-(hue + step)), endAngle: .degrees(-hue), clockwise: false)
            wedge.closeSubpath()

            // Always ramped to the rim, so a given radius means the same thing in every direction.
            // Scaling the ramp to each wedge's own boundary instead put peak saturation wherever
            // the figure happened to fall — and a cut spoke's boundary sits near the centre, so its
            // hue would have looked most saturated close to the middle, inverting the whole ramp.
            context.fill(
                wedge,
                with: .radialGradient(
                    saturationRamp(hue: midpoint, value: value, muted: muted),
                    center: center, startRadius: 0, endRadius: outer))
            hue += step
        }
    }

    /// Centre-to-rim saturation for one wedge. Five stops rather than two so the curve is the
    /// gradient's shape rather than a straight line: the `0.65` exponent brings colour up early and
    /// then eases, while still leaving the very centre neutral instead of a wash of every hue at
    /// once.
    private func saturationRamp(hue: Double, value: Double, muted: Bool) -> Gradient {
        let peak = muted ? mutedSaturation(value) : edgeSaturation(value)
        let stops = (0...4).map { index -> Gradient.Stop in
            let position = Double(index) / 4
            return Gradient.Stop(
                color: Color(
                    hue: hue / 360, saturation: peak * pow(position, 0.65),
                    brightness: 0.97 - 0.06 * position),
                location: position)
        }
        return Gradient(stops: stops)
    }

    /// The dialled value as rim saturation: -5 nearly grey, 0 ordinary, +5 fully saturated. This is
    /// the channel that carries the reading; the figure's radius restates it as a shape.
    private func edgeSaturation(_ value: Double) -> Double {
        min(max(0.55 + 0.09 * value, 0), 1)
    }

    /// Outside the figure, half. A fifth off was not readable as a step at all; halving makes the
    /// boundary carry itself without the outside collapsing to grey, which is the other end of this
    /// same dial — the wheel beyond the outline is still the same wheel, only past what the look
    /// asked for.
    private func mutedSaturation(_ value: Double) -> Double {
        edgeSaturation(value) * 0.5
    }

    /// The twelve values as one closed figure, with a dot at each measured spoke and a dashed circle
    /// at zero. The area is the readable part — a lopsided figure says at a glance that the look
    /// leans one side of the wheel — while the dots give back the exact per-spoke positions that an
    /// interpolated outline would otherwise blur away.
    /// The figure the twelve values trace, built once and used both as the outline and as the clip
    /// that decides where colour is allowed to be saturated.
    private func profileAreaPath(
        center: CGPoint, outer: CGFloat, readings: [CameraLookGeometry.SpokeReading]
    ) -> Path {
        var area = Path()
        for (index, reading) in readings.enumerated() {
            let vertex = point(
                hue: reading.hue, radius: valueRadius(Double(reading.value), outer: outer),
                from: center)
            if index == 0 {
                area.move(to: vertex)
            } else {
                area.addLine(to: vertex)
            }
        }
        area.closeSubpath()
        return area
    }

    private func drawProfileArea(
        _ context: GraphicsContext, center: CGPoint, outer: CGFloat,
        readings: [CameraLookGeometry.SpokeReading], area: Path
    ) {
        guard !readings.isEmpty else { return }

        var zero = Path()
        let zeroRadius = valueRadius(0, outer: outer)
        zero.addEllipse(
            in: CGRect(
                x: center.x - zeroRadius, y: center.y - zeroRadius,
                width: zeroRadius * 2, height: zeroRadius * 2))
        context.stroke(
            zero, with: .color(.secondary.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        context.stroke(area, with: .color(.primary.opacity(0.75)), lineWidth: 1.5)

        for reading in readings {
            let vertex = point(
                hue: reading.hue, radius: valueRadius(Double(reading.value), outer: outer),
                from: center)
            var dot = Path()
            dot.addEllipse(in: CGRect(x: vertex.x - 2.5, y: vertex.y - 2.5, width: 5, height: 5))
            context.fill(dot, with: .color(.primary))

            context.draw(
                Text(reading.code).font(.system(size: 8, weight: .semibold)),
                at: point(hue: reading.hue, radius: outer + 5, from: center))
        }
    }

    /// Value to radius, centred on the zero circle so a cut and a boost of the same size sit the
    /// same distance either side of it.
    private func valueRadius(_ value: Double, outer: CGFloat) -> CGFloat {
        let maximum = Double(CameraLookGeometry.hueSpokeRange.upperBound)
        return outer * (0.55 + 0.35 * min(max(value / maximum, -1), 1))
    }

    // MARK: - A single selected stop

    /// The Colour Creator marker. Position 0 imposes no hue at all, so it draws as a hollow centre
    /// dot rather than a ray — the camera makes the same distinction by drawing an empty swatch.
    /// Vivid is bipolar saturation, shown as a bar rather than as the marker's radius (the radius
    /// carries Vivid in OM Workspace's own UI, which is a source of confusion worth not copying).
    private func drawColorCreator(
        _ context: GraphicsContext, center: CGPoint, outer: CGFloat,
        creator: CameraLook.ColorCreator
    ) {
        let inner = outer - ringWidth

        if let hue = CameraLookGeometry.colorCreatorHue(position: creator.position) {
            var ray = Path()
            ray.move(to: center)
            ray.addLine(to: point(hue: hue, radius: inner, from: center))
            context.stroke(
                ray,
                with: .color(Color(hue: hue / 360, saturation: 0.95, brightness: 0.95)),
                style: StrokeStyle(lineWidth: 4, lineCap: .round))
        } else {
            var dot = Path()
            dot.addEllipse(in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            context.stroke(dot, with: .color(.secondary), lineWidth: 2)
        }

        let label = creator.isMonochrome ? "mono" : signed(creator.strength)
        context.draw(
            Text("Vivid \(label)").font(.system(size: 9, weight: .semibold)),
            at: CGPoint(x: center.x, y: center.y + inner * 0.55))
    }

    /// A tick at the kept hue. The band itself is already visible in the wheel's own chroma, so this
    /// only has to say which stop was chosen.
    private func drawBandMarker(
        _ context: GraphicsContext, center: CGPoint, outer: CGFloat,
        band: CameraLookGeometry.PartialColorBand
    ) {
        var path = Path()
        path.move(to: point(hue: band.center, radius: outer - ringWidth - 4, from: center))
        path.addLine(to: point(hue: band.center, radius: outer + 3, from: center))
        context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        if band.floor > 0 {
            context.draw(
                Text("keeps \(Int((band.floor * 100).rounded()))% elsewhere")
                    .font(.system(size: 8)),
                at: CGPoint(x: center.x, y: center.y))
        }
    }

    // MARK: - Not a hue wheel

    /// Monochrome has no hue to place, so it gets swatches rather than a ring: the contrast filter
    /// (which colours render light or dark) and the toning colour applied to the finished image are
    /// two separate darkroom stages, and the camera stores them independently.
    private func drawMonochrome(
        _ context: GraphicsContext, center: CGPoint, outer: CGFloat,
        mono: CameraLookRendering.Monochrome
    ) {
        var disc = Path()
        disc.addEllipse(
            in: CGRect(
                x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        context.fill(
            disc,
            with: .linearGradient(
                Gradient(colors: [.black, .white]),
                startPoint: CGPoint(x: center.x - outer, y: center.y),
                endPoint: CGPoint(x: center.x + outer, y: center.y)))

        // A light wash rather than a strong one: the tint is a toning stage over a finished
        // monochrome print, so it should read as a cast on the greys, not as a colour of its own.
        if let tint = mono.tint, let color = swatch(tint) {
            context.fill(disc, with: .color(color.opacity(0.22)))
        }
        context.stroke(disc, with: .color(.secondary.opacity(0.6)), lineWidth: 1)

        var lines: [String] = []
        if let filter = mono.filter {
            lines.append(
                mono.filterStrength.map { "\(filter) filter \($0)" } ?? "\(filter) filter")
        }
        if let tint = mono.tint { lines.append("\(tint) tint") }

        // Centred on the disc as a block, so one line and two both sit on the middle rather than
        // hanging off a fixed first-line position. Regular weight at 12: this is the only graphic
        // whose reading is words, and it can afford the size where the ring labels cannot.
        let lineHeight: CGFloat = 16
        let top = center.y - lineHeight * CGFloat(lines.count - 1) / 2
        for (index, line) in lines.enumerated() {
            context.draw(
                Text(line).font(.system(size: 12)).foregroundStyle(.black),
                at: CGPoint(x: center.x, y: top + CGFloat(index) * lineHeight))
        }
    }

    /// The camera's filter/tint names are a small closed set from `CameraLookParsing`'s tables.
    private func swatch(_ name: String) -> Color? {
        switch name {
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "sepia": return Color(red: 0.44, green: 0.26, blue: 0.08)
        default: return nil
        }
    }

    // MARK: - Geometry

    /// Hue 0 at 3 o'clock, increasing anticlockwise. SwiftUI's y runs down, so the angle is negated.
    private func point(hue: Double, radius: CGFloat, from center: CGPoint) -> CGPoint {
        let radians = -hue * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}

#Preview("Colour Profile") {
    var look = CameraLook()
    look.mode = "Color Profile 2"
    look.hueSliders = [
        CameraLook.Slider(code: "Y", value: 4), CameraLook.Slider(code: "R", value: -3),
        CameraLook.Slider(code: "B", value: 2), CameraLook.Slider(code: "G", value: 5),
    ]
    look.contrast = 2
    look.toneLevels = [CameraLook.Slider(code: "HL", value: -3)]
    return CameraLookStripView(look: look, isRawFile: false).padding()
}

#Preview("Partial Color II") {
    var look = CameraLook()
    look.mode = "Partial Color II"
    look.partialColor = CameraLook.PartialColor(index: 9, name: "blue")
    return CameraLookStripView(look: look, isRawFile: false).padding()
}

#Preview("Monochrome") {
    var look = CameraLook()
    look.mode = "Monochrome Profile 3"
    look.monochromeFilter = CameraLook.MonochromeFilter(name: "red", strength: 3)
    look.monochromeTint = "sepia"
    look.grain = "Low"
    look.shading = 2
    return CameraLookStripView(look: look, isRawFile: false).padding()
}

#Preview("No look") {
    CameraLookStripView(look: nil, isRawFile: true).padding()
}
