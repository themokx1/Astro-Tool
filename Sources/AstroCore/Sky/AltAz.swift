import Foundation

/// Equatorial (RA/Dec) -> horizontal (altitude/azimuth) transform for a given
/// site latitude and Local Sidereal Time, plus airmass. Azimuth follows
/// compass convention: North = 0 deg, East = 90 deg, South = 180 deg,
/// West = 270 deg.
public enum AltAz {
    /// `(altitudeDeg, azimuthDeg)` for an object at `raDeg`/`decDeg`, seen
    /// from a site at `latDeg`, at the given `lstHours` (Local Sidereal
    /// Time). Azimuth is measured from North, clockwise through East.
    public static func position(raDeg: Double, decDeg: Double, lstHours: Double, latDeg: Double) -> (altitudeDeg: Double, azimuthDeg: Double) {
        let lstDeg = lstHours * 15.0
        var haDeg = lstDeg - raDeg
        haDeg = haDeg.truncatingRemainder(dividingBy: 360.0)
        if haDeg < -180 { haDeg += 360 }
        if haDeg > 180 { haDeg -= 360 }

        let ha = haDeg * .pi / 180
        let dec = decDeg * .pi / 180
        let lat = latDeg * .pi / 180

        let sinAlt = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha)
        let alt = asin(max(-1, min(1, sinAlt)))

        // Meeus Ch. 13: azimuth A measured westward from South. Converted to
        // compass convention (from North, clockwise) by adding 180 deg.
        let southAz = atan2(sin(ha), cos(ha) * sin(lat) - tan(dec) * cos(lat))
        var azDeg = southAz * 180 / .pi + 180
        azDeg = azDeg.truncatingRemainder(dividingBy: 360)
        if azDeg < 0 { azDeg += 360 }

        return (alt * 180 / .pi, azDeg)
    }

    /// Airmass (plane-parallel secant-of-zenith-angle approximation),
    /// `nil` below the horizon where the approximation is meaningless (and
    /// blows up as altitude -> 0).
    public static func airmass(altitudeDeg: Double) -> Double? {
        guard altitudeDeg > 0 else { return nil }
        return 1.0 / sin(altitudeDeg * .pi / 180)
    }
}
