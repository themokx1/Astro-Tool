import Foundation
import Testing
@testable import AstroCore

@Test func objectAtDeclinationEqualToLatitudeTransitsAtZenith() {
    // HA = 0 <=> LST(hours) == RA(hours). dec == lat => alt should be 90.
    let lat = 47.5
    let raDeg = 123.4
    let lstHours = raDeg / 15.0
    let (alt, _) = AltAz.position(raDeg: raDeg, decDeg: lat, lstHours: lstHours, latDeg: lat)
    #expect(abs(alt - 90) < 1e-6)
}

@Test func polarisAltitudeApproximatesLatitudeAcrossAWideRangeOfLatitudesAndHourAngles() {
    let polarisDec = 89.26
    let polarisRA = 37.95 // approx, degrees
    for lat in [20.0, 35.0, 47.5, 60.0] {
        for lstHours in stride(from: 0.0, to: 24.0, by: 4.0) {
            let (alt, _) = AltAz.position(raDeg: polarisRA, decDeg: polarisDec, lstHours: lstHours, latDeg: lat)
            #expect(abs(alt - lat) < 1.0, "lat=\(lat) lst=\(lstHours) alt=\(alt)")
        }
    }
}

@Test func symmetricHourAnglesGiveEqualAltitudes() {
    let lat = 45.0
    let dec = 10.0
    let ra = 100.0
    // HA = LST*15 - RA. Choose LST values that give HA = +2h and HA = -2h.
    let lstPlus = (ra + 30) / 15.0 // HA = +30 deg
    let lstMinus = (ra - 30) / 15.0 // HA = -30 deg
    let (altPlus, _) = AltAz.position(raDeg: ra, decDeg: dec, lstHours: lstPlus, latDeg: lat)
    let (altMinus, _) = AltAz.position(raDeg: ra, decDeg: dec, lstHours: lstMinus, latDeg: lat)
    #expect(abs(altPlus - altMinus) < 1e-9)
}

@Test func celestialEquatorObjectTransitsDueSouthForNorthernObserver() {
    let lat = 45.0
    let ra = 200.0
    let lstHours = ra / 15.0 // HA = 0, transit
    let (alt, az) = AltAz.position(raDeg: ra, decDeg: 0, lstHours: lstHours, latDeg: lat)
    #expect(abs(alt - 45) < 1e-6)
    #expect(abs(az - 180) < 1e-6)
}

@Test func airmassIsOneAtZenithAndGrowsTowardHorizon() {
    let zenith = AltAz.airmass(altitudeDeg: 90)
    #expect(abs((zenith ?? -1) - 1.0) < 1e-9)

    let low = AltAz.airmass(altitudeDeg: 10)
    let high = AltAz.airmass(altitudeDeg: 60)
    #expect((low ?? 0) > (high ?? 0))
}

@Test func airmassIsNilBelowHorizon() {
    #expect(AltAz.airmass(altitudeDeg: -5) == nil)
    #expect(AltAz.airmass(altitudeDeg: 0) == nil)
}
