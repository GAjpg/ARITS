import Foundation

public struct CampusSunLocation:Codable,Equatable {
    public var latitude:Double,longitude:Double
    public var time_zone:String
    public init(latitude:Double,longitude:Double,timeZone:TimeZone) { self.latitude = latitude;self.longitude = longitude;time_zone = timeZone.identifier }
    public var isValid:Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) && TimeZone(identifier:time_zone) != nil }
}

public struct CampusSolarDay {
    public let sunrise:Date?,sunset:Date?
    public let startsInDaylight:Bool
    public let start:Date,end:Date
}

/// Offline approximation using NOAA's fractional-year equation of time and declination.
/// Source: https://gml.noaa.gov/grad/solcalc/solareqns.PDF
/// The -0.833° threshold accounts for refraction and solar disk size, not indoor brightness.
public enum CampusDaylight {
    public static func lighting(at date:Date,location:CampusSunLocation) throws -> CampusLighting {
        try validate(date,location)
        return elevation(at:date,location:location) >= -0.833 ? .daylight : .night
    }
    public static func day(containing date:Date,location:CampusSunLocation) throws -> CampusSolarDay {
        try validate(date,location)
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(identifier:location.time_zone)!
        guard let interval = calendar.dateInterval(of:.day,for:date) else { throw CampusError.invalid("日期无效。") }
        let start = interval.start,end = interval.end,initial = elevation(at:start,location:location) >= -0.833
        var before = start,wasDay = initial,rise:Date?,set:Date?
        while before < end {
            let after = min(before.addingTimeInterval(300),end),isDay = elevation(at:after,location:location) >= -0.833
            if isDay != wasDay {
                var low = before,high = after
                for _ in 0..<18 {
                    let mid = low.addingTimeInterval(high.timeIntervalSince(low)/2)
                    if (elevation(at:mid,location:location) >= -0.833) == wasDay { low = mid } else { high = mid }
                }
                if high < end { if isDay { rise = rise ?? high } else { set = set ?? high } }
            }
            before = after;wasDay = isDay
        }
        return CampusSolarDay(sunrise:rise,sunset:set,startsInDaylight:initial,start:start,end:end)
    }
    private static func validate(_ date:Date,_ location:CampusSunLocation) throws {
        guard date.timeIntervalSince1970.isFinite,location.isValid else { throw CampusError.invalid("日出日落计算需要有效的经纬度、时区和日期。") }
    }
    private static func elevation(at date:Date,location:CampusSunLocation) -> Double {
        var utc = Calendar(identifier:.gregorian);utc.timeZone = TimeZone(secondsFromGMT:0)!
        let c = utc.dateComponents([.hour,.minute,.second,.nanosecond],from:date)
        let day = Double(utc.ordinality(of:.day,in:.year,for:date)!),days = Double(utc.range(of:.day,in:.year,for:date)!.count)
        let hour = Double(c.hour!)+Double(c.minute!)/60+Double(c.second!)/3600+Double(c.nanosecond!)/3_600_000_000_000
        let gamma = 2 * Double.pi / days * (day-1+(hour-12)/24)
        let eq = 229.18*(0.000075+0.001868*cos(gamma)-0.032077*sin(gamma)-0.014615*cos(2*gamma)-0.040849*sin(2*gamma))
        let decl = 0.006918-0.399912*cos(gamma)+0.070257*sin(gamma)-0.006758*cos(2*gamma)+0.000907*sin(2*gamma)-0.002697*cos(3*gamma)+0.00148*sin(3*gamma)
        let solarMinutes = ((hour*60+eq+4*location.longitude).truncatingRemainder(dividingBy:1440)+1440).truncatingRemainder(dividingBy:1440)
        let angle = (solarMinutes/4-180) * .pi/180,lat = location.latitude * .pi/180
        let sine = sin(lat)*sin(decl)+cos(lat)*cos(decl)*cos(angle)
        return asin(min(1,max(-1,sine))) * 180 / .pi
    }
}

public enum CampusLightingMode:String,Codable,CaseIterable {
    case automatic,daylight,night
    public var title:String { switch self { case .automatic:return "自动（日出／日落）";case .daylight:return "优先白天";case .night:return "优先夜间" } }
}
public struct CampusLightingPreference:Codable,Equatable {
    public var mode:CampusLightingMode = .automatic
    public var location:CampusSunLocation?
    public init() {}
    public func preferredLighting(at date:Date,timeZone:TimeZone = .current) -> CampusLighting {
        switch mode {
        case .daylight:return .daylight
        case .night:return .night
        case .automatic:
            if let location,let light = try? CampusDaylight.lighting(at:date,location:location) { return light }
            var calendar = Calendar(identifier:.gregorian);calendar.timeZone = timeZone
            return (6..<18).contains(calendar.component(.hour,from:date)) ? .daylight : .night
        }
    }
}
